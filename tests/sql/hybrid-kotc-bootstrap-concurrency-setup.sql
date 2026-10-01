drop trigger if exists local_hybrid_kotc_bootstrap_pause on public.hybrid_kotc_teams;
drop function if exists public.local_hybrid_kotc_bootstrap_pause();
delete from public.facilities where slug='local-kotc-bootstrap-race';
delete from auth.users where email in ('bootstrap-race@example.test');
do $$
declare fid uuid:='79666666-6666-4666-8666-666666666661'; actor uuid:='79666666-6666-4666-8666-666666666662'; i integer;
begin
  insert into public.facilities(id,name,slug,code) values(fid,'Local KOTC bootstrap race','local-kotc-bootstrap-race','LKBR');
  insert into auth.users(id,instance_id,aud,role,email) values(actor,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','bootstrap-race@example.test');
  insert into public.user_facility_sessions(user_id,facility_id) values(actor,fid);
  insert into public.facility_admin_credentials(facility_id,username,display_username,password_hash) values(fid,'admin','Admin',crypt('local',gen_salt('bf')));
  insert into public.admin_sessions(user_id,username,facility_id) values(actor,'admin',fid);
  insert into public.waitlist_config(facility_id,id,game_number,max_players,mode,court_count,geofence_enabled,hybrid_rotation_rule) values(fid,true,1,12,'hybrid_waitlist',1,false,'kotc');
  insert into public.waitlist_courts(facility_id,court_number,game_number,team_mode) values(fid,1,1,'king');
  insert into public.daily_waitlist_reset_state(facility_id,id) values(fid,true);
  perform set_config('request.jwt.claim.sub',actor::text,true);
  insert into public.waitlist_players(id,facility_id,user_id,first_name,last_name,display_name,status,queue_position,court_number) values(gen_random_uuid(),fid,actor,'P1','','P1','current',1,1);
  insert into public.waitlist_players(id,facility_id,first_name,last_name,display_name,status,queue_position,court_number) values(gen_random_uuid(),fid,'P2','','P2','current',2,1);
end $$;
create or replace function public.local_hybrid_kotc_bootstrap_pause() returns trigger language plpgsql as $$ begin perform pg_sleep(3); return new; end $$;
create trigger local_hybrid_kotc_bootstrap_pause before insert on public.hybrid_kotc_teams for each row execute function public.local_hybrid_kotc_bootstrap_pause();
