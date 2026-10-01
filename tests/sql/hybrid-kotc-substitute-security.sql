-- Stage 6 negative public-boundary checks.  This deliberately uses the durable
-- Fill In race fixture left in its canonical post-race state and rolls back all
-- attempted mutations.
begin;
do $$
declare fid uuid:='66666666-6666-4666-8666-666666666661'; tid uuid:='66666666-6666-4666-8666-666666666670';
  before_version bigint; before_slots jsonb; before_subs jsonb;
begin
  select version into before_version from public.hybrid_kotc_court_state where facility_id=fid and court_number=1;
  select jsonb_agg(jsonb_build_object('slot',slot_number,'player',player_id) order by slot_number) into before_slots from public.hybrid_kotc_slots where facility_id=fid and team_id=tid;
  select jsonb_agg(player_id order by player_id) into before_subs from public.hybrid_kotc_substitutes where facility_id=fid and team_id=tid;
  perform set_config('request.jwt.claim.sub','66666666-6666-4666-8666-666666666662',false);

  begin perform public.fill_hybrid_kotc_empty_slot(2,tid,fid,1,before_version); raise exception 'cross-court Fill In unexpectedly succeeded'; exception when others then null; end;
  begin perform public.fill_hybrid_kotc_empty_slot(1,'00000000-0000-0000-0000-000000000001',fid,1,before_version); raise exception 'wrong appearance Fill In unexpectedly succeeded'; exception when others then null; end;
  begin perform public.fill_hybrid_kotc_empty_slot(1,tid,'00000000-0000-0000-0000-000000000001',1,before_version); raise exception 'cross-facility Fill In unexpectedly succeeded'; exception when others then null; end;
  begin perform public.fill_hybrid_kotc_empty_slot(1,tid,fid,1,before_version); raise exception 'non-waiting Fill In unexpectedly succeeded'; exception when others then null; end;
  -- The caller is a current temporary member, but the proposed target is an
  -- active original player; a duplicate active KOTC assignment must reject.
  begin perform public.request_hybrid_kotc_substitute(1,tid,'66666666-6666-4666-8666-666666666664',fid,1,before_version); raise exception 'active target invitation unexpectedly succeeded'; exception when others then null; end;

  update public.waitlist_config set hybrid_rotation_rule='two_on_two_off' where facility_id=fid;
  begin perform public.fill_hybrid_kotc_empty_slot(1,tid,fid,1,before_version); raise exception 'two_on_two_off KOTC Fill In unexpectedly succeeded'; exception when others then null; end;
  if (select version from public.hybrid_kotc_court_state where facility_id=fid and court_number=1) is distinct from before_version
    or (select jsonb_agg(jsonb_build_object('slot',slot_number,'player',player_id) order by slot_number) from public.hybrid_kotc_slots where facility_id=fid and team_id=tid) is distinct from before_slots
    or (select jsonb_agg(player_id order by player_id) from public.hybrid_kotc_substitutes where facility_id=fid and team_id=tid) is distinct from before_subs
  then raise exception 'rejected Stage 6 boundary call changed authoritative state'; end if;
end $$;

-- Internal trigger helper must not be executable by browser roles.
do $$ begin
  begin
    set local role authenticated;
    perform public.assert_hybrid_kotc_substitute_integrity();
    raise exception 'authenticated executed private helper';
  exception when insufficient_privilege then null;
  end;
  reset role;
end $$;
rollback;
