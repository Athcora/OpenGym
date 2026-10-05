-- Durable Stage 6 local-only swap/result race fixture.  Fixed identities make
-- both independent callers and the final invariant query unambiguous.
drop trigger if exists local_stage6_swap_result_pause on public.waitlist_players;
drop function if exists public.local_stage6_swap_result_pause();
delete from public.court_game_reversals where facility_id='68666666-6666-4666-8666-666666666661';
delete from public.past_games where facility_id='68666666-6666-4666-8666-666666666661';
delete from public.facilities where id='68666666-6666-4666-8666-666666666661';
delete from auth.users where id='68666666-6666-4666-8666-666666666662';
insert into public.facilities(id,name,slug,code) values('68666666-6666-4666-8666-666666666661','Stage6 swap result race','stage6-swap-result-race','S6SR');
insert into auth.users(id,instance_id,aud,role,email) values('68666666-6666-4666-8666-666666666662','00000000-0000-0000-0000-000000000000','authenticated','authenticated','stage6-swap-result-admin@example.test');
insert into public.user_facility_sessions(user_id,facility_id) values('68666666-6666-4666-8666-666666666662','68666666-6666-4666-8666-666666666661');
insert into public.facility_admin_credentials(facility_id,username,display_username,password_hash) values('68666666-6666-4666-8666-666666666661','admin','Admin',crypt('local',gen_salt('bf')));
insert into public.admin_sessions(user_id,username,facility_id) values('68666666-6666-4666-8666-666666666662','admin','68666666-6666-4666-8666-666666666661');
select set_config('request.jwt.claim.sub','68666666-6666-4666-8666-666666666662',false);
insert into public.waitlist_config(facility_id,id,game_number,max_players,mode,court_count,geofence_enabled,hybrid_rotation_rule) values('68666666-6666-4666-8666-666666666661',true,1,24,'hybrid_waitlist',1,false,'kotc');
insert into public.waitlist_courts(facility_id,court_number,game_number,team_mode) values('68666666-6666-4666-8666-666666666661',1,1,'king');
insert into public.daily_waitlist_reset_state(facility_id,id) values('68666666-6666-4666-8666-666666666661',true);
insert into public.hybrid_kotc_court_state(facility_id,court_number,version,initialized_game_number) values('68666666-6666-4666-8666-666666666661',1,20,1);
insert into public.waitlist_players(id,facility_id,user_id,first_name,last_name,display_name,status,queue_position,court_number,group_id) values
 ('68666666-6666-4666-8666-666666666664','68666666-6666-4666-8666-666666666661','68666666-6666-4666-8666-666666666662','B','','B','current',1,1,'68666666-6666-4666-8666-666666666690'),
 ('68666666-6666-4666-8666-666666666665','68666666-6666-4666-8666-666666666661',null,'C','','C','current',2,1,'68666666-6666-4666-8666-666666666690'),
 ('68666666-6666-4666-8666-666666666666','68666666-6666-4666-8666-666666666661',null,'D','','D','current',3,1,null),('68666666-6666-4666-8666-666666666667','68666666-6666-4666-8666-666666666661',null,'E','','E','current',4,1,null),
 ('68666666-6666-4666-8666-666666666668','68666666-6666-4666-8666-666666666661',null,'F','','F','current',5,1,null),('68666666-6666-4666-8666-666666666669','68666666-6666-4666-8666-666666666661',null,'G','','G','current',6,1,null),
 ('68666666-6666-4666-8666-666666666670','68666666-6666-4666-8666-666666666661',null,'H','','H','current',7,1,null),('68666666-6666-4666-8666-666666666671','68666666-6666-4666-8666-666666666661',null,'I','','I','current',8,1,null),
 ('68666666-6666-4666-8666-666666666672','68666666-6666-4666-8666-666666666661',null,'S','','S','waiting',20,null,null);
insert into public.waitlist_players(id,facility_id,first_name,last_name,display_name,status,queue_position) select gen_random_uuid(),'68666666-6666-4666-8666-666666666661','Q'||n,'','Q'||n,'waiting',30+n from generate_series(1,6)n;
insert into public.hybrid_kotc_teams(id,facility_id,court_number,court_side,appearance_game_number,status) values ('68666666-6666-4666-8666-666666666680','68666666-6666-4666-8666-666666666661',1,1,1,'current'),('68666666-6666-4666-8666-666666666681','68666666-6666-4666-8666-666666666661',1,2,1,'current');
insert into public.hybrid_kotc_slots(facility_id,team_id,slot_number,player_id,original_group_id) values
 ('68666666-6666-4666-8666-666666666661','68666666-6666-4666-8666-666666666680',1,'68666666-6666-4666-8666-666666666664','68666666-6666-4666-8666-666666666690'),('68666666-6666-4666-8666-666666666661','68666666-6666-4666-8666-666666666680',2,'68666666-6666-4666-8666-666666666665','68666666-6666-4666-8666-666666666690'),('68666666-6666-4666-8666-666666666661','68666666-6666-4666-8666-666666666680',3,'68666666-6666-4666-8666-666666666666',null),('68666666-6666-4666-8666-666666666661','68666666-6666-4666-8666-666666666680',4,'68666666-6666-4666-8666-666666666667',null),
 ('68666666-6666-4666-8666-666666666661','68666666-6666-4666-8666-666666666681',1,'68666666-6666-4666-8666-666666666668',null),('68666666-6666-4666-8666-666666666661','68666666-6666-4666-8666-666666666681',2,'68666666-6666-4666-8666-666666666669',null),('68666666-6666-4666-8666-666666666661','68666666-6666-4666-8666-666666666681',3,'68666666-6666-4666-8666-666666666670',null),('68666666-6666-4666-8666-666666666661','68666666-6666-4666-8666-666666666681',4,'68666666-6666-4666-8666-666666666671',null);
create function public.local_stage6_swap_result_pause() returns trigger language plpgsql as $$ begin perform pg_sleep(3); return new; end $$;
create trigger local_stage6_swap_result_pause before update of group_id on public.waitlist_players for each row when (old.id='68666666-6666-4666-8666-666666666672'::uuid and new.group_id='68666666-6666-4666-8666-666666666690'::uuid) execute function public.local_stage6_swap_result_pause();
