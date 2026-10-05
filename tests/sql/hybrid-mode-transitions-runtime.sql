begin;

do $$
declare
  fid uuid:=gen_random_uuid(); admin_id uuid:=gen_random_uuid(); member_id uuid:=gen_random_uuid();
  permanent_group_id uuid:=gen_random_uuid(); side_one uuid:=gen_random_uuid(); side_two uuid:=gen_random_uuid();
  fill_in uuid:=gen_random_uuid(); accepted uuid:=gen_random_uuid(); invited uuid:=gen_random_uuid();
  c1_version bigint; stale_version bigint; c2_before jsonb; players_before jsonb; player_after jsonb;
  i integer;
begin
  insert into public.facilities(id,name,slug,code)
    values(fid,'Stage 9 transitions','stage9-transition-'||left(fid::text,8),left(fid::text,8));
  insert into auth.users(id,instance_id,aud,role,email) values
    (admin_id,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',admin_id||'@example.test'),
    (member_id,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',member_id||'@example.test');
  insert into public.user_facility_sessions(user_id,facility_id) values(admin_id,fid),(member_id,fid);
  insert into public.facility_admin_credentials(facility_id,username,display_username,password_hash)
    values(fid,'stage9-admin','Stage 9 admin',crypt('local-only-password',gen_salt('bf')));
  insert into public.admin_sessions(user_id,username,facility_id) values(admin_id,'stage9-admin',fid);
  perform set_config('request.jwt.claim.sub',admin_id::text,true);

  insert into public.waitlist_config(facility_id,id,mode,court_count,game_number,max_players,geofence_enabled)
    values(fid,true,'hybrid_waitlist',2,7,24,false);
  insert into public.waitlist_courts(facility_id,court_number,game_number,hybrid_rotation_rule,
      hybrid_auto_kotc_threshold_teams,hybrid_auto_kotc_armed,hybrid_config_version,team_max_wins)
    values(fid,1,7,'kotc',null,false,1,2),(fid,2,11,'two_on_two_off',null,false,9,3);
  insert into public.daily_waitlist_reset_state(facility_id,id) values(fid,true);

  -- Eleven current Court 1 players include one permanent group and a filled
  -- temporary slot. Court 2 and two waiting players establish a facility-wide
  -- above-threshold population without sharing Court 1 ownership.
  for i in 1..10 loop
    insert into public.waitlist_players(facility_id,first_name,last_name,display_name,status,queue_position,court_number,group_id)
      values(fid,'C1-'||i,'','C1-'||i,'current',i,1,case when i in(1,2) then permanent_group_id else null end);
  end loop;
  fill_in:=gen_random_uuid();
  insert into public.waitlist_players(id,facility_id,first_name,last_name,display_name,status,queue_position,court_number)
    values(fill_in,fid,'Fill','','Fill','current',11,1);
  for i in 1..6 loop
    insert into public.waitlist_players(facility_id,first_name,last_name,display_name,status,queue_position,court_number)
      values(fid,'C2-'||i,'','C2-'||i,'current',100+i,2);
  end loop;
  accepted:=gen_random_uuid(); invited:=gen_random_uuid();
  insert into public.waitlist_players(id,facility_id,first_name,last_name,display_name,status,queue_position)
    values(accepted,fid,'Accepted','','Accepted','waiting',200),(invited,fid,'Invited','','Invited','waiting',201);

  insert into public.hybrid_kotc_court_state(facility_id,court_number,version,initialized_game_number) values(fid,1,44,7);
  insert into public.hybrid_kotc_teams(id,facility_id,court_number,court_side,appearance_game_number,status,consecutive_wins)
    values(side_one,fid,1,1,7,'current',2),(side_two,fid,1,2,7,'current',1);
  insert into public.hybrid_kotc_slots(facility_id,team_id,slot_number,player_id,is_substitute)
    select fid,side_one,n,case when n=6 then fill_in else (select id from public.waitlist_players where facility_id=fid and display_name='C1-'||n) end,n=6
    from generate_series(1,6) n;
  insert into public.hybrid_kotc_slots(facility_id,team_id,slot_number,player_id,is_substitute)
    select fid,side_two,n,case when n=6 then null else (select id from public.waitlist_players where facility_id=fid and display_name='C1-'||(n+6)) end,false
    from generate_series(1,6) n;
  insert into public.hybrid_kotc_substitutes(facility_id,team_id,player_id) values(fid,side_one,fill_in),(fid,side_two,accepted);
  insert into public.team_substitute_requests(facility_id,hybrid_team_id,requester_id,target_id,expected_game_number,expected_version)
    values(fid,side_one,(select id from public.waitlist_players where facility_id=fid and display_name='C1-1'),invited,7,44);

  select jsonb_agg(jsonb_build_object('id',p.id,'status',p.status,'court',p.court_number,'queue',p.queue_position,'group',p.group_id) order by p.queue_position,p.id)
    into players_before from public.waitlist_players p where p.facility_id=fid;
  select jsonb_build_object('game',game_number,'rule',hybrid_rotation_rule,'threshold',hybrid_auto_kotc_threshold_teams,'armed',hybrid_auto_kotc_armed,'version',hybrid_config_version,'wins',team_max_wins)
    into c2_before from public.waitlist_courts where facility_id=fid and court_number=2;

  -- Manual KOTC -> 2on2 above threshold clears temporary structures, preserves
  -- population/groups/queue, and remains disarmed until a new real crossing.
  perform public.configure_hybrid_waitlist(fid,1,1,'two_on_two_off',3,2);
  if not exists(select 1 from public.waitlist_courts where facility_id=fid and court_number=1 and hybrid_rotation_rule='two_on_two_off' and hybrid_auto_kotc_threshold_teams=3 and not hybrid_auto_kotc_armed)
     or exists(select 1 from public.hybrid_kotc_teams where facility_id=fid and court_number=1)
     or exists(select 1 from public.hybrid_kotc_slots where facility_id=fid)
     or exists(select 1 from public.hybrid_kotc_substitutes where facility_id=fid)
     or exists(select 1 from public.hybrid_kotc_court_state where facility_id=fid and court_number=1)
     or exists(select 1 from public.team_substitute_requests where facility_id=fid and hybrid_team_id is not null)
  then raise exception 'KOTC -> 2on2 did not clear retired Court 1 temporary ownership'; end if;
  select jsonb_agg(jsonb_build_object('id',p.id,'status',p.status,'court',p.court_number,'queue',p.queue_position,'group',p.group_id) order by p.queue_position,p.id)
    into player_after from public.waitlist_players p where p.facility_id=fid;
  if player_after is distinct from players_before then raise exception 'KOTC -> 2on2 rewrote permanent player semantics'; end if;
  if c2_before is distinct from (select jsonb_build_object('game',game_number,'rule',hybrid_rotation_rule,'threshold',hybrid_auto_kotc_threshold_teams,'armed',hybrid_auto_kotc_armed,'version',hybrid_config_version,'wins',team_max_wins) from public.waitlist_courts where facility_id=fid and court_number=2) then
    raise exception 'Court 1 transition changed Court 2'; end if;
  perform public.evaluate_hybrid_auto_kotc_transition(fid);
  if (select hybrid_rotation_rule from public.waitlist_courts where facility_id=fid and court_number=1)<>'two_on_two_off' then raise exception 'above-threshold manual 2on2 immediately retriggered KOTC'; end if;

  delete from public.waitlist_players where facility_id=fid and id in(accepted,invited);
  perform public.evaluate_hybrid_auto_kotc_transition(fid);
  if not (select hybrid_auto_kotc_armed from public.waitlist_courts where facility_id=fid and court_number=1) then raise exception 'below-threshold observation did not re-arm Court 1'; end if;
  insert into public.waitlist_players(id,facility_id,first_name,last_name,display_name,status,queue_position)
    values(accepted,fid,'Accepted','','Accepted','waiting',200),(invited,fid,'Invited','','Invited','waiting',201);
  perform public.evaluate_hybrid_auto_kotc_transition(fid);
  if not exists(select 1 from public.waitlist_courts where facility_id=fid and court_number=1 and hybrid_rotation_rule='kotc' and not hybrid_auto_kotc_armed) then
    raise exception 'fresh upward crossing did not transition only the re-armed Court 1'; end if;

  -- KOTC configuration itself never rearranges a current game. A subsequent
  -- explicit start creates fresh zero-streak appearances and leaves Court 2 intact.
  select hybrid_config_version into c1_version from public.waitlist_courts where facility_id=fid and court_number=1;
  stale_version:=c1_version;
  perform public.configure_hybrid_waitlist(fid,1,c1_version,'kotc',null,3);
  if player_after is distinct from (select jsonb_agg(jsonb_build_object('id',p.id,'status',p.status,'court',p.court_number,'queue',p.queue_position,'group',p.group_id) order by p.queue_position,p.id) from public.waitlist_players p where p.facility_id=fid)
     or exists(select 1 from public.hybrid_kotc_teams where facility_id=fid and court_number=1) then
    raise exception '2on2 -> KOTC configuration rearranged players or created stale appearances'; end if;
  select hybrid_config_version into c1_version from public.waitlist_courts where facility_id=fid and court_number=1;
  perform public.bootstrap_hybrid_kotc_game(fid,1,c1_version);
  if (select count(*) from public.hybrid_kotc_teams where facility_id=fid and court_number=1 and status='current')<>2
     or exists(select 1 from public.hybrid_kotc_teams where facility_id=fid and court_number=1 and consecutive_wins<>0)
     or (select count(*) from public.hybrid_kotc_slots s join public.hybrid_kotc_teams t on t.id=s.team_id and t.facility_id=s.facility_id where t.facility_id=fid and t.court_number=1)<>12
     or c2_before is distinct from (select jsonb_build_object('game',game_number,'rule',hybrid_rotation_rule,'threshold',hybrid_auto_kotc_threshold_teams,'armed',hybrid_auto_kotc_armed,'version',hybrid_config_version,'wins',team_max_wins) from public.waitlist_courts where facility_id=fid and court_number=2)
  then raise exception 'new Court 1 KOTC appearance was not fresh and isolated'; end if;

  -- A pre-transition configuration version is a CAS boundary and non-admins
  -- cannot mutate the target court format.
  perform set_config('request.jwt.claim.sub',member_id::text,true);
  begin perform public.configure_hybrid_waitlist(fid,1,c1_version,'two_on_two_off',null,2); raise exception 'non-admin mode transition succeeded';
  exception when others then if position('Admin access required' in sqlerrm)=0 then raise; end if; end;
  perform set_config('request.jwt.claim.sub',admin_id::text,true);
  begin perform public.configure_hybrid_waitlist(fid,1,stale_version,'two_on_two_off',null,2); raise exception 'stale pre-transition configuration succeeded';
  exception when others then if position('configuration changed' in lower(sqlerrm))=0 then raise; end if; end;

  raise notice 'Stage 9 court-scoped KOTC <-> 2on2 transition matrix PASS';
end $$;

rollback;
