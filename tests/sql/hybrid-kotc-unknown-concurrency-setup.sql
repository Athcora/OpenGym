-- Durable local fixture for two independent unknown-side KOTC callers.
-- psql invocation supplies `-v race=same` or `-v race=opposing`.
\if :{?race}
\else
\set race same
\endif
drop trigger if exists local_stage5_unknown_pause on public.past_games;
drop function if exists public.local_stage5_unknown_pause();
delete from public.court_game_reversals where facility_id='55555555-5555-4555-8555-555555555551';
delete from public.past_games where facility_id='55555555-5555-4555-8555-555555555551';
delete from public.facilities where id='55555555-5555-4555-8555-555555555551';
delete from auth.users where id in ('55555555-5555-4555-8555-555555555552','55555555-5555-4555-8555-555555555553');
insert into public.facilities(id,name,slug,code) values('55555555-5555-4555-8555-555555555551','Stage5 unknown race','stage5-unknown-race','S5UR');
insert into auth.users(id,instance_id,aud,role,email) values
  ('55555555-5555-4555-8555-555555555552','00000000-0000-0000-0000-000000000000','authenticated','authenticated','stage5-race-a@example.test'),
  ('55555555-5555-4555-8555-555555555553','00000000-0000-0000-0000-000000000000','authenticated','authenticated','stage5-race-b@example.test');
insert into public.user_facility_sessions(user_id,facility_id) values
  ('55555555-5555-4555-8555-555555555552','55555555-5555-4555-8555-555555555551'),
  ('55555555-5555-4555-8555-555555555553','55555555-5555-4555-8555-555555555551');
select set_config('request.jwt.claim.sub','55555555-5555-4555-8555-555555555552',false);
insert into public.waitlist_config(facility_id,id,game_number,max_players,mode,court_count,geofence_enabled,hybrid_rotation_rule)
  values('55555555-5555-4555-8555-555555555551',true,1,24,'hybrid_waitlist',1,false,'kotc');
insert into public.waitlist_courts(facility_id,court_number,game_number,team_mode) values('55555555-5555-4555-8555-555555555551',1,1,'king');
insert into public.daily_waitlist_reset_state(facility_id,id) values('55555555-5555-4555-8555-555555555551',true);
insert into public.hybrid_kotc_court_state(facility_id,court_number,version,initialized_game_number) values('55555555-5555-4555-8555-555555555551',1,40,1);
insert into public.waitlist_players(id,facility_id,user_id,first_name,last_name,display_name,status,queue_position,court_number) values
 ('55555555-5555-4555-8555-555555555554','55555555-5555-4555-8555-555555555551','55555555-5555-4555-8555-555555555552','A','','A','current',1,1),
 ('55555555-5555-4555-8555-555555555555','55555555-5555-4555-8555-555555555551',case when :'race'='same' then '55555555-5555-4555-8555-555555555553'::uuid else null end,'B','','B','current',2,1),
 ('55555555-5555-4555-8555-555555555556','55555555-5555-4555-8555-555555555551',case when :'race'='opposing' then '55555555-5555-4555-8555-555555555553'::uuid else null end,'C','','C','current',3,1),
 ('55555555-5555-4555-8555-555555555557','55555555-5555-4555-8555-555555555551',null,'D','','D','current',4,1);
create function public.local_stage5_unknown_pause() returns trigger language plpgsql as $$ begin perform pg_sleep(3); return new; end $$;
create trigger local_stage5_unknown_pause before insert on public.past_games for each row execute function public.local_stage5_unknown_pause();
