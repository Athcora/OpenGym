-- Reversing a game puts the court back exactly as it was.
--
-- The past-games Reverse keeps any player row that changed after the game
-- started ("changes made since then by others were kept"). With held rejoin
-- spots the allocator renumbers the line every time someone taps Rejoin, so
-- players who were seated by the advancement looked "changed" and stayed on
-- the court while the previous lineup was restored around them: 17 players on
-- a 12-player court.
--
-- Now:
--   * Players the advancement moved onto this court, and who are still on it,
--     go back to where they were (waiting / sitting out) in their old order.
--   * Safety net: a court never keeps more than max_players after a reverse;
--     the players furthest back in line go to the front of the waitlist.
begin;

create or replace function public.wl_enforce_court_capacity(p_facility_id uuid)
returns integer
language plpgsql
security definer
set search_path=public
as $$
declare
  cfg public.waitlist_config;
  moved integer:=0;
  n integer;
begin
  select * into cfg from public.waitlist_config where facility_id=p_facility_id and id;
  if cfg.facility_id is null or coalesce(cfg.max_players,0)<=0 or cfg.mode::text ~* '(king|team)' then
    return 0;
  end if;
  with ranked as (
    select p.id,row_number() over(partition by p.court_number
             order by p.line_key nulls last,p.queue_position nulls last,p.id) rn
      from public.waitlist_players p
     where p.facility_id=p_facility_id and p.status='current'
       and not public.is_hybrid_kotc_court(p_facility_id,p.court_number)
  )
  update public.waitlist_players p
     set status='waiting',court_number=null,seat_locked=false,updated_at=now()
    from ranked
   where p.id=ranked.id and ranked.rn>cfg.max_players;
  get diagnostics n=row_count;
  moved:=moved+n;
  return moved;
end;
$$;

alter function public.wl_enforce_court_capacity(uuid) owner to opengym_runtime;
revoke all on function public.wl_enforce_court_capacity(uuid) from public, anon, authenticated;

create or replace function public.reverse_past_game(p_game_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  saved public.court_game_reversals;
  game public.past_games;
  result jsonb;
  later_eligibility jsonb;
  item jsonb;
  cfg public.waitlist_config;
  fid uuid:=public.current_facility_id();
begin
  perform public.lock_facility(); /* per-facility lock (audit L2/L3) */

  select * into game from public.past_games where id=p_game_id and facility_id=fid for update;
  select * into saved from public.court_game_reversals where game_id=p_game_id and facility_id=fid;
  select * into cfg from public.waitlist_config where facility_id=fid and id;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',id,'status',status,'sitout_priority',sitout_priority,'sitout_from_game',sitout_from_game
  )),'[]'::jsonb) into later_eligibility
  from public.waitlist_players
  where facility_id=fid and status in ('left','sitout');
  result:=public.reverse_past_game_legacy(p_game_id);
  for item in select value from jsonb_array_elements(later_eligibility) loop
    update public.waitlist_players set
      status=item->>'status',
      sitout_priority=coalesce((item->>'sitout_priority')::boolean,false),
      sitout_from_game=nullif(item->>'sitout_from_game','')::integer,
      updated_at=now()
    where facility_id=fid and id=(item->>'id')::uuid;
  end loop;
  if saved.game_id is not null then
    perform public.assert_hybrid_reverse_current_ownership(saved.after_state,game.court_number);
    perform public.apply_hybrid_court_reverse(saved.before_state,saved.after_state,game.court_number);
    perform public.reconcile_hybrid_reverse_player_eligibility(game.court_number);

    if cfg.mode::text !~* '(king|team)'
       and not public.is_hybrid_kotc_court(fid,game.court_number) then
      -- Players this advancement seated on the court go back where they were.
      for item in
        select b.value
          from jsonb_array_elements(saved.before_state->'players') b
          join jsonb_array_elements(saved.after_state->'players') a
            on a.value->>'id'=b.value->>'id'
         where (b.value->>'facility_id')::uuid=fid
           and a.value->>'status'='current'
           and (a.value->>'court_number')::integer=game.court_number
           and b.value->>'status' in ('waiting','sitout')
      loop
        update public.waitlist_players set
          status=item->>'status',
          court_number=null,
          seat_locked=false,
          sitout_priority=coalesce((item->>'sitout_priority')::boolean,false),
          sitout_from_game=nullif(item->>'sitout_from_game','')::integer,
          updated_at=now()
        where facility_id=fid and id=(item->>'id')::uuid
          and status='current' and court_number=game.court_number;
      end loop;
      perform public.wl_enforce_court_capacity(fid);
    end if;
  end if;
  return result;
end;
$function$;


-- The undo-based Reverse (latest Next game) gets the same capacity safety net.
create or replace function public.reverse_next_game_guarded(p_facility_id uuid, p_expected_game integer)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  entry public.admin_undo; snapshot_game integer; current_game integer; actor text;
  fid uuid := public.current_facility_id(); skipped integer;
begin
  perform public.lock_facility(); /* per-facility lock (audit L2/L3) */
  if fid is null then raise exception 'Select a facility first.'; end if;
  if p_facility_id is not null then perform public.assert_expected_facility(p_facility_id); end if;
  if public.is_waitlist_operator() then
    select * into entry from public.admin_undo where facility_id=fid and label='start next game' order by id desc limit 1 for update;
  else
    select * into entry from public.admin_undo where facility_id=fid and label='start next game'
      and admin_user_id=public.current_request_user_id() order by id desc limit 1 for update;
  end if;
  if entry.id is null then raise exception 'There is no recent next-game action you can reverse.'; end if;
  select game_number into current_game from public.waitlist_config where facility_id=fid and id for update;
  if p_expected_game is not null and current_game is distinct from p_expected_game then
    raise exception 'This game has already changed. Refresh and try again.';
  end if;
  snapshot_game := (entry.snapshot->'config'->>'game_number')::integer;
  if snapshot_game is null or current_game<>snapshot_game+1 then
    raise exception 'This game can no longer be reversed because the waitlist has already advanced.';
  end if;
  perform set_config('opengym.undo_entry', '', true);
  skipped := public.apply_undo_changes('undo', entry.id);
  -- Never leave a court over capacity after a reverse.
  perform public.wl_enforce_court_capacity(fid);
  delete from public.rejoin_responses where facility_id=fid and game_number>snapshot_game;
  delete from public.admin_undo where facility_id=fid and id=entry.id;
  delete from public.admin_redo where facility_id=fid and admin_user_id=entry.admin_user_id;
  select coalesce(display_name, 'Admin') into actor from public.waitlist_players
    where facility_id=fid and user_id=public.current_request_user_id();
  insert into public.waitlist_events(facility_id, actor_user_id, actor_name, event_type, message)
    values(fid, public.current_request_user_id(), coalesce(actor, 'Admin'), 'next_game_reversed',
           coalesce(actor, 'Admin')||' reversed the start of Game '||(snapshot_game+1)||'.');
  return jsonb_build_object('message', 'Game '||(snapshot_game+1)||' was reversed. Game '||snapshot_game
    ||' and its queue order are restored.'
    ||case when skipped>0 then ' Changes made since then by others were kept.' else '' end);
end;
$function$;

notify pgrst, 'reload schema';
commit;
