do $$
begin
  if not exists(select 1 from public.waitlist_config where facility_id='30000000-0000-4000-8000-000000000003' and hybrid_rotation_rule='kotc' and not hybrid_auto_kotc_armed and hybrid_config_version=2 and king_max_wins=3) then
    raise exception 'manual-rule / threshold evaluation race repeated or lost the manual KOTC switch';
  end if;
  if exists(select 1 from public.hybrid_kotc_teams where facility_id='30000000-0000-4000-8000-000000000003') then raise exception 'manual rule race rearranged the current game'; end if;
  raise notice 'Stage 3 manual-rule/threshold race PASS';
end $$;
