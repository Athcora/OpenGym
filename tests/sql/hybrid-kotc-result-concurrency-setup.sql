do $$
declare fid uuid:=gen_random_uuid(); actor uuid:=gen_random_uuid(); winner uuid:=gen_random_uuid(); loser uuid:=gen_random_uuid(); reporter uuid:=gen_random_uuid(); i int;
begin
  insert into public.facilities(id,name,slug,code) values(fid,'Local hybrid result concurrency','local-hybrid-result-concurrency','LHRC');
  insert into auth.users(id,instance_id,aud,role,email) values(actor,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',actor||'@example.test');
  insert into public.user_facility_sessions(user_id,facility_id) values(actor,fid);
  perform set_config('request.jwt.claim.sub',actor::text,true);
  insert into public.waitlist_config(facility_id,id,game_number,max_players,mode,court_count,geofence_enabled,hybrid_rotation_rule) values(fid,true,1,12,'hybrid_waitlist',1,false,'kotc');
  insert into public.waitlist_courts(facility_id,court_number,game_number,team_mode) values(fid,1,1,'king'); insert into public.daily_waitlist_reset_state(facility_id,id) values(fid,true);
  insert into public.waitlist_players(id,facility_id,user_id,first_name,last_name,display_name,status,queue_position,court_number) values(reporter,fid,actor,'Reporter','','Reporter','current',1,1);
  insert into public.waitlist_players(id,facility_id,first_name,last_name,display_name,status,queue_position,court_number) values(gen_random_uuid(),fid,'Loser','','Loser','current',2,1);
  for i in 1..6 loop insert into public.waitlist_players(id,facility_id,first_name,last_name,display_name,status,queue_position) values(gen_random_uuid(),fid,'Waiting'||i,'','Waiting'||i,'waiting',10+i); end loop;
  insert into public.hybrid_kotc_court_state(facility_id,court_number,version) values(fid,1,40);
  insert into public.hybrid_kotc_teams(id,facility_id,court_number,court_side,appearance_game_number,status) values(winner,fid,1,1,1,'current'),(loser,fid,1,2,1,'current');
  insert into public.hybrid_kotc_slots(facility_id,team_id,slot_number,player_id) select fid,winner,1,reporter union all select fid,loser,1,(select id from public.waitlist_players where facility_id=fid and display_name='Loser');
end $$;
create or replace function public.local_hybrid_result_pause() returns trigger language plpgsql as $$ begin perform pg_sleep(3); return new; end $$;
create trigger local_hybrid_result_pause before insert on public.past_games for each row execute function public.local_hybrid_result_pause();
