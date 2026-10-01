do $$
declare fid uuid:='66666666-6666-4666-8666-666666666661'; tid uuid:='66666666-6666-4666-8666-666666666670';
begin
  if (select version from public.hybrid_kotc_court_state where facility_id=fid and court_number=1)<>51
    or (select count(*) from public.hybrid_kotc_slots where facility_id=fid and team_id=tid and player_id is not null)<>5
    or (select count(*) from public.hybrid_kotc_substitutes where facility_id=fid and team_id=tid)<>1
    or (select count(*) from public.waitlist_players where facility_id=fid and status='current' and court_number=1)<>5
    or (select count(*) from public.waitlist_players where facility_id=fid and id in ('66666666-6666-4666-8666-666666666668','66666666-6666-4666-8666-666666666669') and status='waiting')<>1
  then raise exception 'same-slot Fill In race did not retain exactly one canonical winner'; end if;
end $$;
drop trigger local_stage6_fill_pause on public.hybrid_kotc_slots;
drop function public.local_stage6_fill_pause();
