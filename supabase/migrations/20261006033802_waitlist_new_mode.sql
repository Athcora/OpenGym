-- Waitlist (New): the Rejoin waitlist plus per-court King of the Court and
-- party substitutes.
--
-- Design notes
-- * The facility stays in "mode = 'rejoin'". A separate per-facility flag
--   ("wl_facility_settings.enabled") turns on the extra features, so every
--   existing Rejoin behaviour (queue, rejoin prompts/timers, sit-out, groups,
--   hosts, undo/redo, reversal, geofence) is reused unchanged.
-- * Per-court format settings live in their own table so the existing
--   undo/restore helpers, which rebuild "waitlist_courts", never reset them.
-- * The King and win streak are stored per court *and game number*. Reversing
--   a game rolls the court's game number back, which automatically restores
--   the previous King/streak without changing any reversal helper.
-- * There are no sides and no team slots: the current game is still the plain
--   Rejoin current-game list for each court.
-- * The only existing function changed is "fill_open_court_slots()", which now
--   skips active party substitutes so they never take a spot in a game.
begin;

do $$
begin
  if to_regprocedure('public.end_court_game(integer)') is null
     or to_regprocedure('public.fill_open_court_slots()') is null
     or to_regprocedure('public.assert_expected_court_game(uuid,integer,integer)') is null
     or to_regprocedure('public.assert_expected_facility(uuid)') is null
     or to_regprocedure('public.capture_court_reversal_state()') is null
     or to_regprocedure('public.record_court_reversal(jsonb,integer)') is null
     or to_regprocedure('public.save_admin_undo(text)') is null
     or to_regprocedure('public.set_open_gym_mode(text)') is null then
    raise exception 'Waitlist (New) requires the current Rejoin waitlist functions.';
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------
create table if not exists public.wl_facility_settings(
  facility_id uuid primary key references public.facilities(id) on delete cascade,
  enabled boolean not null default false,
  updated_at timestamptz not null default now()
);

create table if not exists public.wl_court_settings(
  facility_id uuid not null references public.facilities(id) on delete cascade,
  court_number integer not null check (court_number between 1 and 12),
  -- format: the admin's choice. threshold_teams: switch to the other format
  -- once there are this many teams (players / 6), and back when it drops.
  -- active_format: the format the court is playing right now.
  format text not null default 'two_on_two_off' check (format in ('two_on_two_off','kotc')),
  threshold_teams integer check (threshold_teams between 3 and 7),
  active_format text not null default 'two_on_two_off' check (active_format in ('two_on_two_off','kotc')),
  max_wins integer check (max_wins in (2,3)),
  updated_at timestamptz not null default now(),
  primary key(facility_id,court_number)
);

create table if not exists public.wl_kotc_state(
  facility_id uuid not null references public.facilities(id) on delete cascade,
  court_number integer not null check (court_number between 1 and 12),
  game_number integer not null,
  king_player_ids uuid[] not null default '{}',
  streak integer not null default 0 check (streak >= 0),
  updated_at timestamptz not null default now(),
  primary key(facility_id,court_number,game_number)
);

create table if not exists public.wl_party_substitutes(
  id uuid primary key default gen_random_uuid(),
  facility_id uuid not null references public.facilities(id) on delete cascade,
  group_id uuid not null,
  -- No foreign key: undo/reverse rebuild waitlist_players with the same ids,
  -- and a cascade would silently drop every substitute.
  player_id uuid not null,
  created_at timestamptz not null default now(),
  unique(player_id)
);
create index if not exists wl_party_substitutes_group_idx on public.wl_party_substitutes(facility_id,group_id);

create table if not exists public.wl_substitute_requests(
  id uuid primary key default gen_random_uuid(),
  facility_id uuid not null references public.facilities(id) on delete cascade,
  group_id uuid not null,
  requester_id uuid,
  target_id uuid not null,
  status text not null default 'pending' check (status in ('pending','accepted','declined','cancelled')),
  created_at timestamptz not null default now(),
  answered_at timestamptz
);
create index if not exists wl_substitute_requests_pending_idx on public.wl_substitute_requests(facility_id,status,created_at);

