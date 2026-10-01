do $$
declare fid uuid:='30000000-0000-4000-8000-000000000001'; undo_count integer;
begin
  if not exists(select 1 from public.waitlist_config where facility_id=fid and hybrid_config_version=2 and hybrid_rotation_rule='two_on_two_off' and hybrid_auto_kotc_threshold_teams in(3,4) and king_max_wins in(2,3)) then
    raise exception 'configuration race did not retain exactly one guarded write';
  end if;
  select count(*) into undo_count from public.admin_undo where facility_id=fid and label='change Waitlist configuration';
  if undo_count<>1 then raise exception 'configuration race created % undo records, expected one',undo_count; end if;
  raise notice 'Stage 3 same-config-version concurrency PASS';
end $$;
