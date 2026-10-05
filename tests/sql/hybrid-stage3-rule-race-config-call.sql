\set ON_ERROR_STOP on
select set_config('request.jwt.claim.sub','30000000-0000-4000-8000-000000000031',false);
begin;
select pg_advisory_xact_lock(hashtextextended('30000000-0000-4000-8000-000000000003',7429401));
select pg_sleep(2);
select public.configure_hybrid_waitlist('30000000-0000-4000-8000-000000000003',1,'kotc',4,3);
commit;
