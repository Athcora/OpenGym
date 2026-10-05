-- Local-only paired contract: Rejoin and dormant Hybrid must produce the same
-- authoritative player/court/rejoin result for a grouped, sit-out, two-court fixture.
begin;
do $$
declare fa uuid:=gen_random_uuid(); fb uuid:=gen_random_uuid(); ua uuid:=gen_random_uuid(); ub uuid:=gen_random_uuid(); a1 uuid:=gen_random_uuid(); a2 uuid:=gen_random_uuid(); b1 uuid:=gen_random_uuid(); b2 uuid:=gen_random_uuid(); group_id uuid:=gen_random_uuid(); sa jsonb; sb jsonb;
begin
  insert into auth.users(id,instance_id,aud,role,email) values(ua,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',ua||'@example.test'),(ub,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',ub||'@example.test');
  insert into public.facilities(id,name,slug,code) values(fa,'Compare rejoin','local-compare-a-'||left(fa::text,8),left(fa::text,8)),(fb,'Compare hybrid','local-compare-b-'||left(fb::text,8),left(fb::text,8));
  insert into public.facility_admin_credentials(facility_id,username,display_username,password_hash) values(fa,'admina','Admin A',crypt('x',gen_salt('bf'))),(fb,'adminb','Admin B',crypt('x',gen_salt('bf')));
  insert into public.admin_sessions(user_id,username,facility_id) values(ua,'admina',fa),(ub,'adminb',fb); insert into public.user_facility_sessions(user_id,facility_id) values(ua,fa),(ub,fb);
  insert into public.waitlist_config(facility_id,id,game_number,max_players,mode,court_count,geofence_enabled,hybrid_rotation_rule,hybrid_auto_kotc_armed) values(fa,true,1,12,'rejoin',2,false,'two_on_two_off',false),(fb,true,1,12,'hybrid_waitlist',2,false,'two_on_two_off',false);
  insert into public.waitlist_courts(facility_id,court_number,game_number,team_mode) values(fa,1,1,'rotation'),(fa,2,1,'rotation'),(fb,1,1,'rotation'),(fb,2,1,'rotation'); insert into public.daily_waitlist_reset_state(facility_id,id) values(fa,true),(fb,true);
  perform set_config('request.jwt.claim.sub',ua::text,true);
  insert into public.waitlist_players(id,facility_id,user_id,first_name,last_name,display_name,status,queue_position,court_number,group_id,sitout_from_game) values(a1,fa,ua,'One','','One','current',1,1,group_id,null),(a2,fa,null,'Two','','Two','current',2,1,group_id,null),(gen_random_uuid(),fa,null,'Wait','','Wait','waiting',3,null,null,null),(gen_random_uuid(),fa,null,'Sit','','Sit','sitout',4,null,null,1),(gen_random_uuid(),fa,null,'Three','','Three','current',5,2,null,null),(gen_random_uuid(),fa,null,'Four','','Four','current',6,2,null,null);
  perform set_config('request.jwt.claim.sub',ub::text,true);
  insert into public.waitlist_players(id,facility_id,user_id,first_name,last_name,display_name,status,queue_position,court_number,group_id,sitout_from_game) values(b1,fb,ub,'One','','One','current',1,1,group_id,null),(b2,fb,null,'Two','','Two','current',2,1,group_id,null),(gen_random_uuid(),fb,null,'Wait','','Wait','waiting',3,null,null,null),(gen_random_uuid(),fb,null,'Sit','','Sit','sitout',4,null,null,1),(gen_random_uuid(),fb,null,'Three','','Three','current',5,2,null,null),(gen_random_uuid(),fb,null,'Four','','Four','current',6,2,null,null);
  perform set_config('request.jwt.claim.sub',ua::text,true); perform public.advance_court_game(1,fa,1);
  perform set_config('request.jwt.claim.sub',ub::text,true); perform public.advance_court_game(1,fb,1);
  select jsonb_agg(jsonb_build_object('name',p.display_name,'status',p.status,'queue',p.queue_position,'court',p.court_number,'group',p.group_id is not null,'rejoin',p.rejoin_expires_at is not null) order by p.display_name) into sa from public.waitlist_players p where p.facility_id=fa;
  select jsonb_agg(jsonb_build_object('name',p.display_name,'status',p.status,'queue',p.queue_position,'court',p.court_number,'group',p.group_id is not null,'rejoin',p.rejoin_expires_at is not null) order by p.display_name) into sb from public.waitlist_players p where p.facility_id=fb;
  if sa is distinct from sb then raise exception 'hybrid two-on-two-off diverged from Rejoin: % vs %',sa,sb; end if;
  if exists(select 1 from public.waitlist_players where facility_id=fa and display_name in('Three','Four') and court_number<>2) or exists(select 1 from public.waitlist_players where facility_id=fb and display_name in('Three','Four') and court_number<>2) then raise exception 'Court 1 advance moved Court 2'; end if;
  perform set_config('request.jwt.claim.sub',ua::text,true); perform public.advance_court_game(2,fa,1);
  perform set_config('request.jwt.claim.sub',ub::text,true); perform public.advance_court_game(2,fb,1);
  select jsonb_agg(jsonb_build_object('name',p.display_name,'status',p.status,'queue',p.queue_position,'court',p.court_number,'group',p.group_id is not null,'rejoin',p.rejoin_expires_at is not null) order by p.display_name) into sa from public.waitlist_players p where p.facility_id=fa;
  select jsonb_agg(jsonb_build_object('name',p.display_name,'status',p.status,'queue',p.queue_position,'court',p.court_number,'group',p.group_id is not null,'rejoin',p.rejoin_expires_at is not null) order by p.display_name) into sb from public.waitlist_players p where p.facility_id=fb;
  if sa is distinct from sb then raise exception 'Court 2 hybrid outcome diverged from Rejoin'; end if;
  if exists(select 1 from public.hybrid_kotc_teams where facility_id=fb) or exists(select 1 from public.hybrid_kotc_slots where facility_id=fb) then raise exception 'dormant hybrid created KOTC state'; end if;
  raise notice 'hybrid two-on-two-off Rejoin equivalence PASS';
end $$;
rollback;
