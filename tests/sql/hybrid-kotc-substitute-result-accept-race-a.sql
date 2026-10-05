select pg_backend_pid() as accept_backend;
select set_config('request.jwt.claim.sub','67666666-6666-4666-8666-666666666663',false);
select public.answer_hybrid_kotc_substitute((select id from public.team_substitute_requests where facility_id='67666666-6666-4666-8666-666666666661' and status='pending'),true);
