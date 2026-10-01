select (select version from public.hybrid_kotc_court_state s join public.facilities f on f.id=s.facility_id where f.slug='local-hybrid-result-concurrency' and s.court_number=1) as version,
  (select game_number from public.waitlist_courts c join public.facilities f on f.id=c.facility_id where f.slug='local-hybrid-result-concurrency' and c.court_number=1) as game_number,
  (select count(*) from public.past_games g join public.facilities f on f.id=g.facility_id where f.slug='local-hybrid-result-concurrency') as past_games;
