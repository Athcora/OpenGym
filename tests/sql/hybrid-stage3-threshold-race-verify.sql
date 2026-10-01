do $$
declare fid uuid:='30000000-0000-4000-8000-000000000002';
begin
  if not exists(select 1 from public.waitlist_config where facility_id=fid and hybrid_rotation_rule='kotc' and not hybrid_auto_kotc_armed and hybrid_config_version=3 and king_max_wins=3) then
    raise exception 'ordered threshold/player race did not serialize to one automatic KOTC activation';
  end if;
  if (select count(*) from public.waitlist_players where facility_id=fid and status in('current','waiting'))<>24 then
    raise exception 'threshold race changed eligible player population';
  end if;
  raise notice 'Stage 3 threshold/player race PASS';
end $$;
