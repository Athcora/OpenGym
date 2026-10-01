select set_config('request.jwt.claim.sub',(select user_id::text from public.waitlist_players p join public.facilities f on f.id=p.facility_id where f.slug='local-kotc-bootstrap-race' limit 1),false);
select public.bootstrap_hybrid_kotc_games((select id from public.facilities where slug='local-kotc-bootstrap-race'));
