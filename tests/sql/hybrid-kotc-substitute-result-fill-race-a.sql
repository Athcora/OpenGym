select pg_backend_pid() as fill_backend;
select set_config('request.jwt.claim.sub','67666666-6666-4666-8666-666666666663',false);
select public.fill_hybrid_kotc_empty_slot(1,'67666666-6666-4666-8666-666666666680','67666666-6666-4666-8666-666666666661',1,10);
