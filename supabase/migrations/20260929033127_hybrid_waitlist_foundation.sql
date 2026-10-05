-- Hybrid Waitlist foundation.  This migration is deliberately inert for existing
-- modes: it adds isolated state only.  Later migrations expose guarded mutation
-- RPCs after the packing/result/reversal contracts are covered by tests.

alter table public.waitlist_config
  add column if not exists hybrid_rotation_rule text not null default 'two_on_two_off',
  add column if not exists hybrid_auto_kotc_threshold_teams integer,
  add column if not exists hybrid_auto_kotc_armed boolean not null default true;

alter table public.waitlist_config
  drop constraint if exists waitlist_config_mode_check;

alter table public.waitlist_config
  add constraint waitlist_config_mode_check
  check (mode in ('regular', 'rejoin', 'teams', 'teams_rejoin', 'hybrid_waitlist'));

alter table public.waitlist_config
  add constraint waitlist_config_hybrid_rotation_rule_check
  check (hybrid_rotation_rule in ('two_on_two_off', 'kotc')),
  add constraint waitlist_config_hybrid_threshold_check
  check (hybrid_auto_kotc_threshold_teams is null or hybrid_auto_kotc_threshold_teams between 3 and 6);

create table if not exists public.hybrid_kotc_teams(
  id uuid primary key default gen_random_uuid(),
  facility_id uuid not null references public.facilities(id) on delete cascade,
  court_number integer not null check (court_number between 1 and 12),
  court_side smallint not null check (court_side in (1,2)),
  appearance_game_number integer not null check (appearance_game_number > 0),
  status text not null default 'current' check (status in ('current','retired')),
  consecutive_wins integer not null default 0 check (consecutive_wins >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(facility_id,id)
);

create unique index if not exists hybrid_kotc_one_active_side
  on public.hybrid_kotc_teams(facility_id,court_number,court_side)
  where status='current';

create index if not exists hybrid_kotc_teams_facility_court_idx
  on public.hybrid_kotc_teams(facility_id,court_number,status);

create table if not exists public.hybrid_kotc_slots(
  id uuid primary key default gen_random_uuid(),
  facility_id uuid not null references public.facilities(id) on delete cascade,
  team_id uuid not null,
  slot_number smallint not null check (slot_number between 1 and 6),
  player_id uuid references public.waitlist_players(id) on delete set null,
  original_group_id uuid,
  original_unit_order integer,
  original_queue_position bigint,
  is_substitute boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(team_id,slot_number),
  foreign key(facility_id,team_id) references public.hybrid_kotc_teams(facility_id,id) on delete cascade,
  check ((player_id is null and is_substitute=false) or player_id is not null)
);

create index if not exists hybrid_kotc_slots_facility_player_idx
  on public.hybrid_kotc_slots(facility_id,player_id) where player_id is not null;

create table if not exists public.hybrid_kotc_substitutes(
  id uuid primary key default gen_random_uuid(),
  facility_id uuid not null references public.facilities(id) on delete cascade,
  team_id uuid not null,
  player_id uuid not null references public.waitlist_players(id) on delete cascade,
  created_at timestamptz not null default now(),
  unique(team_id,player_id),
  foreign key(facility_id,team_id) references public.hybrid_kotc_teams(facility_id,id) on delete cascade
);

create index if not exists hybrid_kotc_substitutes_facility_team_idx
  on public.hybrid_kotc_substitutes(facility_id,team_id);

-- A version is incremented only by a future guarded hybrid result transition.
-- It provides a per-court stale-result boundary without conflating two courts.
create table if not exists public.hybrid_kotc_court_state(
  facility_id uuid not null references public.facilities(id) on delete cascade,
  court_number integer not null check (court_number between 1 and 12),
  version bigint not null default 0 check (version >= 0),
  initialized_game_number integer,
  updated_at timestamptz not null default now(),
  primary key(facility_id,court_number)
);

alter table public.hybrid_kotc_teams enable row level security;
alter table public.hybrid_kotc_slots enable row level security;
alter table public.hybrid_kotc_substitutes enable row level security;
alter table public.hybrid_kotc_court_state enable row level security;

create policy hybrid_kotc_teams_read on public.hybrid_kotc_teams
  for select to authenticated using(facility_id=public.current_facility_id());
create policy hybrid_kotc_slots_read on public.hybrid_kotc_slots
  for select to authenticated using(facility_id=public.current_facility_id());
create policy hybrid_kotc_substitutes_read on public.hybrid_kotc_substitutes
  for select to authenticated using(facility_id=public.current_facility_id());
create policy hybrid_kotc_court_state_read on public.hybrid_kotc_court_state
  for select to authenticated using(facility_id=public.current_facility_id());

revoke all on public.hybrid_kotc_teams, public.hybrid_kotc_slots,
  public.hybrid_kotc_substitutes, public.hybrid_kotc_court_state from anon, authenticated;

-- A player may occupy one active hybrid side only.  This cannot be represented
-- by a simple partial unique index because activity belongs to the parent team.
create or replace function public.assert_hybrid_kotc_slot_integrity()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  if new.player_id is null then return new; end if;
  if exists(
    select 1 from public.hybrid_kotc_slots existing
    join public.hybrid_kotc_teams team on team.id=existing.team_id and team.facility_id=existing.facility_id
    where existing.facility_id=new.facility_id
      and existing.player_id=new.player_id
      and existing.id<>new.id
      and team.status='current'
  ) then raise exception 'A player may occupy only one active Waitlist KOTC slot.'; end if;
  return new;
end;
$$;

create trigger hybrid_kotc_slot_integrity
before insert or update of facility_id,team_id,player_id on public.hybrid_kotc_slots
for each row execute function public.assert_hybrid_kotc_slot_integrity();

create or replace function public.capture_hybrid_kotc_state()
returns jsonb language sql security definer set search_path=public as $$
  with scope as (select public.current_facility_id() as fid)
  select jsonb_build_object(
    'hybrid_kotc_teams',coalesce((select jsonb_agg(to_jsonb(t) order by t.court_number,t.court_side,t.created_at)
      from public.hybrid_kotc_teams t,scope where t.facility_id=scope.fid),'[]'::jsonb),
    'hybrid_kotc_slots',coalesce((select jsonb_agg(to_jsonb(s) order by s.team_id,s.slot_number)
      from public.hybrid_kotc_slots s,scope where s.facility_id=scope.fid),'[]'::jsonb),
    'hybrid_kotc_substitutes',coalesce((select jsonb_agg(to_jsonb(s) order by s.team_id,s.player_id)
      from public.hybrid_kotc_substitutes s,scope where s.facility_id=scope.fid),'[]'::jsonb),
    'hybrid_kotc_court_state',coalesce((select jsonb_agg(to_jsonb(s) order by s.court_number)
      from public.hybrid_kotc_court_state s,scope where s.facility_id=scope.fid),'[]'::jsonb)
  );
$$;

revoke all on function public.assert_hybrid_kotc_slot_integrity() from public, anon, authenticated;
revoke all on function public.capture_hybrid_kotc_state() from public, anon, authenticated;
grant execute on function public.capture_hybrid_kotc_state() to opengym_runtime;

-- Extend the existing facility-wide Undo/Redo snapshot without changing its
-- legacy payload.  Hybrid state is appended as separate families so temporary
-- KOTC membership never substitutes for player.group_id.
create or replace function public.capture_waitlist_state()
returns jsonb language sql security definer set search_path=public as $$
  with scope as (select public.current_facility_id() as fid)
  select jsonb_build_object(
    'players',coalesce((select jsonb_agg(to_jsonb(p) order by p.queue_position nulls last,p.id) from public.waitlist_players p,scope where p.facility_id=scope.fid),'[]'::jsonb),
    'config',(select to_jsonb(c) from public.waitlist_config c,scope where c.facility_id=scope.fid and c.id),
    'courts',coalesce((select jsonb_agg(to_jsonb(c) order by c.court_number) from public.waitlist_courts c,scope where c.facility_id=scope.fid),'[]'::jsonb),
    'teams',coalesce((select jsonb_agg(to_jsonb(t) order by t.created_at,t.id) from public.king_teams t,scope where t.facility_id=scope.fid),'[]'::jsonb),
    'past_games',coalesce((select jsonb_agg(to_jsonb(g) order by g.game_number,g.id) from public.past_games g,scope where g.facility_id=scope.fid),'[]'::jsonb)
  ) || public.capture_hybrid_kotc_state();
$$;

create or replace function public.restore_hybrid_kotc_state(p_state jsonb)
returns void language plpgsql security definer set search_path=public as $$
declare item jsonb; fid uuid:=public.current_facility_id();
begin
  if fid is null then raise exception 'Select a facility first.'; end if;
  delete from public.hybrid_kotc_substitutes where facility_id=fid;
  delete from public.hybrid_kotc_slots where facility_id=fid;
  delete from public.hybrid_kotc_teams where facility_id=fid;
  delete from public.hybrid_kotc_court_state where facility_id=fid;
  for item in select value from jsonb_array_elements(coalesce(p_state->'hybrid_kotc_teams','[]'::jsonb)) loop
    insert into public.hybrid_kotc_teams select * from jsonb_populate_record(null::public.hybrid_kotc_teams,item);
  end loop;
  for item in select value from jsonb_array_elements(coalesce(p_state->'hybrid_kotc_slots','[]'::jsonb)) loop
    insert into public.hybrid_kotc_slots select * from jsonb_populate_record(null::public.hybrid_kotc_slots,item);
  end loop;
  for item in select value from jsonb_array_elements(coalesce(p_state->'hybrid_kotc_substitutes','[]'::jsonb)) loop
    insert into public.hybrid_kotc_substitutes select * from jsonb_populate_record(null::public.hybrid_kotc_substitutes,item);
  end loop;
  for item in select value from jsonb_array_elements(coalesce(p_state->'hybrid_kotc_court_state','[]'::jsonb)) loop
    insert into public.hybrid_kotc_court_state select * from jsonb_populate_record(null::public.hybrid_kotc_court_state,item);
  end loop;
end;
$$;

revoke all on function public.restore_hybrid_kotc_state(jsonb) from public, anon, authenticated;
grant execute on function public.restore_hybrid_kotc_state(jsonb) to opengym_runtime;

create or replace function public.capture_hybrid_kotc_court_state(p_court_number integer)
returns jsonb language sql security definer set search_path=public as $$
  with scope as (select public.current_facility_id() as fid), teams as (
    select t.* from public.hybrid_kotc_teams t,scope
    where t.facility_id=scope.fid and t.court_number=p_court_number
  )
  select jsonb_build_object(
    'hybrid_kotc_teams',coalesce((select jsonb_agg(to_jsonb(t) order by t.court_side,t.created_at) from teams t),'[]'::jsonb),
    'hybrid_kotc_slots',coalesce((select jsonb_agg(to_jsonb(s) order by s.team_id,s.slot_number) from public.hybrid_kotc_slots s join teams t on t.id=s.team_id where s.facility_id=(select fid from scope)),'[]'::jsonb),
    'hybrid_kotc_substitutes',coalesce((select jsonb_agg(to_jsonb(s) order by s.team_id,s.player_id) from public.hybrid_kotc_substitutes s join teams t on t.id=s.team_id where s.facility_id=(select fid from scope)),'[]'::jsonb),
    'hybrid_kotc_court_state',coalesce((select jsonb_agg(to_jsonb(s)) from public.hybrid_kotc_court_state s,scope where s.facility_id=scope.fid and s.court_number=p_court_number),'[]'::jsonb)
  );
$$;

revoke all on function public.capture_hybrid_kotc_court_state(integer) from public, anon, authenticated;
grant execute on function public.capture_hybrid_kotc_court_state(integer) to opengym_runtime;

-- Comparison payloads deliberately exclude audit timestamps only.  In
-- particular, slot player/group/origin fields and team streak remain semantic.
create or replace function public.hybrid_court_reversal_fields(p_kind text,p_row jsonb)
returns jsonb language sql immutable set search_path=public as $$
  select case p_kind
    when 'hybrid_teams' then coalesce(p_row,'{}'::jsonb)-array['created_at','updated_at']
    when 'hybrid_slots' then coalesce(p_row,'{}'::jsonb)-array['created_at','updated_at']
    when 'hybrid_substitutes' then coalesce(p_row,'{}'::jsonb)-array['created_at']
    when 'hybrid_court_state' then coalesce(p_row,'{}'::jsonb)-array['updated_at']
    else coalesce(p_row,'{}'::jsonb)
  end;
$$;

revoke all on function public.hybrid_court_reversal_fields(text,jsonb) from public, anon, authenticated;
grant execute on function public.hybrid_court_reversal_fields(text,jsonb) to opengym_runtime;

create or replace function public.apply_hybrid_court_reverse(p_before jsonb,p_after jsonb,p_court integer)
returns void language plpgsql security definer set search_path=public as $$
declare fid uuid:=public.current_facility_id(); expected bigint; live bigint; item record; before_row jsonb; after_row jsonb; live_row jsonb; row_id uuid; key text;
begin
  select (value->>'version')::bigint into expected from jsonb_array_elements(coalesce(p_after->'hybrid_kotc_court_state','[]')) value;
  if expected is null then return; end if;
  select version into live from public.hybrid_kotc_court_state where facility_id=fid and court_number=p_court for update;
  -- A higher version may be a later, semantically mergeable CURRENT action.
  -- The entity-level PRE/POST/CURRENT checks below preserve it; an older
  -- version cannot be derived from this exact historical POST and remains stale.
  if live is null or live < expected then raise exception 'This Waitlist KOTC court changed. Refresh and try again.'; end if;
  -- Delete only POST-created children/teams whose live semantic state still equals POST.
  for item in select b.value before_row,a.value after_row from jsonb_array_elements(coalesce(p_before->'hybrid_kotc_substitutes','[]')) b full join jsonb_array_elements(coalesce(p_after->'hybrid_kotc_substitutes','[]')) a on a.value->>'id'=b.value->>'id' loop
    if item.before_row is null and item.after_row is not null then select to_jsonb(s) into live_row from public.hybrid_kotc_substitutes s where s.id=(item.after_row->>'id')::uuid and s.facility_id=fid for update; if public.hybrid_court_reversal_fields('hybrid_substitutes',live_row)=public.hybrid_court_reversal_fields('hybrid_substitutes',item.after_row) then delete from public.hybrid_kotc_substitutes where id=(item.after_row->>'id')::uuid and facility_id=fid; end if; end if;
  end loop;
  for item in select b.value before_row,a.value after_row from jsonb_array_elements(coalesce(p_before->'hybrid_kotc_slots','[]')) b full join jsonb_array_elements(coalesce(p_after->'hybrid_kotc_slots','[]')) a on a.value->>'id'=b.value->>'id' loop
    if item.before_row is null and item.after_row is not null then select to_jsonb(s) into live_row from public.hybrid_kotc_slots s where s.id=(item.after_row->>'id')::uuid and s.facility_id=fid for update; if public.hybrid_court_reversal_fields('hybrid_slots',live_row)=public.hybrid_court_reversal_fields('hybrid_slots',item.after_row) then delete from public.hybrid_kotc_slots where id=(item.after_row->>'id')::uuid and facility_id=fid; end if; end if;
  end loop;
  for item in select b.value before_row,a.value after_row from jsonb_array_elements(coalesce(p_before->'hybrid_kotc_teams','[]')) b full join jsonb_array_elements(coalesce(p_after->'hybrid_kotc_teams','[]')) a on a.value->>'id'=b.value->>'id' loop
    if item.before_row is null and item.after_row is not null then select to_jsonb(t) into live_row from public.hybrid_kotc_teams t where t.id=(item.after_row->>'id')::uuid and t.facility_id=fid and t.court_number=p_court for update; if public.hybrid_court_reversal_fields('hybrid_teams',live_row)=public.hybrid_court_reversal_fields('hybrid_teams',item.after_row) and not exists(select 1 from public.hybrid_kotc_slots s where s.team_id=(item.after_row->>'id')::uuid) and not exists(select 1 from public.hybrid_kotc_substitutes s where s.team_id=(item.after_row->>'id')::uuid) then delete from public.hybrid_kotc_teams where id=(item.after_row->>'id')::uuid and facility_id=fid and court_number=p_court; end if; end if;
  end loop;
  -- Recreate/update parents before children only when the live row still equals POST or is absent.
  for item in select b.value before_row,a.value after_row from jsonb_array_elements(coalesce(p_before->'hybrid_kotc_teams','[]')) b full join jsonb_array_elements(coalesce(p_after->'hybrid_kotc_teams','[]')) a on a.value->>'id'=b.value->>'id' loop
    if item.before_row is not null then
      select to_jsonb(t) into live_row from public.hybrid_kotc_teams t where t.id=(item.before_row->>'id')::uuid and t.facility_id=fid for update;
      if live_row is null then
        insert into public.hybrid_kotc_teams select * from jsonb_populate_record(null::public.hybrid_kotc_teams,item.before_row);
      elsif public.hybrid_court_reversal_fields('hybrid_teams',live_row)=public.hybrid_court_reversal_fields('hybrid_teams',item.after_row) then
        -- A later CURRENT successor may legitimately own this semantic side.
        -- Restore the historical PRE row only when that cannot create a second
        -- active owner; its child merge below still restores only unchanged
        -- historical entities and preserves successor mutations.
        if item.before_row->>'status'<>'current' or not exists(
          select 1 from public.hybrid_kotc_teams successor
          where successor.facility_id=fid and successor.court_number=p_court
            and successor.court_side=(item.before_row->>'court_side')::smallint
            and successor.status='current' and successor.id<>(item.before_row->>'id')::uuid
        ) then
          update public.hybrid_kotc_teams set status=item.before_row->>'status',consecutive_wins=(item.before_row->>'consecutive_wins')::integer,updated_at=now() where id=(item.before_row->>'id')::uuid and facility_id=fid;
        end if;
      end if;
    end if;
  end loop;
  -- Restore slot/substitute rows only when their current semantic state is still
  -- the game-produced POST state. Later Fill In/swap rows are therefore kept.
  for item in select b.value before_row,a.value after_row from jsonb_array_elements(coalesce(p_before->'hybrid_kotc_slots','[]')) b full join jsonb_array_elements(coalesce(p_after->'hybrid_kotc_slots','[]')) a on a.value->>'id'=b.value->>'id' loop
    row_id:=coalesce((item.before_row->>'id')::uuid,(item.after_row->>'id')::uuid); select to_jsonb(s) into live_row from public.hybrid_kotc_slots s where s.id=row_id and s.facility_id=fid for update;
    if item.before_row is null then if public.hybrid_court_reversal_fields('hybrid_slots',live_row)=public.hybrid_court_reversal_fields('hybrid_slots',item.after_row) then delete from public.hybrid_kotc_slots where id=row_id and facility_id=fid; end if;
    elsif live_row is null then
      -- Do not recreate a historical slot when CURRENT already has a canonical
      -- active successor owner for that player.  The side-owner merge above
      -- selected that successor; this retains its six-slot semantics.
      if item.before_row->>'player_id' is null or not exists(
        select 1 from public.hybrid_kotc_slots owned join public.hybrid_kotc_teams owner on owner.id=owned.team_id and owner.facility_id=owned.facility_id
        where owned.facility_id=fid and owned.player_id=(item.before_row->>'player_id')::uuid and owner.status='current'
        union all
        select 1 from public.hybrid_kotc_substitutes owned join public.hybrid_kotc_teams owner on owner.id=owned.team_id and owner.facility_id=owned.facility_id
        where owned.facility_id=fid and owned.player_id=(item.before_row->>'player_id')::uuid and owner.status='current'
      ) then insert into public.hybrid_kotc_slots select * from jsonb_populate_record(null::public.hybrid_kotc_slots,item.before_row); end if;
    elsif public.hybrid_court_reversal_fields('hybrid_slots',live_row)=public.hybrid_court_reversal_fields('hybrid_slots',item.after_row) then
      if item.before_row->>'player_id' is null or not exists(
        select 1 from public.hybrid_kotc_slots owned join public.hybrid_kotc_teams owner on owner.id=owned.team_id and owner.facility_id=owned.facility_id
        where owned.facility_id=fid and owned.player_id=(item.before_row->>'player_id')::uuid and owner.status='current' and owned.id<>row_id
        union all
        select 1 from public.hybrid_kotc_substitutes owned join public.hybrid_kotc_teams owner on owner.id=owned.team_id and owner.facility_id=owned.facility_id
        where owned.facility_id=fid and owned.player_id=(item.before_row->>'player_id')::uuid and owner.status='current'
      ) then delete from public.hybrid_kotc_slots where id=row_id and facility_id=fid; insert into public.hybrid_kotc_slots select * from jsonb_populate_record(null::public.hybrid_kotc_slots,item.before_row); end if;
    end if;
  end loop;
  for item in select b.value before_row,a.value after_row from jsonb_array_elements(coalesce(p_before->'hybrid_kotc_substitutes','[]')) b full join jsonb_array_elements(coalesce(p_after->'hybrid_kotc_substitutes','[]')) a on a.value->>'id'=b.value->>'id' loop
    row_id:=coalesce((item.before_row->>'id')::uuid,(item.after_row->>'id')::uuid); select to_jsonb(s) into live_row from public.hybrid_kotc_substitutes s where s.id=row_id and s.facility_id=fid for update;
    if item.before_row is null then if public.hybrid_court_reversal_fields('hybrid_substitutes',live_row)=public.hybrid_court_reversal_fields('hybrid_substitutes',item.after_row) then delete from public.hybrid_kotc_substitutes where id=row_id and facility_id=fid; end if;
    elsif live_row is null then insert into public.hybrid_kotc_substitutes select * from jsonb_populate_record(null::public.hybrid_kotc_substitutes,item.before_row);
    elsif public.hybrid_court_reversal_fields('hybrid_substitutes',live_row)=public.hybrid_court_reversal_fields('hybrid_substitutes',item.after_row) then delete from public.hybrid_kotc_substitutes where id=row_id and facility_id=fid; insert into public.hybrid_kotc_substitutes select * from jsonb_populate_record(null::public.hybrid_kotc_substitutes,item.before_row); end if;
  end loop;
  update public.hybrid_kotc_court_state set version=version+1,updated_at=now() where facility_id=fid and court_number=p_court and version=live;
  if not found then raise exception 'This Waitlist KOTC court changed. Refresh and try again.'; end if;
end;
$$;

-- Preserve the mature legacy merge by calling it first; PostgreSQL function calls
-- share this transaction, so any hybrid error rolls back the legacy reversal too.
alter function public.reverse_past_game(uuid) rename to reverse_past_game_legacy;
create or replace function public.reverse_past_game(p_game_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare saved public.court_game_reversals; game public.past_games; result jsonb;
begin
  select * into game from public.past_games where id=p_game_id and facility_id=public.current_facility_id() for update;
  select * into saved from public.court_game_reversals where game_id=p_game_id and facility_id=public.current_facility_id();
  result:=public.reverse_past_game_legacy(p_game_id);
  if saved.game_id is not null then perform public.apply_hybrid_court_reverse(saved.before_state,saved.after_state,game.court_number); end if;
  return result;
end;
$$;
revoke all on function public.apply_hybrid_court_reverse(jsonb,jsonb,integer) from public, anon, authenticated;
grant execute on function public.apply_hybrid_court_reverse(jsonb,jsonb,integer) to opengym_runtime;
revoke all on function public.reverse_past_game_legacy(uuid) from public, anon;
revoke all on function public.reverse_past_game(uuid) from public, anon;
grant execute on function public.reverse_past_game(uuid) to authenticated;

alter function public.capture_court_reversal_state() rename to capture_court_reversal_state_legacy;
create or replace function public.capture_court_reversal_state()
returns jsonb language sql security definer set search_path=public as $$
  select public.capture_court_reversal_state_legacy() || public.capture_hybrid_kotc_state();
$$;

-- The legacy callers capture their pre-game state before they pass the court
-- number to record_court_reversal.  Keep that stable API, but trim hybrid
-- families at record time so an exact reversal record can never carry Court 2
-- (or another court's) temporary state.
create or replace function public.filter_hybrid_court_snapshot(p_state jsonb,p_court integer)
returns jsonb language sql security definer set search_path=public as $$
  with teams as (
    select value as row from jsonb_array_elements(coalesce(p_state->'hybrid_kotc_teams','[]'::jsonb))
    where (value->>'court_number')::integer=p_court
  ), team_ids as (select row->>'id' as id from teams)
  select jsonb_build_object(
    'hybrid_kotc_teams',coalesce((select jsonb_agg(row order by (row->>'court_side')::integer,row->>'id') from teams),'[]'::jsonb),
    'hybrid_kotc_slots',coalesce((select jsonb_agg(value order by value->>'team_id',(value->>'slot_number')::integer)
      from jsonb_array_elements(coalesce(p_state->'hybrid_kotc_slots','[]'::jsonb))
      where value->>'team_id' in (select id from team_ids)),'[]'::jsonb),
    'hybrid_kotc_substitutes',coalesce((select jsonb_agg(value order by value->>'team_id',value->>'id')
      from jsonb_array_elements(coalesce(p_state->'hybrid_kotc_substitutes','[]'::jsonb))
      where value->>'team_id' in (select id from team_ids)),'[]'::jsonb),
    'hybrid_kotc_court_state',coalesce((select jsonb_agg(value)
      from jsonb_array_elements(coalesce(p_state->'hybrid_kotc_court_state','[]'::jsonb))
      where (value->>'court_number')::integer=p_court),'[]'::jsonb)
  );
$$;
revoke all on function public.filter_hybrid_court_snapshot(jsonb,integer) from public, anon, authenticated;

create or replace function public.record_court_reversal(p_before jsonb,p_court integer)
returns void language plpgsql security definer set search_path=public as $$
declare gid uuid; old_game integer; fid uuid:=public.current_facility_id(); after_state jsonb; before_state jsonb; captured_after jsonb;
begin
  select (c->>'game_number')::integer into old_game from jsonb_array_elements(p_before->'courts') c where (c->>'court_number')::integer=p_court;
  select id into gid from public.past_games where facility_id=fid and court_number=p_court and game_number=old_game;
  if gid is null then raise exception 'Could not save this game for reversal.'; end if;
  before_state:=p_before || public.filter_hybrid_court_snapshot(p_before,p_court);
  captured_after:=public.capture_court_reversal_state();
  after_state:=captured_after || public.filter_hybrid_court_snapshot(captured_after,p_court);
  insert into public.court_game_reversals(game_id,facility_id,before_state,after_state) values(gid,fid,before_state,after_state)
  on conflict(game_id) do update set before_state=excluded.before_state,after_state=excluded.after_state,facility_id=excluded.facility_id,created_at=now();
  update public.past_games set reversible=true where facility_id=fid and id=gid;
end;
$$;

-- Keep the existing full restore semantics; hybrid children are restored only
-- after their referenced players and before any mode helper can rearrange state.
create or replace function public.restore_waitlist_state(p_state jsonb)
returns void language plpgsql security definer set search_path=public as $$
declare item jsonb; restored_court_count integer; fid uuid:=public.current_facility_id();
begin
  if fid is null then raise exception 'Select a facility first.'; end if;
  delete from public.waitlist_players where facility_id=fid;
  delete from public.king_teams where facility_id=fid;
  for item in select value from jsonb_array_elements(coalesce(p_state->'teams','[]'::jsonb)) loop
    insert into public.king_teams(id,facility_id,name,status,queue_position,court_number,court_side,consecutive_wins,created_at,updated_at)
    values((item->>'id')::uuid,fid,item->>'name',item->>'status',(item->>'queue_position')::bigint,nullif(item->>'court_number','')::integer,nullif(item->>'court_side','')::integer,coalesce((item->>'consecutive_wins')::integer,0),(item->>'created_at')::timestamptz,now());
  end loop;
  for item in select value from jsonb_array_elements(coalesce(p_state->'players','[]'::jsonb)) loop
    insert into public.waitlist_players(id,facility_id,user_id,first_name,last_name,display_name,status,queue_position,restricted,rejoin_expires_at,created_at,updated_at,group_id,is_host,sitout_priority,sitout_from_game,court_number,team_id)
    values((item->>'id')::uuid,fid,nullif(item->>'user_id','')::uuid,item->>'first_name',item->>'last_name',item->>'display_name',item->>'status',nullif(item->>'queue_position','')::bigint,coalesce((item->>'restricted')::boolean,false),nullif(item->>'rejoin_expires_at','')::timestamptz,(item->>'created_at')::timestamptz,now(),nullif(item->>'group_id','')::uuid,coalesce((item->>'is_host')::boolean,false),coalesce((item->>'sitout_priority')::boolean,false),nullif(item->>'sitout_from_game','')::integer,nullif(item->>'court_number','')::integer,nullif(item->>'team_id','')::uuid);
  end loop;
  perform public.restore_hybrid_kotc_state(p_state);
  restored_court_count:=coalesce(nullif(p_state->'config'->>'court_count','')::integer,1);
  update public.waitlist_config set game_number=(p_state->'config'->>'game_number')::integer,max_players=(p_state->'config'->>'max_players')::integer,court_count=restored_court_count,mode=p_state->'config'->>'mode',king_max_wins=nullif(p_state->'config'->>'king_max_wins','')::integer,hybrid_rotation_rule=coalesce(p_state->'config'->>'hybrid_rotation_rule','two_on_two_off'),hybrid_auto_kotc_threshold_teams=nullif(p_state->'config'->>'hybrid_auto_kotc_threshold_teams','')::integer,hybrid_auto_kotc_armed=coalesce((p_state->'config'->>'hybrid_auto_kotc_armed')::boolean,true),updated_at=now() where facility_id=fid and id;
  delete from public.waitlist_courts where facility_id=fid;
  for item in select value from jsonb_array_elements(coalesce(p_state->'courts','[]'::jsonb)) loop
    insert into public.waitlist_courts(facility_id,court_number,game_number,started_at,team_mode,team_max_wins) values(fid,(item->>'court_number')::integer,(item->>'game_number')::integer,(item->>'started_at')::timestamptz,coalesce(item->>'team_mode','rotation'),nullif(item->>'team_max_wins','')::integer);
  end loop;
  delete from public.past_games where facility_id=fid;
  for item in select value from jsonb_array_elements(coalesce(p_state->'past_games','[]'::jsonb)) loop
    insert into public.past_games(id,facility_id,game_number,player_names,ended_at,court_number) values((item->>'id')::uuid,fid,(item->>'game_number')::integer,item->'player_names',(item->>'ended_at')::timestamptz,coalesce(nullif(item->>'court_number','')::integer,1));
  end loop;
  perform public.king_fill_courts(); perform public.king_repair_initial_team_names();
end;
$$;
