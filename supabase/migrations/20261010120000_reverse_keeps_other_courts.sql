-- Past games -> Reverse: audit fixes.
--
-- 1. Reversing one court no longer reaches into other courts. A player who,
--    since the reversed game, has been seated on another court or has played
--    a game there (so is now deciding whether to rejoin from that court) keeps
--    their current state. Before, reversing Court 1 could pull a lineup off
--    Court 2 mid-game, or skip players' rejoin decision for Court 2, and leave
--    Court 2 empty. The seats they leave on the reversed court are filled from
--    the line as usual.
-- 2. The "keep players who left or sat out" pass only rewrites rows the
--    reverse actually changed. Before, every reverse rewrote every player who
--    ever left the facility (about 900 rows at PHR), which flooded realtime
--    and made the reverse slow.
-- 3. Players can no longer call the unguarded reverse_past_game directly.
begin;

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
  elsewhere jsonb;
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

  -- Players who belong to another court now: seated there, or they played a
  -- game there after this game ended.
  if saved.game_id is not null and game.id is not null then
    select coalesce(jsonb_agg(to_jsonb(p)),'[]'::jsonb) into elsewhere
    from public.waitlist_players p
    where p.facility_id=fid and p.status<>'left'
      and (
        (p.status='current' and p.court_number is not null and p.court_number<>game.court_number)
        or exists(
          select 1
            from public.court_game_reversals r
            join public.past_games g on g.id=r.game_id and g.facility_id=fid
           cross join lateral jsonb_array_elements(r.before_state->'players') b
           where r.facility_id=fid and r.created_at>saved.created_at
             and g.court_number<>game.court_number
             and b.value->>'id'=p.id::text
             and b.value->>'status'='current'
             and (b.value->>'court_number')::integer=g.court_number)
      );
  else
    elsewhere:='[]'::jsonb;
  end if;

  result:=public.reverse_past_game_legacy(p_game_id);

  for item in select value from jsonb_array_elements(later_eligibility) loop
    update public.waitlist_players set
      status=item->>'status',
      sitout_priority=coalesce((item->>'sitout_priority')::boolean,false),
      sitout_from_game=nullif(item->>'sitout_from_game','')::integer,
      updated_at=now()
    where facility_id=fid and id=(item->>'id')::uuid
      and (status is distinct from item->>'status'
        or sitout_priority is distinct from coalesce((item->>'sitout_priority')::boolean,false)
        or sitout_from_game is distinct from nullif(item->>'sitout_from_game','')::integer);
  end loop;

  for item in select value from jsonb_array_elements(elsewhere) loop
    update public.waitlist_players t set
      status=r.status,
      court_number=r.court_number,
      seat_locked=r.seat_locked,
      rejoin_expires_at=r.rejoin_expires_at,
      rejoin_returning=r.rejoin_returning,
      sitout_priority=r.sitout_priority,
      sitout_from_game=r.sitout_from_game,
      team_id=r.team_id,
      group_id=r.group_id,
      line_key=r.line_key,
      line_spot=r.line_spot,
      updated_at=now()
    from jsonb_populate_record(null::public.waitlist_players,item) r
    where t.facility_id=fid and t.id=r.id
      and (t.status,t.court_number,t.seat_locked,t.rejoin_expires_at,t.rejoin_returning,
           t.sitout_priority,t.sitout_from_game,t.team_id,t.group_id,t.line_key,t.line_spot)
          is distinct from
          (r.status,r.court_number,r.seat_locked,r.rejoin_expires_at,r.rejoin_returning,
           r.sitout_priority,r.sitout_from_game,r.team_id,r.group_id,r.line_key,r.line_spot);
  end loop;

  if saved.game_id is not null then
    perform public.assert_hybrid_reverse_current_ownership(saved.after_state,game.court_number);
    perform public.apply_hybrid_court_reverse(saved.before_state,saved.after_state,game.court_number);
    perform public.reconcile_hybrid_reverse_player_eligibility(game.court_number);

    -- A restored King of the Court team must not keep a player who now
    -- belongs to another court.
    if jsonb_array_length(elsewhere)>0 then
      delete from public.hybrid_kotc_substitutes s
        using public.hybrid_kotc_teams t
       where s.facility_id=fid and s.team_id=t.id and t.facility_id=fid
         and t.court_number=game.court_number and t.status='current'
         and s.player_id in (select (e->>'id')::uuid from jsonb_array_elements(elsewhere) e);
      update public.hybrid_kotc_slots s set player_id=null,is_substitute=false,updated_at=now()
        from public.hybrid_kotc_teams t
       where s.facility_id=fid and s.team_id=t.id and t.facility_id=fid
         and t.court_number=game.court_number and t.status='current'
         and s.player_id in (select (e->>'id')::uuid from jsonb_array_elements(elsewhere) e);
    end if;

    if cfg.mode::text !~* '(king|team)'
       and not public.is_hybrid_kotc_court(fid,game.court_number) then
      for item in
        select b.value
          from jsonb_array_elements(saved.before_state->'players') b
         where (b.value->>'facility_id')::uuid=fid
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
      update public.waitlist_players p set
        status='waiting',court_number=null,seat_locked=false,updated_at=now()
      where p.facility_id=fid and p.status='current' and p.court_number=game.court_number
        and not exists(
          select 1 from jsonb_array_elements(saved.before_state->'players') b
           where b.value->>'id'=p.id::text
             and b.value->>'status'='current'
             and (b.value->>'court_number')::integer=game.court_number);
      perform public.wl_enforce_court_capacity(fid);
    end if;
  end if;

  if saved.game_id is not null then
    delete from public.admin_undo where facility_id=fid and created_at>=saved.created_at;
    delete from public.admin_redo where facility_id=fid;
  end if;
  return result;
end;
$function$;

-- Clients go through reverse_past_game_guarded (checks the facility on screen).
revoke all on function public.reverse_past_game(uuid) from public, anon, authenticated;

insert into supabase_migrations.schema_migrations(version,name,statements)
values ('20261010120000','reverse_keeps_other_courts',array['see supabase/migrations/20261010120000_reverse_keeps_other_courts.sql'])
on conflict (version) do nothing;
notify pgrst, 'reload schema';
commit;
