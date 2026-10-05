-- Retained Stage 3 fixture.  The two callers use distinct auth identities and
-- distinct backend sessions; the known facility UUID keeps cleanup scoped.
delete from public.facilities where id='30000000-0000-4000-8000-000000000001';
insert into public.facilities(id,name,slug,code) values
  ('30000000-0000-4000-8000-000000000001','Stage 3 configuration race','stage3-config-race','S3RACE');
insert into auth.users(id,instance_id,aud,role,email) values
  ('30000000-0000-4000-8000-000000000011','00000000-0000-0000-0000-000000000000','authenticated','authenticated','stage3a@example.test'),
  ('30000000-0000-4000-8000-000000000012','00000000-0000-0000-0000-000000000000','authenticated','authenticated','stage3b@example.test')
  on conflict (id) do nothing;
insert into public.facility_admin_credentials(facility_id,username,display_username,password_hash)
  values('30000000-0000-4000-8000-000000000001','stage3race','Stage 3 race',crypt('x',gen_salt('bf')));
insert into public.admin_sessions(user_id,username,facility_id) values
  ('30000000-0000-4000-8000-000000000011','stage3race','30000000-0000-4000-8000-000000000001'),
  ('30000000-0000-4000-8000-000000000012','stage3race','30000000-0000-4000-8000-000000000001');
insert into public.user_facility_sessions(user_id,facility_id) values
  ('30000000-0000-4000-8000-000000000011','30000000-0000-4000-8000-000000000001'),
  ('30000000-0000-4000-8000-000000000012','30000000-0000-4000-8000-000000000001');
select set_config('request.jwt.claim.sub','30000000-0000-4000-8000-000000000011',false);
insert into public.waitlist_config(facility_id,id,game_number,max_players,mode,court_count,geofence_enabled)
  values('30000000-0000-4000-8000-000000000001',true,1,24,'hybrid_waitlist',1,false);
insert into public.waitlist_courts(facility_id,court_number,game_number,team_mode)
  values('30000000-0000-4000-8000-000000000001',1,1,'rotation');
insert into public.daily_waitlist_reset_state(facility_id,id)
  values('30000000-0000-4000-8000-000000000001',true);
select 'Stage 3 config concurrency setup complete' as result;
