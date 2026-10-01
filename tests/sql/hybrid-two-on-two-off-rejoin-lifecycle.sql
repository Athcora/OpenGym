-- Local-only Stage 2 contract: dormant hybrid matches ordinary Rejoin through
-- a real player response and a persisted state reread; it must not arm KOTC.
begin;
do $$
declare
  legacy_fid uuid:=gen_random_uuid(); hybrid_fid uuid:=gen_random_uuid();
  legacy_user uuid:=gen_random_uuid(); hybrid_user uuid:=gen_random_uuid();
  legacy_response uuid; hybrid_response uuid; legacy_state jsonb; hybrid_state jsonb;
begin
  insert into auth.users(id,instance_id,aud,role,email) values
    (legacy_user,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',legacy_user||'@example.test'),
    (hybrid_user,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',hybrid_user||'@example.test');
  insert into public.facilities(id,name,slug,code) values
    (legacy_fid,'Local Rejoin lifecycle','local-rj-life-'||left(legacy_fid::text,8),left(legacy_fid::text,8)),
    (hybrid_fid,'Local hybrid lifecycle','local-hy-life-'||left(hybrid_fid::text,8),left(hybrid_fid::text,8));
  insert into public.facility_admin_credentials(facility_id,username,display_username,password_hash) values
    (legacy_fid,'legacyadmin','Legacy',crypt('x',gen_salt('bf'))),(hybrid_fid,'hybridadmin','Hybrid',crypt('x',gen_salt('bf')));
  insert into public.admin_sessions(user_id,username,facility_id) values
    (legacy_user,'legacyadmin',legacy_fid),(hybrid_user,'hybridadmin',hybrid_fid);
  insert into public.user_facility_sessions(user_id,facility_id) values(legacy_user,legacy_fid),(hybrid_user,hybrid_fid);
  insert into public.waitlist_config(facility_id,id,game_number,max_players,mode,court_count,geofence_enabled,hybrid_rotation_rule,hybrid_auto_kotc_armed) values
    (legacy_fid,true,1,2,'rejoin',1,false,'two_on_two_off',false),
    (hybrid_fid,true,1,2,'hybrid_waitlist',1,false,'two_on_two_off',false);
  insert into public.waitlist_courts(facility_id,court_number,game_number,team_mode) values
    (legacy_fid,1,1,'rotation'),(hybrid_fid,1,1,'rotation');
  insert into public.daily_waitlist_reset_state(facility_id,id) values(legacy_fid,true),(hybrid_fid,true);
  perform set_config('request.jwt.claim.sub',legacy_user::text,true);
  insert into public.waitlist_players(facility_id,user_id,first_name,last_name,display_name,status,queue_position,court_number,group_id) values
    (legacy_fid,legacy_user,'Player','','Player','current',1,1,'11111111-1111-4111-8111-111111111111'),
    (legacy_fid,null,'Mate','','Mate','current',2,1,'11111111-1111-4111-8111-111111111111'),
    (legacy_fid,null,'Wait','','Wait','waiting',3,null,null),
    (legacy_fid,null,'Sit','','Sit','sitout',4,null,null);
  perform set_config('request.jwt.claim.sub',hybrid_user::text,true);
  insert into public.waitlist_players(facility_id,user_id,first_name,last_name,display_name,status,queue_position,court_number,group_id) values
    (hybrid_fid,hybrid_user,'Player','','Player','current',1,1,'11111111-1111-4111-8111-111111111111'),
    (hybrid_fid,null,'Mate','','Mate','current',2,1,'11111111-1111-4111-8111-111111111111'),
    (hybrid_fid,null,'Wait','','Wait','waiting',3,null,null),
    (hybrid_fid,null,'Sit','','Sit','sitout',4,null,null);
  perform set_config('request.jwt.claim.sub',legacy_user::text,true);
  perform public.advance_court_game(1,legacy_fid,1);
  select id into legacy_response from public.rejoin_responses where facility_id=legacy_fid and user_id=legacy_user and choice is null;
  if legacy_response is null then raise exception 'legacy prompt missing'; end if;
  perform public.answer_rejoin_prompt(legacy_response,'stay');
  perform set_config('request.jwt.claim.sub',hybrid_user::text,true);
  perform public.advance_court_game(1,hybrid_fid,1);
  select id into hybrid_response from public.rejoin_responses where facility_id=hybrid_fid and user_id=hybrid_user and choice is null;
  if hybrid_response is null then raise exception 'hybrid prompt missing'; end if;
  perform public.answer_rejoin_prompt(hybrid_response,'stay');
  select jsonb_agg(jsonb_build_object('name',display_name,'status',status,'queue',queue_position,'court',court_number,'group',group_id is not null,'timer',rejoin_expires_at is not null) order by display_name)
    into legacy_state from public.waitlist_players where facility_id=legacy_fid;
  select jsonb_agg(jsonb_build_object('name',display_name,'status',status,'queue',queue_position,'court',court_number,'group',group_id is not null,'timer',rejoin_expires_at is not null) order by display_name)
    into hybrid_state from public.waitlist_players where facility_id=hybrid_fid;
  if legacy_state is distinct from hybrid_state then raise exception 'hybrid rejoin lifecycle diverged: % vs %',legacy_state,hybrid_state; end if;
  if exists(select 1 from public.hybrid_kotc_teams where facility_id=hybrid_fid)
    or exists(select 1 from public.hybrid_kotc_slots where facility_id=hybrid_fid)
    or exists(select 1 from public.waitlist_config where facility_id=hybrid_fid and (hybrid_auto_kotc_armed or hybrid_auto_kotc_threshold_teams is not null)) then
    raise exception 'dormant hybrid armed or created KOTC state';
  end if;
  if not exists(select 1 from public.rejoin_responses where id=hybrid_response and choice='stay' and answered_at is not null) then
    raise exception 'hybrid response did not persist';
  end if;
  raise notice 'hybrid Rejoin response, Sit Out, persistence, and KOTC dormancy PASS';
end $$;
rollback;