do $$
declare t text;
begin
  foreach t in array array['wl_facility_settings','wl_court_settings','wl_kotc_state','wl_party_substitutes','wl_substitute_requests'] loop
    execute format('alter table public.%I enable row level security',t);
    execute format('drop policy if exists facility_isolation on public.%I',t);
    execute format('create policy facility_isolation on public.%I as restrictive for all to public using (facility_id=public.current_facility_id()) with check (facility_id=public.current_facility_id())',t);
    execute format('drop policy if exists runtime_facility_access on public.%I',t);
    execute format('create policy runtime_facility_access on public.%I as permissive for all to opengym_runtime using (true) with check (true)',t);
    execute format('drop policy if exists %I on public.%I',t||'_read',t);
    execute format('create policy %I on public.%I as permissive for select to authenticated using (facility_id=public.current_facility_id())',t||'_read',t);
    execute format('revoke all on public.%I from anon, authenticated',t);
    execute format('grant select on public.%I to authenticated',t);
    execute format('grant select, insert, update, delete on public.%I to opengym_runtime',t);
  end loop;
end;
$$;

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- Substitutes count only while their party still has active members and the
-- substitute is still an ungrouped, active player.
create or replace function public.wl_active_substitute_ids(p_facility_id uuid)
returns setof uuid language sql stable security definer set search_path=public as $$
  select s.player_id
  from public.wl_party_substitutes s
  join public.waitlist_players sub on sub.id=s.player_id and sub.facility_id=s.facility_id
  where s.facility_id=p_facility_id
    and sub.status in ('current','waiting','sitout')
    and sub.group_id is null
    and exists(
      select 1 from public.waitlist_players g
      where g.facility_id=s.facility_id and g.group_id=s.group_id
        and g.status in ('current','waiting','sitout','rejoin')
    );
$$;

-- "Teams" for the automatic format threshold: everyone checked in, divided by 6.
create or replace function public.wl_team_count(p_facility_id uuid)
returns integer language sql stable security definer set search_path=public as $$
  select (count(*)/6)::integer
  from public.waitlist_players
  where facility_id=p_facility_id and status in ('current','waiting','sitout','rejoin');
$$;

create or replace function public.wl_is_enabled(p_facility_id uuid)
returns boolean language sql stable security definer set search_path=public as $$
  select coalesce((select s.enabled from public.wl_facility_settings s where s.facility_id=p_facility_id),false)
     and exists(select 1 from public.waitlist_config c where c.facility_id=p_facility_id and c.id and c.mode='rejoin');
$$;

-- Applies the court's "until there are N teams" rule after a game has advanced:
-- below N teams the court plays the admin's format, at N or more the other one.
create or replace function public.wl_apply_auto_format(p_facility_id uuid,p_court_number integer,p_game_number integer)
returns text language plpgsql security definer set search_path=public as $$
declare s public.wl_court_settings; desired text;
begin
  select * into s from public.wl_court_settings where facility_id=p_facility_id and court_number=p_court_number for update;
  if s.facility_id is null or s.threshold_teams is null then return coalesce(s.active_format,'two_on_two_off'); end if;
  desired:=case when public.wl_team_count(p_facility_id)>=s.threshold_teams
                then case when s.format='kotc' then 'two_on_two_off' else 'kotc' end
                else s.format end;
  if desired<>s.active_format then
    update public.wl_court_settings set active_format=desired,updated_at=now() where facility_id=p_facility_id and court_number=p_court_number;
    if desired='two_on_two_off' then
      delete from public.wl_kotc_state where facility_id=p_facility_id and court_number=p_court_number and game_number=p_game_number;
    end if;
  end if;
  return desired;
end;
$$;

