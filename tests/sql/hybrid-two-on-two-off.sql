-- Local-only Stage 2 public-path contract: hybrid two-on-two-off is Rejoin.
begin;
do $$
declare fid uuid:=gen_random_uuid(); admin uuid:=gen_random_uuid(); host uuid:=gen_random_uuid(); p1 uuid:=gen_random_uuid(); p2 uuid:=gen_random_uuid(); waiter uuid:=gen_random_uuid(); gid uuid:=gen_random_uuid(); before_players jsonb; result jsonb;
begin
  insert into public.facilities(id,name,slug,code) values(fid,'Local hybrid 2-on-2','local-hybrid-2o2-'||left(fid::text,8),left(fid::text,8));
  insert into auth.users(id,instance_id,aud,role,email) values(admin,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',admin||'@example.test'),(host,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',host||'@example.test');
  insert into public.facility_admin_credentials(facility_id,username,display_username,password_hash) values(fid,'admin','Admin',crypt('local-only-password',gen_salt('bf')));
  insert into public.admin_sessions(user_id,username,facility_id) values(admin,'admin',fid);
  insert into public.user_facility_sessions(user_id,facility_id) values(admin,fid),(host,fid);
  insert into public.waitlist_config(facility_id,id,game_number,max_players,mode,court_count,geofence_enabled) values(fid,true,1,12,'rejoin',1,false);
  insert into public.waitlist_courts(facility_id,court_number,game_number,team_mode) values(fid,1,1,'rotation'); insert into public.daily_waitlist_reset_state(facility_id,id) values(fid,true);
  perform set_config('request.jwt.claim.sub',admin::text,true);
  insert into public.waitlist_players(id,facility_id,user_id,first_name,last_name,display_name,status,queue_position,court_number,group_id) values(p1,fid,admin,'One','','One','current',1,1,gid),(p2,fid,null,'Two','','Two','current',2,1,gid),(waiter,fid,null,'Wait','','Wait','waiting',3,null,null);
  select jsonb_agg(jsonb_build_object('id',id,'status',status,'queue',queue_position,'court',court_number,'group',group_id) order by queue_position) into before_players from public.waitlist_players where facility_id=fid;
  perform public.set_open_gym_mode('hybrid_waitlist');
  if not exists(select 1 from public.waitlist_config where facility_id=fid and mode='hybrid_waitlist' and hybrid_rotation_rule='two_on_two_off' and hybrid_auto_kotc_threshold_teams is null and not hybrid_auto_kotc_armed) then raise exception 'hybrid defaults were not initialized'; end if;
  if before_players is distinct from (select jsonb_agg(jsonb_build_object('id',id,'status',status,'queue',queue_position,'court',court_number,'group',group_id) order by queue_position) from public.waitlist_players where facility_id=fid) then raise exception 'mode entry moved player state'; end if;
  if exists(select 1 from public.hybrid_kotc_teams where facility_id=fid) or exists(select 1 from public.hybrid_kotc_slots where facility_id=fid) or exists(select 1 from public.hybrid_kotc_substitutes where facility_id=fid) then raise exception 'two-on-two-off created KOTC state'; end if;
  perform set_config('request.jwt.claim.sub',host::text,true);
  begin perform public.set_open_gym_mode('regular'); raise exception 'host changed mode'; exception when others then if position('Admin access required' in sqlerrm)=0 then raise; end if; end;
  perform set_config('request.jwt.claim.sub',admin::text,true);
  result:=public.advance_court_game(1,fid,1);
  if (select status from public.waitlist_players where id=p1)<>'rejoin' or (select status from public.waitlist_players where id=p2)<>'rejoin' or (select group_id from public.waitlist_players where id=p1) is distinct from gid or not exists(select 1 from public.rejoin_responses where facility_id=fid and user_id=admin and choice is null) then raise exception 'hybrid advance did not delegate to Rejoin'; end if;
  if exists(select 1 from public.hybrid_kotc_teams where facility_id=fid) then raise exception 'hybrid advance invoked KOTC'; end if;
  begin perform public.advance_court_game(1,fid,1); raise exception 'stale advance succeeded'; exception when others then if position('changed' in sqlerrm)=0 then raise; end if; end;
  raise notice 'hybrid two-on-two-off Admin entry and Rejoin delegation PASS';
end $$;
rollback;
