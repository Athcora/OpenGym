-- Local-only result matrix: server-derived Lose, a three-win cap, and No Limit.
begin;
create or replace function pg_temp.reset_hybrid_kotc_result_case(
  p_facility uuid, p_reporter uuid, p_actor uuid, p_opponent uuid, p_a uuid, p_b uuid,
  p_limit integer, p_streak integer, p_version bigint
) returns void language plpgsql as $$
declare i integer;
begin
  delete from public.court_game_reversals where facility_id=p_facility; delete from public.past_games where facility_id=p_facility;
  delete from public.rejoin_responses where facility_id=p_facility; delete from public.hybrid_kotc_substitutes where facility_id=p_facility; delete from public.hybrid_kotc_slots where facility_id=p_facility; delete from public.hybrid_kotc_teams where facility_id=p_facility; delete from public.waitlist_players where facility_id=p_facility;
  update public.waitlist_config set game_number=1 where facility_id=p_facility;
  update public.waitlist_courts set game_number=1,team_max_wins=p_limit where facility_id=p_facility and court_number=1;
  update public.hybrid_kotc_court_state set version=p_version where facility_id=p_facility and court_number=1;
  insert into public.waitlist_players(id,facility_id,user_id,first_name,last_name,display_name,status,queue_position,court_number) values(p_reporter,p_facility,p_actor,'Reporter','','Reporter','current',1,1),(p_opponent,p_facility,null,'Opponent','','Opponent','current',2,1);
  for i in 1..12 loop insert into public.waitlist_players(id,facility_id,first_name,last_name,display_name,status,queue_position) values(gen_random_uuid(),p_facility,'W'||i,'','W'||i,'waiting',10+i); end loop;
  insert into public.hybrid_kotc_teams(id,facility_id,court_number,court_side,appearance_game_number,status,consecutive_wins) values(p_a,p_facility,1,1,1,'current',p_streak),(p_b,p_facility,1,2,1,'current',0);
  insert into public.hybrid_kotc_slots(facility_id,team_id,slot_number,player_id) values(p_facility,p_a,1,p_reporter),(p_facility,p_b,1,p_opponent);
end $$;
do $$
declare fid uuid:=gen_random_uuid(); actor uuid:=gen_random_uuid(); a uuid:=gen_random_uuid(); b uuid:=gen_random_uuid(); reporter uuid:=gen_random_uuid(); opponent uuid:=gen_random_uuid(); result jsonb;
begin
  insert into public.facilities(id,name,slug,code) values(fid,'Local result matrix','local-result-matrix-'||left(fid::text,8),left(fid::text,8));
  insert into auth.users(id,instance_id,aud,role,email) values(actor,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',actor||'@example.test');
  insert into public.facility_admin_credentials(facility_id,username,display_username,password_hash) values(fid,'admin','Admin',crypt('local-only-password',gen_salt('bf')));
  insert into public.admin_sessions(user_id,username,facility_id) values(actor,'admin',fid);
  insert into public.user_facility_sessions(user_id,facility_id) values(actor,fid);
  perform set_config('request.jwt.claim.sub',actor::text,true);
  insert into public.waitlist_config(facility_id,id,game_number,max_players,mode,court_count,geofence_enabled,hybrid_rotation_rule) values(fid,true,1,12,'hybrid_waitlist',1,false,'kotc');
  insert into public.waitlist_courts(facility_id,court_number,game_number,team_mode,team_max_wins,hybrid_rotation_rule) values(fid,1,1,'king',3,'kotc');
  insert into public.hybrid_kotc_court_state(facility_id,court_number,version) values(fid,1,60);
  insert into public.daily_waitlist_reset_state(facility_id,id) values(fid,true);

  -- Reporter A says Lose: server derives B as winner and retains B below cap.
  perform pg_temp.reset_hybrid_kotc_result_case(fid,reporter,actor,opponent,a,b,3,0,60);
  result:=public.advance_hybrid_kotc_game(1,'lose',fid,1,60);
  if result->>'winner_stays'<>'true' or (select consecutive_wins from public.hybrid_kotc_teams where id=b)<>1
    or exists(select 1 from public.hybrid_kotc_teams where id=a and status='current')
    or not exists(select 1 from public.waitlist_players where id=reporter and status='rejoin') then raise exception 'Lose did not derive opponent winner/return reporter'; end if;

  -- Three-win cap: 2 -> 3 forces both current appearances off, then builds two new sides at zero.
  perform pg_temp.reset_hybrid_kotc_result_case(fid,reporter,actor,opponent,a,b,3,2,61);
  result:=public.advance_hybrid_kotc_game(1,'win',fid,1,61);
  if result->>'winner_stays'<>'false' or exists(select 1 from public.hybrid_kotc_teams where id in(a,b) and status='current')
    or (select count(*) from public.hybrid_kotc_teams where facility_id=fid and status='current')<>2
    or exists(select 1 from public.hybrid_kotc_teams where facility_id=fid and status='current' and consecutive_wins<>0)
    or (select version from public.hybrid_kotc_court_state where facility_id=fid and court_number=1)<>62 then raise exception 'three-win cap lifecycle wrong'; end if;

  -- No Limit preserves the winner across sequential wins above ordinary caps.
  perform pg_temp.reset_hybrid_kotc_result_case(fid,reporter,actor,opponent,a,b,null,3,70);
  result:=public.advance_hybrid_kotc_game(1,'win',fid,1,70);
  if result->>'winner_stays'<>'true' or (select consecutive_wins from public.hybrid_kotc_teams where id=a)<>4 then raise exception 'No Limit did not retain streak 4'; end if;
  result:=public.advance_hybrid_kotc_game(1,'win',fid,2,71);
  if result->>'winner_stays'<>'true' or (select consecutive_wins from public.hybrid_kotc_teams where id=a)<>5 then raise exception 'No Limit did not retain streak 5'; end if;
  -- A later reporter loss retires the long-streak appearance; future appearances are new zero-streak rows.
  result:=public.advance_hybrid_kotc_game(1,'lose',fid,3,72);
  if exists(select 1 from public.hybrid_kotc_teams where id=a and status='current') then raise exception 'No Limit loser did not retire'; end if;
  raise notice 'hybrid KOTC Lose / three-win / No Limit matrix PASS';
end $$;
rollback;
