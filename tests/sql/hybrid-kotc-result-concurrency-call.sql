select set_config('request.jwt.claim.sub',(select user_id::text from public.waitlist_players p join public.facilities f on f.id=p.facility_id where f.slug='local-hybrid-result-concurrency' and p.display_name='Reporter'),false);
select public.advance_hybrid_kotc_game(1,'win',(select id from public.facilities where slug='local-hybrid-result-concurrency'),1,40);
