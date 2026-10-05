begin;
select set_config('request.jwt.claim.sub','20000000-0000-4000-8000-000000000012',true);
select public.reverse_past_game_guarded((select id from public.past_games where facility_id='20000000-0000-4000-8000-000000000001' and court_number=2),'20000000-0000-4000-8000-000000000001');
do $$ declare v integer; begin select game_number into v from public.waitlist_courts where facility_id='20000000-0000-4000-8000-000000000001' and court_number=1; if v<>1 or exists(select 1 from public.past_games where facility_id='20000000-0000-4000-8000-000000000001') then raise exception 'Court 2 reverse crossed Court 1 or retained history'; end if; end $$;
commit;
begin;
select set_config('request.jwt.claim.sub','20000000-0000-4000-8000-000000000012',true);
do $$ begin begin perform public.reverse_past_game_guarded('00000000-0000-0000-0000-000000000000','20000000-0000-4000-8000-000000000001'); raise exception 'unexpected'; exception when others then null; end; end $$;
rollback;
