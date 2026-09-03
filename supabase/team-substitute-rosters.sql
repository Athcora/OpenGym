create table if not exists public.team_substitutes(
  id uuid primary key default gen_random_uuid(),
  team_id uuid not null references public.king_teams(id) on delete cascade,
  player_id uuid not null unique references public.waitlist_players(id) on delete cascade,
  created_at timestamptz not null default now(),
  unique(team_id,player_id)
);

create table if not exists public.team_substitute_requests(
  id uuid primary key default gen_random_uuid(),
  team_id uuid not null references public.king_teams(id) on delete cascade,
  requester_id uuid references public.waitlist_players(id) on delete set null,
  target_id uuid not null references public.waitlist_players(id) on delete cascade,
  status text not null default 'pending' check(status in('pending','accepted','declined','expired')),
  created_at timestamptz not null default now(),
  answered_at timestamptz
);

alter table public.team_substitutes enable row level security;
alter table public.team_substitute_requests enable row level security;
drop policy if exists team_substitutes_read on public.team_substitutes;
create policy team_substitutes_read on public.team_substitutes for select to authenticated using(true);
drop policy if exists team_substitute_requests_read on public.team_substitute_requests;
create policy team_substitute_requests_read on public.team_substitute_requests for select to authenticated using(true);

do $$ begin alter publication supabase_realtime add table public.team_substitutes; exception when duplicate_object then null; end $$;
do $$ begin alter publication supabase_realtime add table public.team_substitute_requests; exception when duplicate_object then null; end $$;

create unique index if not exists one_pending_team_sub_invite
on public.team_substitute_requests(team_id,target_id) where status='pending';

create or replace function public.request_team_substitute(p_team_id uuid,p_target_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare requester public.waitlist_players; target public.waitlist_players; requested_team public.king_teams; active_count integer; sub_count integer;
begin
  update public.team_substitute_requests set status='expired',answered_at=now() where status='pending' and created_at<=now()-interval '5 minutes';
  select * into requester from public.waitlist_players where user_id=auth.uid() and status in('current','waiting') for update;
  select * into target from public.waitlist_players where id=p_target_id and status='waiting' for update;
  select * into requested_team from public.king_teams where id=p_team_id for update;
  if requested_team.id is null then raise exception 'That team is unavailable.'; end if;
  if requester.id is null and not public.is_waitlist_operator() then raise exception 'You must be an active player to invite a substitute.'; end if;
  if requester.id is not null and requester.team_id<>requested_team.id and not public.is_waitlist_operator() then raise exception 'Only this team or an admin or host can invite substitutes.'; end if;
  if target.id is null then raise exception 'Select a player who is currently in the waitlist.'; end if;
  if target.team_id=requested_team.id then raise exception 'You cannot invite someone who is already on your team.'; end if;
  select count(*) into active_count from public.waitlist_players where team_id=requested_team.id and status<>'left' and not exists(select 1 from public.team_substitutes s where s.player_id=waitlist_players.id);
  if active_count<6 then raise exception 'Fill all six team positions before adding substitutes.'; end if;
  select count(*) into sub_count from public.team_substitutes where team_id=requested_team.id;
  if sub_count>=6 then raise exception 'This team already has six substitutes.'; end if;
  if exists(select 1 from public.team_substitutes where player_id=target.id) then raise exception 'That player is already a substitute.'; end if;
  insert into public.team_substitute_requests(team_id,requester_id,target_id) values(requested_team.id,requester.id,target.id);
  return jsonb_build_object('message','Substitute invitation sent.');
end;$$;
grant execute on function public.request_team_substitute(uuid,uuid) to authenticated;

create or replace function public.answer_team_substitute(p_request_id uuid,p_accept boolean)
returns jsonb language plpgsql security definer set search_path=public as $$
declare request public.team_substitute_requests; target public.waitlist_players; old_team uuid; sub_count integer;
begin
  perform pg_advisory_xact_lock(7429204);
  select * into request from public.team_substitute_requests where id=p_request_id and status='pending' and created_at>now()-interval '5 minutes' for update;
  if request.id is null then raise exception 'This substitute invitation is no longer available.'; end if;
  select * into target from public.waitlist_players where id=request.target_id and user_id=auth.uid() and status='waiting' for update;
  if target.id is null then raise exception 'Only the invited waitlist player can answer this request.'; end if;
  if not p_accept then
    update public.team_substitute_requests set status='declined',answered_at=now() where id=request.id;
    return jsonb_build_object('message','Substitute invitation declined.');
  end if;
  select count(*) into sub_count from public.team_substitutes where team_id=request.team_id;
  if sub_count>=6 then raise exception 'That team already has six substitutes.'; end if;
  old_team:=target.team_id;
  delete from public.team_substitutes where player_id=target.id;
  insert into public.team_substitutes(team_id,player_id) values(request.team_id,target.id);
  update public.waitlist_players set team_id=null,status='waiting',court_number=null,updated_at=now() where id=target.id;
  update public.team_substitute_requests set status='accepted',answered_at=now() where id=request.id;
  update public.team_substitute_requests set status='expired',answered_at=now() where target_id=target.id and status='pending' and id<>request.id;
  if old_team is not null and not exists(select 1 from public.waitlist_players where team_id=old_team and status<>'left') then delete from public.king_teams where id=old_team; end if;
  return jsonb_build_object('message','You are now a substitute for '||public.king_team_label(request.team_id)||'.');
end;$$;
grant execute on function public.answer_team_substitute(uuid,boolean) to authenticated;

create or replace function public.cleanup_team_substitute_membership()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  if new.status in('left','rejoin') or new.team_id is not null then
    delete from public.team_substitutes where player_id=new.id;
  end if;
  return new;
end;$$;
drop trigger if exists cleanup_team_substitute_membership_trigger on public.waitlist_players;
create trigger cleanup_team_substitute_membership_trigger after update of status,team_id on public.waitlist_players for each row execute function public.cleanup_team_substitute_membership();
