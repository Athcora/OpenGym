do $$
declare fid uuid:='55555555-5555-4555-8555-555555555551';
begin
  if (select count(*) from public.past_games where facility_id=fid and court_number=1)<>1
    or (select count(*) from public.court_game_reversals where facility_id=fid)<>1
    or (select game_number from public.waitlist_courts where facility_id=fid and court_number=1)<>2
    or (select version from public.hybrid_kotc_court_state where facility_id=fid and court_number=1)<>41
    -- Stage 1B canonical lifecycle retains the winning side and prepares the
    -- next empty opposing side.  There must be exactly one occupied winner,
    -- not a duplicate result-created occupied side.
    or (select count(*) from public.hybrid_kotc_teams where facility_id=fid and court_number=1 and status='current')<>2
    or (select count(*) from public.hybrid_kotc_teams t where t.facility_id=fid and t.court_number=1 and t.status='current'
       and exists(select 1 from public.hybrid_kotc_slots s where s.facility_id=fid and s.team_id=t.id and s.player_id is not null))<>1
  then raise exception 'unknown-side race did not produce exactly one canonical transition'; end if;
  if not exists(select 1 from public.court_game_reversals r join public.past_games g on g.id=r.game_id
    where r.facility_id=fid and g.facility_id=fid and g.court_number=1) then
    raise exception 'unknown-side race history/reversal identity mismatch'; end if;
end $$;
drop trigger local_stage5_unknown_pause on public.past_games;
drop function public.local_stage5_unknown_pause();
