\set ON_ERROR_STOP on
select set_config('request.jwt.claim.sub', :'actor', false);
begin;
select pg_backend_pid() as backend_pid, pg_advisory_xact_lock(hashtextextended('30000000-0000-4000-8000-000000000001',7429401));
select pg_sleep(2);
select public.configure_hybrid_waitlist(
  '30000000-0000-4000-8000-000000000001', 1,
  'two_on_two_off', :threshold, :win_limit
) as result;
commit;
