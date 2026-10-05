-- Run after hybrid-kotc-substitute-result-swap-race-setup.sql.  The setup's
-- pause trigger is removed here; this is a sequential exact-history regression.
drop trigger if exists local_stage6_swap_result_pause on public.waitlist_players;
drop function if exists public.local_stage6_swap_result_pause();

-- The fixed-ID setup runs in another psql session; restore the authenticated
-- operator request context for this public-RPC regression session.
select set_config('request.jwt.claim.sub','68666666-6666-4666-8666-666666666662',false);
select public.advance_hybrid_kotc_game(1,'win','68666666-6666-4666-8666-666666666661',1,20);
select public.advance_hybrid_kotc_game(1,'lose','68666666-6666-4666-8666-666666666661',2,21);

do $$
declare older_game uuid; newer_game uuid; version_before bigint; players_before jsonb;
begin
  select id into strict older_game from public.past_games
    where facility_id='68666666-6666-4666-8666-666666666661' and court_number=1 order by game_number limit 1;
  select id into strict newer_game from public.past_games
    where facility_id='68666666-6666-4666-8666-666666666661' and court_number=1 order by game_number desc limit 1;
  if (select count(*) from public.court_game_reversals where facility_id='68666666-6666-4666-8666-666666666661')<>2 then
    raise exception 'consecutive results did not retain distinct reversal mappings';
  end if;
  select version into version_before from public.hybrid_kotc_court_state
    where facility_id='68666666-6666-4666-8666-666666666661' and court_number=1;
  select jsonb_agg(jsonb_build_object('id',id,'status',status,'group',group_id,'court',court_number) order by id)
    into players_before from public.waitlist_players where facility_id='68666666-6666-4666-8666-666666666661';
  begin
    perform public.reverse_past_game_guarded(older_game,'68666666-6666-4666-8666-666666666661');
    raise exception 'older Reverse unexpectedly accepted a newer current appearance';
  exception when others then
    if position('most recent game' in lower(sqlerrm))=0 then raise; end if;
  end;
  if (select version from public.hybrid_kotc_court_state where facility_id='68666666-6666-4666-8666-666666666661' and court_number=1)<>version_before
     or players_before is distinct from (select jsonb_agg(jsonb_build_object('id',id,'status',status,'group',group_id,'court',court_number) order by id) from public.waitlist_players where facility_id='68666666-6666-4666-8666-666666666661') then
    raise exception 'rejected older Reverse mutated state';
  end if;
  perform public.reverse_past_game_guarded(newer_game,'68666666-6666-4666-8666-666666666661');
  perform public.reverse_past_game_guarded(older_game,'68666666-6666-4666-8666-666666666661');
  if (select count(*) from public.past_games where facility_id='68666666-6666-4666-8666-666666666661')<>0
     or (select version from public.hybrid_kotc_court_state where facility_id='68666666-6666-4666-8666-666666666661' and court_number=1)<>24 then
    raise exception 'newer Reverse then original retry did not consume each exact history once';
  end if;
  raise notice 'consecutive history identity + incompatible rejection/retry PASS (20 -> 21 -> 22 -> 23 -> 24)';
end $$;
