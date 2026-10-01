select pg_backend_pid() as swap_backend;
select set_config('request.jwt.claim.sub','68666666-6666-4666-8666-666666666662',false);
select public.swap_hybrid_kotc_slot(1,'68666666-6666-4666-8666-666666666680','2'::smallint,'68666666-6666-4666-8666-666666666672','68666666-6666-4666-8666-666666666661',1,20::bigint);
