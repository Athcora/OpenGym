do $$ begin
 if (select version from public.hybrid_kotc_court_state where facility_id='11111111-1111-4111-8111-111111111111' and court_number=1)<>102
  or (select version from public.hybrid_kotc_court_state where facility_id='11111111-1111-4111-8111-111111111111' and court_number=2)<>202
  or (select count(*) from public.past_games where facility_id='11111111-1111-4111-8111-111111111111')<>2 then raise exception 'both court transitions did not commit exactly once'; end if;
 raise notice 'hybrid KOTC different-court concurrency PASS';
end $$;
delete from public.court_game_reversals where facility_id='11111111-1111-4111-8111-111111111111'; delete from public.past_games where facility_id='11111111-1111-4111-8111-111111111111'; delete from public.facilities where id='11111111-1111-4111-8111-111111111111';
