select pg_backend_pid() as backend_a;
select set_config('request.jwt.claim.sub','66666666-6666-4666-8666-666666666662',false);
select public.fill_hybrid_kotc_empty_slot(1,'66666666-6666-4666-8666-666666666670','66666666-6666-4666-8666-666666666661',1,50);
