-- Stage 3 server-side configuration: this intentionally uses the public Admin
-- RPC and the deferred population trigger, never direct config mutation.
begin;
do $$
declare
  fid uuid:=gen_random_uuid(); other_fid uuid:=gen_random_uuid(); admin_id uuid:=gen_random_uuid();
  host_id uuid:=gen_random_uuid(); player_id uuid:=gen_random_uuid(); p24 uuid:=gen_random_uuid();
  group_id uuid:=gen_random_uuid(); version_before bigint; preserved_players jsonb;
  expected_config jsonb; actual_config jsonb; team_id uuid:=gen_random_uuid();
  i integer;
begin
  insert into public.facilities(id,name,slug,code) values
    (fid,'Stage 3 config','stage3-config-'||left(fid::text,8),left(fid::text,8)),
    (other_fid,'Stage 3 other','stage3-other-'||left(other_fid::text,8),left(other_fid::text,8));
  insert into public.facility_admin_credentials(facility_id,username,display_username,password_hash)
    values(fid,'stage3admin','Stage 3 Admin',crypt('x',gen_salt('bf')));
  insert into auth.users(id,instance_id,aud,role,email) values
    (admin_id,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',admin_id::text||'@example.test'),
    (host_id,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',host_id::text||'@example.test'),
    (player_id,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',player_id::text||'@example.test');
  insert into public.admin_sessions(user_id,username,facility_id) values(admin_id,'stage3admin',fid);
  insert into public.user_facility_sessions(user_id,facility_id) values(admin_id,fid),(host_id,fid),(player_id,fid);
  perform set_config('request.jwt.claim.sub',admin_id::text,true);
  insert into public.waitlist_config(facility_id,id,game_number,max_players,mode,court_count,geofence_enabled)
    values(fid,true,1,24,'hybrid_waitlist',2,false);
  insert into public.waitlist_courts(facility_id,court_number,game_number,team_mode,team_max_wins)
    values(fid,1,1,'rotation',9),(fid,2,1,'rotation',9);
  insert into public.daily_waitlist_reset_state(facility_id,id) values(fid,true);
  insert into public.waitlist_players(id,facility_id,user_id,first_name,last_name,display_name,status,queue_position,court_number,group_id,is_host)
    values(host_id,fid,host_id,'Host','','Host','current',1,1,group_id,true),
          (player_id,fid,player_id,'Player','','Player','current',2,1,group_id,false);
  for i in 3..23 loop
    insert into public.waitlist_players(facility_id,first_name,last_name,display_name,status,queue_position)
      values(fid,'P'||i,'','P'||i,'waiting',i);
  end loop;
  set constraints waitlist_players_hybrid_auto_kotc_transition immediate;
  perform set_config('request.jwt.claim.sub',admin_id::text,true);

  -- All supported thresholds persist canonically; only below starts armed.
  select hybrid_config_version into version_before from public.waitlist_config where facility_id=fid;
  perform public.configure_hybrid_waitlist(fid,version_before,'two_on_two_off',3,2);
  if not exists(select 1 from public.waitlist_config where facility_id=fid and hybrid_auto_kotc_threshold_teams=3 and not hybrid_auto_kotc_armed and king_max_wins=2)
     or exists(select 1 from public.waitlist_courts where facility_id=fid and team_max_wins<>2) then raise exception '3-team threshold / 2-win cap not persisted'; end if;
  select hybrid_config_version into version_before from public.waitlist_config where facility_id=fid;
  perform public.configure_hybrid_waitlist(fid,version_before,'two_on_two_off',5,3);
  if not exists(select 1 from public.waitlist_config where facility_id=fid and hybrid_auto_kotc_threshold_teams=5 and hybrid_auto_kotc_armed and king_max_wins=3)
     or exists(select 1 from public.waitlist_courts where facility_id=fid and team_max_wins<>3) then raise exception '5-team threshold / 3-win cap not persisted'; end if;
  select hybrid_config_version into version_before from public.waitlist_config where facility_id=fid;
  perform public.configure_hybrid_waitlist(fid,version_before,'two_on_two_off',6,null);
  if not exists(select 1 from public.waitlist_config where facility_id=fid and hybrid_auto_kotc_threshold_teams=6 and hybrid_auto_kotc_armed and king_max_wins is null)
     or exists(select 1 from public.waitlist_courts where facility_id=fid and team_max_wins is not null) then raise exception '6-team threshold / no-limit not persisted'; end if;

  -- Setting 24 at 23 establishes the below baseline, then only the actual
  -- 23 -> 24 population transition auto-switches.  Current courts stay intact.
  select hybrid_config_version into version_before from public.waitlist_config where facility_id=fid;
  perform public.configure_hybrid_waitlist(fid,version_before,'two_on_two_off',4,2);
  if not exists(select 1 from public.waitlist_config where facility_id=fid and hybrid_auto_kotc_armed) then raise exception 'below baseline was not armed'; end if;
  select jsonb_agg(jsonb_build_object('id',p.id,'status',p.status,'court',p.court_number,'queue',p.queue_position,'group',p.group_id) order by p.queue_position,p.id)
    into preserved_players from public.waitlist_players p where p.facility_id=fid;
  insert into public.waitlist_players(id,facility_id,first_name,last_name,display_name,status,queue_position)
    values(p24,fid,'P24','','P24','waiting',24);
  set constraints waitlist_players_hybrid_auto_kotc_transition immediate;
  if not exists(select 1 from public.waitlist_config where facility_id=fid and hybrid_rotation_rule='kotc' and not hybrid_auto_kotc_armed) then raise exception '24-player crossing did not switch to KOTC'; end if;
  if preserved_players is distinct from (select jsonb_agg(jsonb_build_object('id',p.id,'status',p.status,'court',p.court_number,'queue',p.queue_position,'group',p.group_id) order by p.queue_position,p.id) from public.waitlist_players p where p.facility_id=fid and p.id<>p24) then
    raise exception 'automatic threshold switch rearranged current player state';
  end if;

  -- Returning above threshold clears only temporary lifecycle state and stays
  -- disarmed until a real below observation followed by a new crossing.
  insert into public.hybrid_kotc_court_state(facility_id,court_number,version) values(fid,1,7);
  insert into public.hybrid_kotc_teams(id,facility_id,court_number,court_side,appearance_game_number) values(team_id,fid,1,1,1);
  insert into public.hybrid_kotc_slots(facility_id,team_id,slot_number,player_id) values(fid,team_id,1,host_id);
  select hybrid_config_version into version_before from public.waitlist_config where facility_id=fid;
  perform public.configure_hybrid_waitlist(fid,version_before,'two_on_two_off',4,2);
  if not exists(select 1 from public.waitlist_config where facility_id=fid and hybrid_rotation_rule='two_on_two_off' and not hybrid_auto_kotc_armed)
     or exists(select 1 from public.hybrid_kotc_teams where facility_id=fid)
     or exists(select 1 from public.hybrid_kotc_slots where facility_id=fid)
     or exists(select 1 from public.hybrid_kotc_court_state where facility_id=fid) then
    raise exception 'manual return did not clear temporary state / disarm';
  end if;
  if preserved_players is distinct from (select jsonb_agg(jsonb_build_object('id',p.id,'status',p.status,'court',p.court_number,'queue',p.queue_position,'group',p.group_id) order by p.queue_position,p.id) from public.waitlist_players p where p.facility_id=fid and p.id<>p24) then
    raise exception 'manual return changed player, queue, court, or group state';
  end if;
  delete from public.waitlist_players where id=p24 and facility_id=fid;
  set constraints waitlist_players_hybrid_auto_kotc_transition immediate;
  if not exists(select 1 from public.waitlist_config where facility_id=fid and hybrid_auto_kotc_armed and hybrid_rotation_rule='two_on_two_off') then raise exception 'below threshold did not re-arm'; end if;
  insert into public.waitlist_players(id,facility_id,first_name,last_name,display_name,status,queue_position) values(p24,fid,'P24','','P24','waiting',24);
  set constraints waitlist_players_hybrid_auto_kotc_transition immediate;
  if not exists(select 1 from public.waitlist_config where facility_id=fid and hybrid_rotation_rule='kotc' and not hybrid_auto_kotc_armed) then raise exception 'second crossing did not auto-switch'; end if;

  -- Never disables all population-driven switching, while manual KOTC remains
  -- allowed independently of any threshold.
  select hybrid_config_version into version_before from public.waitlist_config where facility_id=fid;
  perform public.configure_hybrid_waitlist(fid,version_before,'two_on_two_off',null,null);
  if not exists(select 1 from public.waitlist_config where facility_id=fid and hybrid_rotation_rule='two_on_two_off' and hybrid_auto_kotc_threshold_teams is null and not hybrid_auto_kotc_armed) then raise exception 'Never was not disabled canonically'; end if;
  delete from public.waitlist_players where id=p24 and facility_id=fid;
  insert into public.waitlist_players(id,facility_id,first_name,last_name,display_name,status,queue_position) values(p24,fid,'P24','','P24','waiting',24);
  set constraints waitlist_players_hybrid_auto_kotc_transition immediate;
  if not exists(select 1 from public.waitlist_config where facility_id=fid and hybrid_rotation_rule='two_on_two_off') then raise exception 'Never auto-switched'; end if;
  select hybrid_config_version into version_before from public.waitlist_config where facility_id=fid;
  perform public.configure_hybrid_waitlist(fid,version_before,'kotc',null,3);
  if not exists(select 1 from public.waitlist_config where facility_id=fid and hybrid_rotation_rule='kotc' and king_max_wins=3 and not hybrid_auto_kotc_armed) then raise exception 'manual KOTC / 3-win config failed'; end if;

  -- Undo/redo restores the exact semantic configuration and preserves the
  -- monotonic configuration version for stale callers.
  select jsonb_build_object('rule',hybrid_rotation_rule,'threshold',hybrid_auto_kotc_threshold_teams,'armed',hybrid_auto_kotc_armed,'wins',king_max_wins) into expected_config from public.waitlist_config where facility_id=fid;
  select hybrid_config_version into version_before from public.waitlist_config where facility_id=fid;
  perform public.configure_hybrid_waitlist(fid,version_before,'two_on_two_off',3,2);
  perform public.admin_undo_last();
  select jsonb_build_object('rule',hybrid_rotation_rule,'threshold',hybrid_auto_kotc_threshold_teams,'armed',hybrid_auto_kotc_armed,'wins',king_max_wins) into actual_config from public.waitlist_config where facility_id=fid;
  if actual_config is distinct from expected_config then raise exception 'Admin Undo did not restore configuration: %',actual_config; end if;
  perform public.admin_redo_last();
  if not exists(select 1 from public.waitlist_config where facility_id=fid and hybrid_rotation_rule='two_on_two_off' and hybrid_auto_kotc_threshold_teams=3 and not hybrid_auto_kotc_armed and king_max_wins=2) then raise exception 'Admin Redo did not restore configuration'; end if;
  select hybrid_config_version into version_before from public.waitlist_config where facility_id=fid;
  perform public.configure_hybrid_waitlist(fid,version_before,'kotc',null,2);
  begin perform public.configure_hybrid_waitlist(fid,version_before,'two_on_two_off',3,2); raise exception 'stale configuration write succeeded'; exception when others then if position('configuration changed' in lower(sqlerrm))=0 then raise; end if; end;

  -- Only an Admin for the selected facility reaches the public mutation.
  select hybrid_config_version into version_before from public.waitlist_config where facility_id=fid;
  perform set_config('request.jwt.claim.sub',host_id::text,true);
  begin perform public.configure_hybrid_waitlist(fid,version_before,'kotc',null,2); raise exception 'host changed configuration'; exception when others then if position('Admin access required' in sqlerrm)=0 then raise; end if; end;
  perform set_config('request.jwt.claim.sub',player_id::text,true);
  begin perform public.configure_hybrid_waitlist(fid,version_before,'kotc',null,2); raise exception 'player changed configuration'; exception when others then if position('Admin access required' in sqlerrm)=0 then raise; end if; end;
  perform set_config('request.jwt.claim.sub',admin_id::text,true);
  begin perform public.configure_hybrid_waitlist(other_fid,version_before,'kotc',null,2); raise exception 'cross-facility configuration changed'; exception when others then if position('no longer connected' in lower(sqlerrm))=0 then raise; end if; end;
  if has_function_privilege('anon','public.configure_hybrid_waitlist(uuid,bigint,text,integer,integer)','execute')
     or has_function_privilege('authenticated','public.hybrid_eligible_player_count(uuid)','execute')
     or has_function_privilege('authenticated','public.evaluate_hybrid_auto_kotc_transition(uuid)','execute') then
    raise exception 'Stage 3 function grants leaked';
  end if;
  raise notice 'Stage 3 hybrid configuration PASS';
end $$;
rollback;
