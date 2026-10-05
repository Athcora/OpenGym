\set ON_ERROR_STOP on
select set_config('request.jwt.claim.sub', :'actor', false);
select pg_backend_pid() as backend_pid,
  public.configure_hybrid_waitlist(
    '30000000-0000-4000-8000-000000000001', 1,
    'two_on_two_off', :threshold, :win_limit
  ) as result;
