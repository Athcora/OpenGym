select pg_backend_pid() as result_backend;
select set_config('request.jwt.claim.sub','68666666-6666-4666-8666-666666666662',false);
select public.advance_hybrid_kotc_game(1,'lose','68666666-6666-4666-8666-666666666661',1,21::bigint);
