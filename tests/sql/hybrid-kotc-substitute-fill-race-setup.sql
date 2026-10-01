-- Durable local Stage 6 race fixture.  The callers below run in two separate
-- psql backends.  The short trigger pause makes the overlap observable while
-- production constraints and the public guarded RPC do all state mutation.
drop trigger if exists local_stage6_fill_pause on public.hybrid_kotc_slots;
drop function if exists public.local_stage6_fill_pause();
delete from public.court_game_reversals where facility_id='66666666-6666-4666-8666-666666666661';
delete from public.past_games where facility_id='66666666-6666-4666-8666-666666666661';
delete from public.facilities where id='66666666-6666-4666-8666-666666666661';
delete from auth.users where id in ('66666666-6666-4666-8666-666666666662','66666666-6666-4666-8666-666666666663');

insert into public.facilities(id,name,slug,code) values
 ('66666666-6666-4666-8666-666666666661','Stage6 fill race','stage6-fill-race','S6FR');
insert into auth.users(id,instance_id,aud,role,email) values
 ('66666666-6666-4666-8666-666666666662','00000000-0000-0000-0000-000000000000','authenticated','authenticated','stage6-fill-a@example.test'),
 ('66666666-6666-4666-8666-666666666663','00000000-0000-0000-0000-000000000000','authenticated','authenticated','stage6-fill-b@example.test');
insert into public.user_facility_sessions(user_id,facility_id) values
 ('66666666-6666-4666-8666-666666666662','66666666-6666-4666-8666-666666666661'),
 ('66666666-6666-4666-8666-666666666663','66666666-6666-4666-8666-666666666661');
select set_config('request.jwt.claim.sub','66666666-6666-4666-8666-666666666662',false);
insert into public.waitlist_config(facility_id,id,game_number,max_players,mode,court_count,geofence_enabled,hybrid_rotation_rule)
 values('66666666-6666-4666-8666-666666666661',true,1,24,'hybrid_waitlist',1,false,'kotc');
insert into public.waitlist_courts(facility_id,court_number,game_number,team_mode)
 values('66666666-6666-4666-8666-666666666661',1,1,'king');
insert into public.daily_waitlist_reset_state(facility_id,id) values('66666666-6666-4666-8666-666666666661',true);
insert into public.hybrid_kotc_court_state(facility_id,court_number,version,initialized_game_number)
 values('66666666-6666-4666-8666-666666666661',1,50,1);
insert into public.waitlist_players(id,facility_id,user_id,first_name,last_name,display_name,status,queue_position,court_number) values
 ('66666666-6666-4666-8666-666666666664','66666666-6666-4666-8666-666666666661',null,'A','','A','current',1,1),
 ('66666666-6666-4666-8666-666666666665','66666666-6666-4666-8666-666666666661',null,'B','','B','current',2,1),
 ('66666666-6666-4666-8666-666666666666','66666666-6666-4666-8666-666666666661',null,'C','','C','current',3,1),
 ('66666666-6666-4666-8666-666666666667','66666666-6666-4666-8666-666666666661',null,'D','','D','current',4,1),
 ('66666666-6666-4666-8666-666666666668','66666666-6666-4666-8666-666666666661','66666666-6666-4666-8666-666666666662','Fill A','','Fill A','waiting',5,null),
 ('66666666-6666-4666-8666-666666666669','66666666-6666-4666-8666-666666666661','66666666-6666-4666-8666-666666666663','Fill B','','Fill B','waiting',6,null);
insert into public.hybrid_kotc_teams(id,facility_id,court_number,court_side,appearance_game_number,status)
 values('66666666-6666-4666-8666-666666666670','66666666-6666-4666-8666-666666666661',1,1,1,'current');
insert into public.hybrid_kotc_slots(facility_id,team_id,slot_number,player_id,is_substitute) values
 ('66666666-6666-4666-8666-666666666661','66666666-6666-4666-8666-666666666670',1,'66666666-6666-4666-8666-666666666664',false),
 ('66666666-6666-4666-8666-666666666661','66666666-6666-4666-8666-666666666670',2,'66666666-6666-4666-8666-666666666665',false),
 ('66666666-6666-4666-8666-666666666661','66666666-6666-4666-8666-666666666670',3,'66666666-6666-4666-8666-666666666666',false),
 ('66666666-6666-4666-8666-666666666661','66666666-6666-4666-8666-666666666670',4,'66666666-6666-4666-8666-666666666667',false),
 ('66666666-6666-4666-8666-666666666661','66666666-6666-4666-8666-666666666670',5,null,false);
create function public.local_stage6_fill_pause() returns trigger language plpgsql as $$ begin perform pg_sleep(3); return new; end $$;
create trigger local_stage6_fill_pause before update of player_id on public.hybrid_kotc_slots
 for each row when (old.player_id is null and new.player_id is not null) execute function public.local_stage6_fill_pause();
