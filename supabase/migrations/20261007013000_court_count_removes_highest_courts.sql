-- Lowering the number of courts removed the most recently started courts
-- instead of the highest-numbered ones. Going from 2 courts to 1 right after
-- Court 1 started a game deleted Court 1 and kept Court 2. The app only shows
-- courts up to the configured count, so Court 2 and its players disappeared
-- from every screen even though they were still playing.
--
-- 1. admin_set_court_count() now removes the highest-numbered courts.
-- 2. Any facility already left with a gap (e.g. count 1 but only Court 2)
--    has its remaining courts renumbered 1..n, with their players.
begin;

do $$
declare def text; patched text;
begin
  def:=pg_get_functiondef('public.admin_set_court_count(integer)'::regprocedure);
  if position('order by started_at desc,game_number desc' in def)=0
     and position('order by c.started_at desc,c.game_number desc' in def)=0 then
    return; -- already patched
  end if;
  if (length(def)-length(replace(def,'order by started_at desc,game_number desc','')))/length('order by started_at desc,game_number desc')<>2
     or (length(def)-length(replace(def,'order by c.started_at desc,c.game_number desc','')))/length('order by c.started_at desc,c.game_number desc')<>1 then
    raise exception 'admin_set_court_count() changed; review before patching.';
  end if;
  patched:=replace(def,'order by started_at desc,game_number desc','order by court_number desc');
  patched:=replace(patched,'order by c.started_at desc,c.game_number desc','order by c.court_number desc');
  execute patched;
end;
$$;

-- Repair facilities whose courts are not numbered 1..n.
do $$
declare fac record; c record; n integer;
begin
  for fac in
    select facility_id from public.waitlist_courts group by facility_id
    having max(court_number)<>count(*)
  loop
    -- Renumber in ascending order: each court moves down into the first gap,
    -- which is always free, so no two courts ever share a number.
    delete from public.wl_court_settings where facility_id=fac.facility_id;
    delete from public.wl_kotc_state where facility_id=fac.facility_id;
    n:=0;
    for c in select court_number from public.waitlist_courts where facility_id=fac.facility_id order by court_number loop
      n:=n+1;
      continue when c.court_number=n;
      update public.waitlist_courts set court_number=n where facility_id=fac.facility_id and court_number=c.court_number;
      update public.waitlist_players set court_number=n where facility_id=fac.facility_id and court_number=c.court_number;
      update public.king_teams set court_number=n where facility_id=fac.facility_id and court_number=c.court_number;
    end loop;
    update public.waitlist_config set court_count=n,updated_at=now() where facility_id=fac.facility_id and id;
  end loop;
end;
$$;

notify pgrst,'reload schema';
commit;
