drop trigger if exists local_hybrid_kotc_bootstrap_pause on public.hybrid_kotc_teams;
drop function if exists public.local_hybrid_kotc_bootstrap_pause();
do $$
declare fid uuid:=(select id from public.facilities where slug='local-kotc-bootstrap-race');
begin
  if (select count(*) from public.hybrid_kotc_teams where facility_id=fid and status='current')<>2 then raise exception 'concurrent bootstrap created an invalid number of sides'; end if;
  if (select count(*) from public.hybrid_kotc_slots s join public.hybrid_kotc_teams t on t.id=s.team_id where t.facility_id=fid)<>12 then raise exception 'concurrent bootstrap did not preserve six slots per side'; end if;
  if (select version from public.hybrid_kotc_court_state where facility_id=fid and court_number=1)<>1 then raise exception 'concurrent bootstrap advanced the first-game version more than once'; end if;
  raise notice 'hybrid KOTC concurrent first-game bootstrap PASS';
end $$;
delete from public.facilities where id=(select id from public.facilities where slug='local-kotc-bootstrap-race');
delete from auth.users where email='bootstrap-race@example.test';
