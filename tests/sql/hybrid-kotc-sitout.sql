-- Run after hybrid-kotc-substitute-result-swap-race-setup.sql.  This is a
-- local-only fixed-ID fixture for the guarded hybrid KOTC Sit Out boundary.
drop trigger if exists local_stage6_swap_result_pause on public.waitlist_players;
drop function if exists public.local_stage6_swap_result_pause();

do $$
declare fid uuid:='68666666-6666-4666-8666-666666666661'; b uuid:='68666666-6666-4666-8666-666666666664';
  c uuid:='68666666-6666-4666-8666-666666666665'; t1 uuid:='68666666-6666-4666-8666-666666666680';
  grp uuid:='68666666-6666-4666-8666-666666666690'; before_state jsonb; result jsonb;
begin
  -- This fixture is run in its own psql session after the fixed-ID setup;
  -- request claims are session-local, so authenticate the actual caller here.
  perform set_config('request.jwt.claim.sub','68666666-6666-4666-8666-666666666662',true);
  select jsonb_build_object('version',(select version from public.hybrid_kotc_court_state where facility_id=fid and court_number=1),'slots',(select jsonb_agg(jsonb_build_object('slot',slot_number,'player',player_id) order by slot_number) from public.hybrid_kotc_slots where facility_id=fid and team_id=t1)) into before_state;
  result:=public.sit_out_hybrid_kotc_player(1,b,fid,1,20);
  if result->>'version'<>'21' or (select status from public.waitlist_players where id=b)<>'sitout'
     or not (select sitout_priority from public.waitlist_players where id=b)
     or (select group_id from public.waitlist_players where id=b) is distinct from grp
     or exists(select 1 from public.hybrid_kotc_slots where facility_id=fid and team_id=t1 and player_id=b)
     or not exists(select 1 from public.hybrid_kotc_slots where facility_id=fid and team_id=t1 and slot_number=1 and player_id is null)
     or (select count(*) from public.hybrid_kotc_slots where facility_id=fid and team_id=t1)<>4 then raise exception 'grouped direct-slot Sit Out was not structurally durable: %',result; end if;
  begin perform public.sit_out_hybrid_kotc_player(1,b,fid,1,21); raise exception 'repeated Sit Out accepted'; exception when others then if position('changed' in lower(sqlerrm))=0 and position('not active' in lower(sqlerrm))=0 then raise; end if; end;
  if before_state->'slots' is null or (select version from public.hybrid_kotc_court_state where facility_id=fid and court_number=1)<>21 then raise exception 'rejected repeat mutated state'; end if;
  begin perform public.sit_out_hybrid_kotc_player(1,c,fid,1,20); raise exception 'stale version accepted'; exception when others then if position('changed' in lower(sqlerrm))=0 then raise; end if; end;
  begin perform public.sit_out_hybrid_kotc_player(2,c,fid,1,21); raise exception 'wrong court accepted'; exception when others then if position('changed' in lower(sqlerrm))=0 and position('not active' in lower(sqlerrm))=0 then raise; end if; end;
  begin perform public.sit_out_hybrid_kotc_player(1,c,gen_random_uuid(),1,21); raise exception 'wrong facility accepted'; exception when others then if position('facility' in lower(sqlerrm))=0 then raise; end if; end;
  update public.waitlist_config set hybrid_rotation_rule='two_on_two_off' where facility_id=fid;
  begin perform public.sit_out_hybrid_kotc_player(1,c,fid,1,21); raise exception 'two_on_two_off Sit Out accepted'; exception when others then if position('changed' in lower(sqlerrm))=0 then raise; end if; end;
  update public.waitlist_config set hybrid_rotation_rule='kotc' where facility_id=fid;
  raise notice 'guarded hybrid KOTC Sit Out durable boundary matrix PASS';
end $$;
