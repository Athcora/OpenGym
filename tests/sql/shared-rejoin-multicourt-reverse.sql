begin;
select set_config('request.jwt.claim.sub','20000000-0000-4000-8000-000000000011',true);
select public.reverse_past_game_guarded((select id from public.past_games where facility_id='20000000-0000-4000-8000-000000000001' and court_number=1),'20000000-0000-4000-8000-000000000001');
do $$ begin if (select count(*) from public.past_games where facility_id='20000000-0000-4000-8000-000000000001' and court_number=2)<>1 or (select game_number from public.waitlist_courts where facility_id='20000000-0000-4000-8000-000000000001' and court_number=2)<>2 then raise exception 'Court 1 reverse altered Court 2'; end if; end $$;
commit;

begin;
select set_config('request.jwt.claim.sub','20000000-0000-4000-8000-000000000012',true);
select public.reverse_past_game_guarded((select id from public.past_games where facility_id='20000000-0000-4000-8000-000000000001' and court_number=2),'20000000-0000-4000-8000-000000000001');
do $$ begin if exists(select 1 from public.past_games where facility_id='20000000-0000-4000-8000-000000000001' and court_number=1) then raise exception 'Court 2 reverse altered Court 1 history'; end if; end $$;
commit;