-- ---------------------------------------------------------------------------
-- Existing allocator: never place an active party substitute into a game.
-- Patched in place so the deployed body (including its KOTC guard) is kept.
-- ---------------------------------------------------------------------------
do $$
declare def text; patched text;
begin
  def:=pg_get_functiondef('public.fill_open_court_slots()'::regprocedure);
  if position('wl_active_substitute_ids' in def)>0 then return; end if;
  if (length(def)-length(replace(def,'p.status=''waiting''','')))/length('p.status=''waiting''')<>1 then
    raise exception 'fill_open_court_slots() changed; expected exactly one waiting-candidate predicate.';
  end if;
  patched:=replace(def,'p.status=''waiting''','p.status=''waiting''
        and p.id not in (select public.wl_active_substitute_ids(fid))');
  execute patched;
end;
$$;

-- ---------------------------------------------------------------------------
-- Mode and court settings
-- ---------------------------------------------------------------------------
create or replace function public.set_waitlist_new_mode(p_facility_id uuid,p_enabled boolean)
returns jsonb language plpgsql security definer set search_path=public as $$
declare fid uuid; cfg public.waitlist_config; actor text;
begin
  perform public.assert_expected_facility(p_facility_id);
  fid:=public.current_facility_id();
  if not public.is_waitlist_admin() then raise exception 'Admin access required.'; end if;
  select * into cfg from public.waitlist_config where facility_id=fid and id;
  if p_enabled and cfg.mode<>'rejoin' then perform public.set_open_gym_mode('rejoin'); end if;
  insert into public.wl_facility_settings(facility_id,enabled,updated_at) values(fid,coalesce(p_enabled,false),now())
    on conflict(facility_id) do update set enabled=excluded.enabled,updated_at=now();
  select coalesce(display_name,'Admin') into actor from public.waitlist_players where facility_id=fid and user_id=public.current_request_user_id();
  insert into public.waitlist_events(facility_id,actor_user_id,actor_name,event_type,message)
    values(fid,public.current_request_user_id(),coalesce(actor,'Admin'),'wl_mode',
      case when p_enabled then 'The waitlist is now Waitlist (New).' else 'The waitlist is now the Rejoin waitlist.' end);
  return jsonb_build_object('message',case when p_enabled then 'Switched to Waitlist (New).' else 'Switched to Rejoin waitlist.' end);
end;
$$;

-- Leaving Rejoin through any other mode switch turns Waitlist (New) off.
create or replace function public.wl_clear_on_mode_change()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  if new.mode is distinct from 'rejoin' then
    update public.wl_facility_settings set enabled=false,updated_at=now() where facility_id=new.facility_id and enabled;
  end if;
  return new;
end;
$$;
drop trigger if exists wl_clear_on_mode_change on public.waitlist_config;
create trigger wl_clear_on_mode_change after update of mode on public.waitlist_config
  for each row when (old.mode is distinct from new.mode) execute function public.wl_clear_on_mode_change();

create or replace function public.configure_waitlist_court(
  p_facility_id uuid,p_court_number integer,p_format text,p_threshold_teams integer,p_max_wins integer
) returns jsonb language plpgsql security definer set search_path=public as $$
declare fid uuid; court public.waitlist_courts; label text; actor text;
begin
  perform public.assert_expected_facility(p_facility_id);
  fid:=public.current_facility_id();
  if not public.is_waitlist_admin() then raise exception 'Admin access required.'; end if;
  if not public.wl_is_enabled(fid) then raise exception 'Switch the facility to Waitlist (New) first.'; end if;
  if p_format not in ('two_on_two_off','kotc') then raise exception 'Choose 2 on 2 off or King of the Court.'; end if;
  if p_threshold_teams is not null and p_threshold_teams not between 3 and 7 then raise exception 'Choose 3 to 7 teams, or Unlimited.'; end if;
  if p_max_wins is not null and p_max_wins not in (2,3) then raise exception 'Choose 2, 3, or Unlimited consecutive games.'; end if;
  select * into court from public.waitlist_courts where facility_id=fid and court_number=p_court_number;
  if court.court_number is null then raise exception 'That court is not active.'; end if;
  perform 1 from public.wl_court_settings where facility_id=fid and court_number=p_court_number for update;
  -- The admin's choice applies right away; the team-count rule is checked
  -- again at every Next game.
  insert into public.wl_court_settings(facility_id,court_number,format,threshold_teams,max_wins,active_format,updated_at)
    values(fid,p_court_number,p_format,p_threshold_teams,p_max_wins,p_format,now())
    on conflict(facility_id,court_number) do update
      set format=excluded.format,threshold_teams=excluded.threshold_teams,max_wins=excluded.max_wins,
          active_format=excluded.active_format,updated_at=now();
  if p_format='two_on_two_off' then
    -- Switching a court back to 2 on 2 off resets its win streak.
    delete from public.wl_kotc_state where facility_id=fid and court_number=p_court_number and game_number=court.game_number;
  end if;
  label:=case when p_format='kotc' then 'King of the Court' else '2 on 2 off' end
    ||case when p_threshold_teams is null then '' else ' until there are '||p_threshold_teams||' teams' end
    ||case when p_format='kotc' or p_threshold_teams is not null
           then case when p_max_wins is null then ' (no game limit)' else ' ('||p_max_wins||' consecutive games max)' end
           else '' end;
  select coalesce(display_name,'Admin') into actor from public.waitlist_players where facility_id=fid and user_id=public.current_request_user_id();
  insert into public.waitlist_events(facility_id,actor_user_id,actor_name,event_type,message)
    values(fid,public.current_request_user_id(),coalesce(actor,'Admin'),'wl_court_rules','Court '||p_court_number||' is now '||label||'.');
  return jsonb_build_object('message','Court '||p_court_number||' is now '||label||'.','format',p_format);
end;
$$;

-- ---------------------------------------------------------------------------
-- Next game on a 2 on 2 off court (plain Rejoin advance + threshold rule)
-- ---------------------------------------------------------------------------
create or replace function public.advance_waitlist_court_game(p_court_number integer,p_facility_id uuid,p_expected_game_number integer)
returns jsonb language plpgsql security definer set search_path=public as $$
declare fid uuid; fmt text; res jsonb; new_format text;
begin
  perform public.assert_expected_court_game(p_facility_id,p_court_number,p_expected_game_number);
  fid:=public.current_facility_id();
  if not public.wl_is_enabled(fid) then raise exception 'This facility is not using Waitlist (New). Refresh and try again.'; end if;
  select active_format into fmt from public.wl_court_settings where facility_id=fid and court_number=p_court_number;
  if coalesce(fmt,'two_on_two_off')='kotc' then
    raise exception 'This court is playing King of the Court. Report whether you won or lost.';
  end if;
  res:=public.end_court_game(p_court_number);
  new_format:=public.wl_apply_auto_format(fid,p_court_number,(res->>'game_number')::integer);
  return res||jsonb_build_object('format',new_format);
end;
$$;

-- ---------------------------------------------------------------------------
-- Next game on a King of the Court court
-- ---------------------------------------------------------------------------
create or replace function public.advance_waitlist_kotc_game(
  p_court_number integer,p_facility_id uuid,p_expected_game_number integer,p_result text,p_team_player_ids uuid[]
) returns jsonb language plpgsql security definer set search_path=public as $$
declare
  fid uuid; cfg public.waitlist_config; court public.waitlist_courts; settings public.wl_court_settings;
  caller public.waitlist_players; reversal_before jsonb;
  on_court uuid[]; team uuid[]; staying uuid[]; leaving uuid[];
  prev public.wl_kotc_state; prev_streak integer:=0; overlap integer; new_streak integer:=0; winner_stays boolean;
  history_game integer; last_position bigint; next_game integer; response_rows jsonb:='[]'::jsonb;
  open_spots integer; short_by integer:=0; blk record; waiting_available integer;
  min_team integer; max_team integer; bad_group uuid; result text:=lower(coalesce(p_result,''));
  actor text; short_message text:=''; new_format text;
begin
  perform public.assert_expected_court_game(p_facility_id,p_court_number,p_expected_game_number);
  fid:=public.current_facility_id();
  perform pg_advisory_xact_lock(7429101); perform public.repair_facility_court_assignments(fid);
  select * into cfg from public.waitlist_config where facility_id=fid and id for update;
  if cfg.mode<>'rejoin' or not public.wl_is_enabled(fid) then raise exception 'King of the Court results are only available in Waitlist (New).'; end if;
  if result not in ('win','lose') then raise exception 'Choose Win or Lose.'; end if;
  select * into court from public.waitlist_courts where facility_id=fid and court_number=p_court_number for update;
  if court.court_number is null then raise exception 'That court is not active.'; end if;
  select * into settings from public.wl_court_settings where facility_id=fid and court_number=p_court_number for update;
  if coalesce(settings.active_format,'two_on_two_off')<>'kotc' then raise exception 'This court is playing 2 on 2 off. Use Next game.'; end if;
  select * into caller from public.waitlist_players where facility_id=fid and user_id=public.current_request_user_id();
  if not public.is_waitlist_operator() and (caller.id is null or caller.status<>'current' or caller.court_number<>p_court_number or caller.restricted) then
    raise exception 'Only an unrestricted player on this court or an admin/host can start its next game.';
  end if;

  select coalesce(array_agg(id order by queue_position,id),'{}') into on_court
    from public.waitlist_players where facility_id=fid and status='current' and court_number=p_court_number;
  select count(*) into waiting_available from public.waitlist_players p
    where p.facility_id=fid and p.status='waiting' and p.id not in (select public.wl_active_substitute_ids(fid));
  if waiting_available=0 then raise exception 'There''s no one on the waitlist yet. Try again once more people show up.'; end if;

  select coalesce(array_agg(distinct x),'{}') into team from unnest(coalesce(p_team_player_ids,'{}'::uuid[])) x;
  if exists(select 1 from unnest(team) x where not x=any(on_court)) then raise exception 'Select only players in this court''s current game.'; end if;
  if cardinality(on_court)>=12 then min_team:=6; max_team:=6;
  else min_team:=greatest(1,cardinality(on_court)-6); max_team:=least(6,cardinality(on_court)-1); end if;
  if max_team<1 or cardinality(team)<min_team or cardinality(team)>max_team then raise exception 'You need to select your team of 6.'; end if;
  if caller.id is not null and caller.status='current' and caller.court_number=p_court_number and not caller.id=any(team) then
    raise exception 'Your team must include you.';
  end if;
  select p.group_id into bad_group from public.waitlist_players p
    where p.facility_id=fid and p.status='current' and p.court_number=p_court_number and p.group_id is not null
    group by p.group_id having bool_or(p.id=any(team)) and not bool_and(p.id=any(team)) limit 1;
  if bad_group is not null then raise exception 'Parties must be selected together.'; end if;

  if result='win' then staying:=team;
  else select coalesce(array_agg(x),'{}') into staying from unnest(on_court) x where not x=any(team); end if;

  -- A King keeps its streak when most of the staying players were the King.
  select * into prev from public.wl_kotc_state where facility_id=fid and court_number=p_court_number and game_number=court.game_number;
  if prev.facility_id is not null and prev.streak>0 and cardinality(staying)>0 then
    select count(*) into overlap from unnest(prev.king_player_ids) k where k=any(staying);
    if overlap>0 and overlap*2>=cardinality(staying) then prev_streak:=prev.streak; end if;
  end if;
  -- Same cap rule as Teams mode: with a max of N, a King that wins its Nth
  -- consecutive game leaves too, so all players rotate off.
  winner_stays:=settings.max_wins is null or prev_streak+1<settings.max_wins;
  if winner_stays then new_streak:=prev_streak+1; else staying:='{}'; new_streak:=0; end if;
  select coalesce(array_agg(x),'{}') into leaving from unnest(on_court) x where not x=any(staying);

  -- From here this mirrors end_court_game() for the leaving players only.
  reversal_before:=public.capture_court_reversal_state();
  perform public.save_admin_undo('start next game');
  select coalesce(max(game_number),0)+1 into history_game from public.past_games where facility_id=fid;
  insert into public.past_games(facility_id,game_number,player_names,court_number)
    select fid,history_game,coalesce(jsonb_agg(display_name order by queue_position),'[]'::jsonb),p_court_number
    from public.waitlist_players where facility_id=fid and status='current' and court_number=p_court_number;
  select coalesce(max(queue_position),0) into last_position from public.waitlist_players
    where facility_id=fid and status in('current','waiting','sitout','rejoin');
  with finished as(
    select id,row_number()over(order by queue_position,id) rn from public.waitlist_players
    where facility_id=fid and status='current' and court_number=p_court_number and id=any(leaving)
  ) update public.waitlist_players p set queue_position=last_position+finished.rn,court_number=null,updated_at=now()
    from finished where p.id=finished.id;
  update public.waitlist_players
    set status='rejoin',rejoin_expires_at=now()+case when user_id is null then interval '15 minutes' else interval '5 minutes' end
    where facility_id=fid and status='current' and court_number is null and queue_position>last_position;
  with changed as(
    select * from public.waitlist_players where facility_id=fid and status='rejoin' and queue_position>last_position and user_id is not null
  ), ins as(
    insert into public.rejoin_responses(facility_id,user_id,game_number,original_position,expires_at)
    select fid,user_id,court.game_number+1,queue_position,rejoin_expires_at from changed returning id,user_id
  ) select coalesce(jsonb_agg(jsonb_build_object('user_id',user_id,'response_id',id)),'[]'::jsonb) into response_rows from ins;
  update public.waitlist_players set status='waiting',sitout_from_game=null,updated_at=now()
    where facility_id=fid and status='sitout' and sitout_from_game<=court.game_number;
  next_game:=court.game_number+1;
  update public.waitlist_courts set game_number=next_game,started_at=now() where facility_id=fid and court_number=p_court_number;
  update public.waitlist_config set game_number=greatest(game_number,next_game),updated_at=now() where facility_id=fid and id;

  -- Fill this court in queue order. A party that does not fit the open spots
  -- is skipped and keeps its place at the front of the line.
  select greatest(cfg.max_players-count(*),0) into open_spots from public.waitlist_players
    where facility_id=fid and status='current' and court_number=p_court_number;
  for blk in
    select coalesce(p.group_id,p.id) block_id,count(*)::integer block_size
    from public.waitlist_players p
    where p.facility_id=fid and p.status='waiting' and p.id not in (select public.wl_active_substitute_ids(fid))
    group by coalesce(p.group_id,p.id)
    order by bool_or(p.sitout_priority) desc,min(p.queue_position),coalesce(p.group_id,p.id)
  loop
    exit when open_spots<=0;
    if blk.block_size<=open_spots then
      update public.waitlist_players set status='current',court_number=p_court_number,sitout_priority=false,updated_at=now()
        where facility_id=fid and status='waiting' and coalesce(group_id,id)=blk.block_id
          and id not in (select public.wl_active_substitute_ids(fid));
      open_spots:=open_spots-blk.block_size;
    end if;
  end loop;
  perform public.fill_open_court_slots();
  select greatest(cfg.max_players-count(*),0) into short_by from public.waitlist_players
    where facility_id=fid and status='current' and court_number=p_court_number;
  if short_by>0 then
    short_message:=' There weren''t enough players to make a full team. '||short_by||' more player'||case when short_by=1 then '' else 's' end||' needed.';
  end if;

  insert into public.wl_kotc_state(facility_id,court_number,game_number,king_player_ids,streak,updated_at)
    values(fid,p_court_number,next_game,staying,new_streak,now())
    on conflict(facility_id,court_number,game_number) do update
      set king_player_ids=excluded.king_player_ids,streak=excluded.streak,updated_at=now();
  new_format:=public.wl_apply_auto_format(fid,p_court_number,next_game);

  actor:=coalesce(caller.display_name,'Admin');
  insert into public.waitlist_events(facility_id,actor_user_id,actor_name,event_type,message)
    values(fid,public.current_request_user_id(),actor,'next_game',actor||' started Game '||next_game||' on Court '||p_court_number||'.'||short_message);
  perform public.record_court_reversal(reversal_before,p_court_number);
  return jsonb_build_object(
    'message','Game '||next_game||' started on Court '||p_court_number||'.'||short_message,
    'game_number',next_game,'court_number',p_court_number,'rejoin_prompts',response_rows,
    'short_by',short_by,'win_streak',new_streak,'format',new_format);
end;
$$;

-- ---------------------------------------------------------------------------
-- Party substitutes
-- ---------------------------------------------------------------------------
create or replace function public.request_waitlist_substitute(p_facility_id uuid,p_target_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare fid uuid; caller public.waitlist_players; target public.waitlist_players; party_size integer; sub_count integer;
begin
  perform public.assert_expected_facility(p_facility_id);
  fid:=public.current_facility_id();
  perform pg_advisory_xact_lock(7429204);
  if not public.wl_is_enabled(fid) then raise exception 'Substitutes are only available in Waitlist (New).'; end if;
  select * into caller from public.waitlist_players where facility_id=fid and user_id=public.current_request_user_id()
    and status in ('current','waiting','sitout') for update;
  if caller.id is null or caller.group_id is null then raise exception 'Only members of a full group can add substitutes.'; end if;
  select count(*) into party_size from public.waitlist_players where facility_id=fid and group_id=caller.group_id and status in ('current','waiting','sitout','rejoin');
  if party_size<>6 then raise exception 'Your group needs 6 players before adding substitutes.'; end if;
  select count(*) into sub_count from public.wl_party_substitutes s where s.facility_id=fid and s.group_id=caller.group_id
    and s.player_id in (select public.wl_active_substitute_ids(fid));
  if sub_count>=6 then raise exception 'Your group already has six substitutes.'; end if;
  select * into target from public.waitlist_players where facility_id=fid and id=p_target_id for update;
  if target.id is null or target.status not in ('waiting','sitout') then raise exception 'Choose a player who is waiting in line.'; end if;
  if target.user_id is null then raise exception 'That player was added by an admin and cannot accept an invitation.'; end if;
  if target.group_id is not null then raise exception 'That player is already in a group.'; end if;
  if target.id in (select public.wl_active_substitute_ids(fid)) then raise exception 'That player is already a substitute.'; end if;
  if exists(select 1 from public.wl_substitute_requests where facility_id=fid and group_id=caller.group_id and target_id=target.id
            and status='pending' and created_at>now()-interval '5 minutes') then
    return jsonb_build_object('message','An invitation is already waiting for '||target.display_name||'.');
  end if;
  insert into public.wl_substitute_requests(facility_id,group_id,requester_id,target_id) values(fid,caller.group_id,caller.id,target.id);
  insert into public.waitlist_events(facility_id,actor_user_id,actor_name,event_type,message)
    values(fid,public.current_request_user_id(),caller.display_name,'wl_sub_invite',caller.display_name||' invited '||target.display_name||' to be a substitute.');
  return jsonb_build_object('message','Substitute invitation sent to '||target.display_name||'.');
end;
$$;

create or replace function public.answer_waitlist_substitute(p_request_id uuid,p_accept boolean)
returns jsonb language plpgsql security definer set search_path=public as $$
declare fid uuid:=public.current_facility_id(); request public.wl_substitute_requests; target public.waitlist_players; party_size integer; sub_count integer;
begin
  if fid is null then raise exception 'Select a facility first.'; end if;
  perform pg_advisory_xact_lock(7429204);
  select * into request from public.wl_substitute_requests where facility_id=fid and id=p_request_id and status='pending'
    and created_at>now()-interval '5 minutes' for update;
  if request.id is null then raise exception 'This substitute invitation is no longer available.'; end if;
  select * into target from public.waitlist_players where facility_id=fid and id=request.target_id
    and user_id=public.current_request_user_id() for update;
  if target.id is null then raise exception 'Only the invited player can answer this request.'; end if;
  if not coalesce(p_accept,false) then
    update public.wl_substitute_requests set status='declined',answered_at=now() where id=request.id;
    return jsonb_build_object('message','Substitute invitation declined.');
  end if;
  if target.status not in ('waiting','sitout') or target.group_id is not null then raise exception 'You can only become a substitute while you are waiting in line and not in a group.'; end if;
  select count(*) into party_size from public.waitlist_players where facility_id=fid and group_id=request.group_id and status in ('current','waiting','sitout','rejoin');
  if party_size<>6 then raise exception 'That group no longer has 6 players.'; end if;
  select count(*) into sub_count from public.wl_party_substitutes s where s.facility_id=fid and s.group_id=request.group_id
    and s.player_id in (select public.wl_active_substitute_ids(fid));
  if sub_count>=6 then raise exception 'That group already has six substitutes.'; end if;
  delete from public.wl_party_substitutes where facility_id=fid and player_id=target.id;
  insert into public.wl_party_substitutes(facility_id,group_id,player_id) values(fid,request.group_id,target.id);
  update public.wl_substitute_requests set status='accepted',answered_at=now() where id=request.id;
  update public.wl_substitute_requests set status='cancelled',answered_at=now()
    where facility_id=fid and target_id=target.id and status='pending' and id<>request.id;
  insert into public.waitlist_events(facility_id,actor_user_id,actor_name,event_type,message)
    values(fid,public.current_request_user_id(),target.display_name,'wl_sub_joined',target.display_name||' is now a substitute.');
  return jsonb_build_object('message','You are now a substitute.');
end;
$$;

create or replace function public.remove_waitlist_substitute(p_substitute_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare fid uuid:=public.current_facility_id(); sub public.wl_party_substitutes; caller public.waitlist_players; name text;
begin
  if fid is null then raise exception 'Select a facility first.'; end if;
  perform pg_advisory_xact_lock(7429204);
  select * into sub from public.wl_party_substitutes where facility_id=fid and id=p_substitute_id for update;
  if sub.id is null then raise exception 'That substitute was already removed.'; end if;
  select * into caller from public.waitlist_players where facility_id=fid and user_id=public.current_request_user_id();
  if not public.is_waitlist_operator() and not (caller.id is not null and (caller.id=sub.player_id or caller.group_id=sub.group_id)) then
    raise exception 'Only the group, the substitute, or an admin/host can remove this substitute.';
  end if;
  delete from public.wl_party_substitutes where id=sub.id;
  select display_name into name from public.waitlist_players where id=sub.player_id;
  insert into public.waitlist_events(facility_id,actor_user_id,actor_name,event_type,message)
    values(fid,public.current_request_user_id(),coalesce(caller.display_name,'Admin'),'wl_sub_removed',coalesce(name,'A player')||' is no longer a substitute.');
  return jsonb_build_object('message',coalesce(name,'The player')||' is no longer a substitute.');
end;
$$;

-- A substitute who leaves, or who joins a group, stops being a substitute.
create or replace function public.wl_cleanup_substitute_membership()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  if new.status='left' or new.group_id is not null then
    delete from public.wl_party_substitutes where player_id=new.id;
  end if;
  return new;
end;
$$;
drop trigger if exists wl_cleanup_substitute_membership on public.waitlist_players;
create trigger wl_cleanup_substitute_membership after update of status,group_id on public.waitlist_players
  for each row when (new.status='left' or (new.group_id is not null and old.group_id is distinct from new.group_id))
  execute function public.wl_cleanup_substitute_membership();

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------
revoke all on function public.wl_active_substitute_ids(uuid) from public,anon,authenticated;
grant execute on function public.wl_active_substitute_ids(uuid) to opengym_runtime;
revoke all on function public.wl_team_count(uuid) from public,anon,authenticated;
grant execute on function public.wl_team_count(uuid) to opengym_runtime;
revoke all on function public.wl_is_enabled(uuid) from public,anon,authenticated;
grant execute on function public.wl_is_enabled(uuid) to opengym_runtime;
revoke all on function public.wl_apply_auto_format(uuid,integer,integer) from public,anon,authenticated;
revoke all on function public.wl_clear_on_mode_change() from public,anon,authenticated;
revoke all on function public.wl_cleanup_substitute_membership() from public,anon,authenticated;

revoke all on function public.set_waitlist_new_mode(uuid,boolean) from public,anon;
revoke all on function public.configure_waitlist_court(uuid,integer,text,integer,integer) from public,anon;
revoke all on function public.advance_waitlist_court_game(integer,uuid,integer) from public,anon;
revoke all on function public.advance_waitlist_kotc_game(integer,uuid,integer,text,uuid[]) from public,anon;
revoke all on function public.request_waitlist_substitute(uuid,uuid) from public,anon;
revoke all on function public.answer_waitlist_substitute(uuid,boolean) from public,anon;
revoke all on function public.remove_waitlist_substitute(uuid) from public,anon;
grant execute on function public.set_waitlist_new_mode(uuid,boolean) to authenticated;
grant execute on function public.configure_waitlist_court(uuid,integer,text,integer,integer) to authenticated;
grant execute on function public.advance_waitlist_court_game(integer,uuid,integer) to authenticated;
grant execute on function public.advance_waitlist_kotc_game(integer,uuid,integer,text,uuid[]) to authenticated;
grant execute on function public.request_waitlist_substitute(uuid,uuid) to authenticated;
grant execute on function public.answer_waitlist_substitute(uuid,boolean) to authenticated;
grant execute on function public.remove_waitlist_substitute(uuid) to authenticated;

notify pgrst,'reload schema';
commit;
