-- Multi-facility tenancy for OpenGym. Existing live data becomes the PHR facility.
create extension if not exists pgcrypto;

create table if not exists public.facilities (
  id uuid primary key default gen_random_uuid(),
  slug text not null unique check (slug ~ '^[a-z0-9]+(?:-[a-z0-9]+)*$'),
  code text not null unique,
  name text not null,
  address text,
  city text,
  region text,
  latitude double precision,
  longitude double precision,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

insert into public.facilities(slug,code,name,address,city,region,latitude,longitude)
values('pacific-highlands-ranch','PHR','Pacific Highlands Ranch','5977 Village Center Loop Rd','San Diego','CA',32.95996,-117.18682)
on conflict(slug) do update set code=excluded.code,name=excluded.name,address=excluded.address,
  city=excluded.city,region=excluded.region,latitude=excluded.latitude,longitude=excluded.longitude;

create table if not exists public.user_facility_sessions (
  user_id uuid primary key,
  facility_id uuid not null references public.facilities(id) on delete cascade,
  selected_at timestamptz not null default now()
);

alter table public.facilities enable row level security;
alter table public.user_facility_sessions enable row level security;
drop policy if exists "public reads active facilities" on public.facilities;
create policy "public reads active facilities" on public.facilities for select to anon,authenticated using(active);
drop policy if exists "users read facility session" on public.user_facility_sessions;
create policy "users read facility session" on public.user_facility_sessions for select to authenticated using(user_id=auth.uid());

create or replace function public.current_facility_id()
returns uuid language sql stable security definer set search_path=public as $$
  select coalesce(
    (select facility_id from public.user_facility_sessions where user_id=auth.uid()),
    (select id from public.facilities where slug='pacific-highlands-ranch')
  )
$$;

create or replace function public.select_facility(p_slug text)
returns public.facilities language plpgsql security definer set search_path=public as $$
declare selected public.facilities;
begin
  if auth.uid() is null then raise exception 'You must be signed in.'; end if;
  select * into selected from public.facilities
    where active and (slug=lower(trim(p_slug)) or upper(code)=upper(trim(p_slug)));
  if selected.id is null then raise exception 'Facility not found.'; end if;
  insert into public.user_facility_sessions(user_id,facility_id,selected_at)
    values(auth.uid(),selected.id,now())
    on conflict(user_id) do update set facility_id=excluded.facility_id,selected_at=now();
  return selected;
end $$;
grant execute on function public.select_facility(text) to authenticated;
grant select on public.facilities to anon,authenticated;

-- Scope every queue-owned record. UUID records remain globally unique; singleton
-- and ordinal records receive facility-aware keys below.
do $$
declare t text; legacy uuid := (select id from public.facilities where slug='pacific-highlands-ranch');
begin
  foreach t in array array[
    'admin_redo','admin_sessions','admin_undo','daily_waitlist_reset_state',
    'geofence_return_prompts','group_notifications','group_requests','king_mode_state',
    'king_round_history','king_teams','past_games','push_subscriptions','rejoin_responses',
    'substitute_requests','team_fill_ins','team_substitute_requests','team_substitutes',
    'waitlist_config','waitlist_courts','waitlist_events','waitlist_players'
  ] loop
    execute format('alter table public.%I add column if not exists facility_id uuid references public.facilities(id) on delete cascade',t);
    execute format('update public.%I set facility_id=$1 where facility_id is null',t) using legacy;
    execute format('alter table public.%I alter column facility_id set default public.current_facility_id()',t);
    execute format('alter table public.%I alter column facility_id set not null',t);
    execute format('alter table public.%I enable row level security',t);
    execute format('drop policy if exists facility_isolation on public.%I',t);
    execute format('create policy facility_isolation on public.%I as restrictive for all to public using(facility_id=public.current_facility_id()) with check(facility_id=public.current_facility_id())',t);
    execute format('drop policy if exists runtime_facility_access on public.%I',t);
    execute format('create policy runtime_facility_access on public.%I for all to opengym_runtime using(true) with check(true)',t);
  end loop;
end $$;

alter table public.waitlist_config drop constraint if exists waitlist_config_pkey;
alter table public.waitlist_config add primary key(facility_id,id);
alter table public.waitlist_courts drop constraint if exists waitlist_courts_pkey;
alter table public.waitlist_courts add primary key(facility_id,court_number);
alter table public.daily_waitlist_reset_state drop constraint if exists daily_waitlist_reset_state_pkey;
alter table public.daily_waitlist_reset_state add primary key(facility_id,id);
alter table public.king_mode_state drop constraint if exists king_mode_state_pkey;
alter table public.king_mode_state add primary key(facility_id,id);
alter table public.past_games drop constraint if exists past_games_game_number_key;
alter table public.past_games add unique(facility_id,game_number);
alter table public.waitlist_players drop constraint if exists waitlist_players_user_id_key;
alter table public.waitlist_players add unique(facility_id,user_id);
drop index if exists public.waitlist_players_one_active_device;
create unique index waitlist_players_one_active_device on public.waitlist_players(facility_id,device_id)
  where device_id is not null and status<>'left';

-- Functions need elevated write access, but must still obey the restrictive RLS
-- policy. A dedicated NOLOGIN owner provides that without BYPASSRLS.
do $$ begin create role opengym_runtime nologin; exception when duplicate_object then null; end $$;
grant opengym_runtime to postgres;
grant usage,create on schema public to opengym_runtime;
grant usage on schema auth to opengym_runtime;
grant execute on all functions in schema auth to opengym_runtime;
grant authenticated to opengym_runtime;
grant select,insert,update,delete on all tables in schema public to opengym_runtime;
grant usage,select on all sequences in schema public to opengym_runtime;
grant execute on all functions in schema public to opengym_runtime;

do $$
declare f record;
begin
  for f in select p.oid::regprocedure signature
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.prosecdef
      and p.proname not in('current_facility_id','select_facility','sign_in_waitlist_admin','create_facility')
  loop execute format('alter function %s owner to opengym_runtime',f.signature); end loop;
end $$;

-- Facility-specific administrator credentials reuse the existing secure hashes.
create table if not exists public.facility_admin_credentials (
  facility_id uuid not null references public.facilities(id) on delete cascade,
  username text not null,
  display_username text not null,
  password_hash text not null,
  created_at timestamptz not null default now(),
  primary key(facility_id,username)
);
insert into public.facility_admin_credentials(facility_id,username,display_username,password_hash)
select f.id,c.username,c.display_username,c.password_hash
from public.facilities f cross join public.admin_credentials c
where f.slug='pacific-highlands-ranch'
on conflict(facility_id,username) do update set display_username=excluded.display_username,password_hash=excluded.password_hash;
-- Pacific Highlands Ranch uses its facility-specific administrator name.
update public.facility_admin_credentials
set username='phr',display_username='PHR'
where facility_id=(select id from public.facilities where slug='pacific-highlands-ranch')
  and username<>'phr';
alter table public.facility_admin_credentials enable row level security;
alter table public.admin_sessions drop constraint if exists admin_sessions_username_fkey;
alter table public.admin_sessions drop constraint if exists admin_sessions_facility_username_fkey;
alter table public.admin_sessions add constraint admin_sessions_facility_username_fkey
  foreign key(facility_id,username) references public.facility_admin_credentials(facility_id,username) on update cascade;

create or replace function public.sign_in_waitlist_admin(p_username text,p_password text)
returns jsonb language plpgsql security definer set search_path=public,extensions as $$
declare credential public.facility_admin_credentials; fid uuid:=public.current_facility_id();
begin
  if auth.uid() is null then raise exception 'You must be signed in.'; end if;
  select * into credential from public.facility_admin_credentials
    where facility_id=fid and username=lower(trim(p_username));
  if credential.username is null or credential.password_hash<>crypt(p_password,credential.password_hash) then
    raise exception 'Incorrect username or password.';
  end if;
  insert into public.admin_sessions(user_id,username,facility_id)
    values(auth.uid(),credential.username,fid)
    on conflict(user_id) do update set username=excluded.username,facility_id=excluded.facility_id,created_at=now();
  return jsonb_build_object('message','Signed in.');
end $$;
grant execute on function public.sign_in_waitlist_admin(text,text) to authenticated;

-- Provisioning is intentionally limited to an authenticated administrator of
-- the currently selected facility. This creates a fresh, independent queue.
create or replace function public.create_facility(
  p_name text,p_slug text,p_code text,p_admin_username text,p_admin_password text,
  p_address text default null,p_city text default null,p_region text default null
) returns public.facilities language plpgsql security definer set search_path=public,extensions as $$
declare created public.facilities; new_slug text:=lower(trim(p_slug));
begin
  if not exists(select 1 from public.admin_sessions where user_id=auth.uid() and facility_id=public.current_facility_id()) then
    raise exception 'Admin access required.';
  end if;
  if length(trim(p_name))<2 or new_slug!~'^[a-z0-9]+(?:-[a-z0-9]+)*$' or length(trim(p_code))<3 then raise exception 'Enter a valid facility name, URL, and code.'; end if;
  if length(p_admin_password)<8 then raise exception 'The administrator password must be at least 8 characters.'; end if;
  insert into public.facilities(name,slug,code,address,city,region)
    values(trim(p_name),new_slug,upper(trim(p_code)),nullif(trim(p_address),''),nullif(trim(p_city),''),nullif(trim(p_region),'')) returning * into created;
  insert into public.facility_admin_credentials(facility_id,username,display_username,password_hash)
    values(created.id,lower(trim(p_admin_username)),trim(p_admin_username),crypt(p_admin_password,gen_salt('bf')));
  insert into public.waitlist_config(facility_id,id,game_number,max_players,mode,court_count,geofence_enabled,geofence_radius_m)
    values(created.id,true,1,12,'regular',1,false,150);
  insert into public.waitlist_courts(facility_id,court_number,game_number) values(created.id,1,1);
  insert into public.daily_waitlist_reset_state(facility_id,id,last_reset_date) values(created.id,true,null);
  return created;
end $$;
grant execute on function public.create_facility(text,text,text,text,text,text,text,text) to authenticated;

-- Existing ON CONFLICT statements that use ordinal keys need facility-aware targets.
do $$
declare f record; definition text;
begin
  for f in select p.oid,p.oid::regprocedure signature,pg_get_functiondef(p.oid) definition
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public'
  loop
    definition:=replace(f.definition,'ON CONFLICT (court_number)','ON CONFLICT (facility_id, court_number)');
    definition:=replace(definition,'on conflict(court_number)','on conflict(facility_id,court_number)');
    definition:=replace(definition,'ON CONFLICT (game_number)','ON CONFLICT (facility_id, game_number)');
    definition:=replace(definition,'on conflict(game_number)','on conflict(facility_id,game_number)');
    definition:=replace(definition,'ON CONFLICT (user_id)','ON CONFLICT (facility_id, user_id)');
    definition:=replace(definition,'on conflict(user_id)','on conflict(facility_id,user_id)');
    definition:=replace(definition,'ON CONFLICT (id)','ON CONFLICT (facility_id, id)');
    definition:=replace(definition,'on conflict(id)','on conflict(facility_id,id)');
    if definition<>f.definition then execute definition; end if;
  end loop;
end $$;

notify pgrst,'reload schema';
