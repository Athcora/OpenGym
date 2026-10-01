do $$ begin
 if (select count(*) from public.past_games where facility_id='20000000-0000-4000-8000-000000000001')<>1 or (select count(*) from public.court_game_reversals where facility_id='20000000-0000-4000-8000-000000000001')<>1 or (select game_number from public.waitlist_courts where facility_id='20000000-0000-4000-8000-000000000001' and court_number=1)<>2 then raise exception 'same-court guard failed'; end if;
 raise notice 'same-court guarded Rejoin concurrency PASS'; end $$;
