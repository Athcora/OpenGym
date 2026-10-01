-- Local-only fixture for two simultaneous courts in one shared hybrid queue.
delete from public.court_game_reversals where facility_id='11111111-1111-4111-8111-111111111111';
delete from public.past_games where facility_id='11111111-1111-4111-8111-111111111111';
delete from public.facilities where id='11111111-1111-4111-8111-111111111111';
delete from auth.users where id in ('11111111-1111-4111-8111-111111111112','11111111-1111-4111-8111-111111111113');
insert into public.facilities(id,name,slug,code) values('11111111-1111-4111-8111-111111111111','Local multicourt','local-multicourt','LMULTI');
insert into auth.users(id,instance_id,aud,role,email) values
 ('11111111-1111-4111-8111-111111111112','00000000-0000-0000-0000-000000000000','authenticated','authenticated','one@local.test'),
 ('11111111-1111-4111-8111-111111111113','00000000-0000-0000-0000-000000000000','authenticated','authenticated','two@local.test');
insert into public.facility_admin_credentials(facility_id,username,display_username,password_hash) values('11111111-1111-4111-8111-111111111111','admin','Admin',crypt('local-only-password',gen_salt('bf')));
insert into public.admin_sessions(user_id,username,facility_id) values('11111111-1111-4111-8111-111111111112','admin','11111111-1111-4111-8111-111111111111');
insert into public.user_facility_sessions(user_id,facility_id) values('11111111-1111-4111-8111-111111111112','11111111-1111-4111-8111-111111111111'),('11111111-1111-4111-8111-111111111113','11111111-1111-4111-8111-111111111111');
insert into public.waitlist_config(facility_id,id,game_number,max_players,mode,court_count,geofence_enabled,hybrid_rotation_rule) values('11111111-1111-4111-8111-111111111111',true,1,24,'hybrid_waitlist',2,false,'kotc');
insert into public.waitlist_courts(facility_id,court_number,game_number,team_mode) values('11111111-1111-4111-8111-111111111111',1,1,'king'),('11111111-1111-4111-8111-111111111111',2,1,'king');
insert into public.hybrid_kotc_court_state(facility_id,court_number,version) values('11111111-1111-4111-8111-111111111111',1,101),('11111111-1111-4111-8111-111111111111',2,201); insert into public.daily_waitlist_reset_state(facility_id,id) values('11111111-1111-4111-8111-111111111111',true);
select set_config('request.jwt.claim.sub','11111111-1111-4111-8111-111111111112',false);
insert into public.waitlist_players(id,facility_id,user_id,first_name,last_name,display_name,status,queue_position,court_number) values
 ('11111111-1111-4111-8111-111111111114','11111111-1111-4111-8111-111111111111','11111111-1111-4111-8111-111111111112','C1A','','C1A','current',1,1),('11111111-1111-4111-8111-111111111115','11111111-1111-4111-8111-111111111111',null,'C1B','','C1B','current',2,1),
 ('11111111-1111-4111-8111-111111111116','11111111-1111-4111-8111-111111111111','11111111-1111-4111-8111-111111111113','C2A','','C2A','current',3,2),('11111111-1111-4111-8111-111111111117','11111111-1111-4111-8111-111111111111',null,'C2B','','C2B','current',4,2);
insert into public.waitlist_players(id,facility_id,first_name,last_name,display_name,status,queue_position) select gen_random_uuid(),'11111111-1111-4111-8111-111111111111','W'||n,'','W'||n,'waiting',10+n from generate_series(1,24)n;
insert into public.hybrid_kotc_teams(id,facility_id,court_number,court_side,appearance_game_number,status) values
 ('11111111-1111-4111-8111-111111111118','11111111-1111-4111-8111-111111111111',1,1,1,'current'),('11111111-1111-4111-8111-111111111119','11111111-1111-4111-8111-111111111111',1,2,1,'current'),
 ('11111111-1111-4111-8111-111111111120','11111111-1111-4111-8111-111111111111',2,1,1,'current'),('11111111-1111-4111-8111-111111111121','11111111-1111-4111-8111-111111111111',2,2,1,'current');
insert into public.hybrid_kotc_slots(facility_id,team_id,slot_number,player_id) values
 ('11111111-1111-4111-8111-111111111111','11111111-1111-4111-8111-111111111118',1,'11111111-1111-4111-8111-111111111114'),('11111111-1111-4111-8111-111111111111','11111111-1111-4111-8111-111111111119',1,'11111111-1111-4111-8111-111111111115'),
 ('11111111-1111-4111-8111-111111111111','11111111-1111-4111-8111-111111111120',1,'11111111-1111-4111-8111-111111111116'),('11111111-1111-4111-8111-111111111111','11111111-1111-4111-8111-111111111121',1,'11111111-1111-4111-8111-111111111117');
