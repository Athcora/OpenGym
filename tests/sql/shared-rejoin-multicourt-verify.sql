do $$ declare f uuid; begin foreach f in array array['20000000-0000-4000-8000-000000000001'::uuid,'20000000-0000-4000-8000-000000000002'::uuid] loop
 if (select count(*) from public.past_games where facility_id=f)<>2 or (select count(distinct game_number) from public.past_games where facility_id=f)<>2 or (select count(*) from public.court_game_reversals r join public.past_games g on g.id=r.game_id where g.facility_id=f)<>2 then raise exception 'history/reversal mapping failed for %',f; end if;
 if exists(select 1 from public.past_games g left join public.court_game_reversals r on r.game_id=g.id where g.facility_id=f and r.game_id is null) then raise exception 'orphan history for %',f; end if;
 if (select count(*) from public.waitlist_courts where facility_id=f and game_number=2)<>2 then raise exception 'court-local progression failed for %',f; end if;
 end loop; raise notice 'shared Rejoin retained concurrent history PASS'; end $$;
