begin;
select set_config('request.jwt.claim.sub',:'user_id',true);
select pg_backend_pid(),clock_timestamp(),public.advance_court_game(:court,:'facility_id'::uuid,1);
commit;
