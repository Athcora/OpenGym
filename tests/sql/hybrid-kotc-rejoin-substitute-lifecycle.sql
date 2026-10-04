-- Local-only: an original KOTC group returns as a queue unit; substitute
-- players return behind it and never obtain a phantom current assignment.
begin;
do $$
declare fid uuid:=gen_random_uuid(); actor uuid:=gen_random_uuid(); p1 uuid:=gen_random_uuid(); p2 uuid:=gen_random_uuid(); sub uuid:=gen_random_uuid(); opp uuid:=gen_random_uuid(); a uuid:=gen_random_uuid(); b uuid:=gen_random_uuid(); gid uuid:=gen_random_uuid(); prompt uuid; result jsonb;
begin
  insert into public.facilities(id,name,slug,code) values(fid,'Local hybrid lifecycle','local-hybrid-life-'||left(fid::text,8),left(fid::text,8));
  insert into auth.users(id,instance_id,aud,role,email) values(actor,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',actor||'@example.test');
  insert into public.facility_admin_credentials(facility_id,username,display_username,password_hash) values(fid,'admin','Admin',crypt('local-only-password',gen_salt('bf')));
  insert into public.admin_sessions(user_id,username,facility_id) values(actor,'admin',fid);
  insert into public.user_facility_sessions(user_id,facility_id) values(actor,fid);
  perform set_config('request.jwt.claim.sub',actor::text,true);
  insert into public.waitlist_config(facility_id,id,game_number,max_players,mode,court_count,geofence_enabled,hybrid_rotation_rule) values(fid,true,1,12,'hybrid_waitlist',1,false,'kotc');
  insert into public.waitlist_courts(facility_id,court_number,game_number,team_mode,team_max_wins,hybrid_rotation_rule) values(fid,1,1,'king',3,'kotc');
  insert into public.hybrid_kotc_court_state(facility_id,court_number,version) values(fid,1,9);
  insert into public.daily_waitlist_reset_state(facility_id,id) values(fid,true);
  insert into public.waitlist_players(id,facility_id,user_id,first_name,last_name,display_name,status,queue_position,court_number,group_id) values
    (p1,fid,actor,'One','','One','current',1,1,gid),(p2,fid,null,'Two','','Two','current',2,1,gid),
    (sub,fid,null,'Sub','','Sub','current',3,1,null),(opp,fid,null,'Opp','','Opp','current',4,1,null);
  insert into public.hybrid_kotc_teams(id,facility_id,court_number,court_side,appearance_game_number,status) values(a,fid,1,1,1,'current'),(b,fid,1,2,1,'current');
  insert into public.hybrid_kotc_slots(facility_id,team_id,slot_number,player_id,is_substitute) values(fid,a,1,p1,false),(fid,a,2,p2,false),(fid,a,3,sub,true),(fid,b,1,opp,false);
  insert into public.hybrid_kotc_substitutes(facility_id,team_id,player_id) values(fid,a,sub);
  result:=public.advance_hybrid_kotc_game(1,'lose',fid,1,9);
  select id into prompt from public.rejoin_responses where facility_id=fid and user_id=actor and choice is null;
  if prompt is null or (select status from public.waitlist_players where id=p1)<>'rejoin'
    or (select rejoin_expires_at from public.waitlist_players where id=sub) is not null
    or exists(select 1 from public.hybrid_kotc_slots s join public.hybrid_kotc_teams t on t.id=s.team_id where s.facility_id=fid and s.player_id=sub and t.id=a and t.status='current')
    then raise exception 'return states were not separated'; end if;
  if (select queue_position from public.waitlist_players where id=sub)<=(select queue_position from public.waitlist_players where id=p1) then raise exception 'substitute did not return behind original block'; end if;
  perform public.answer_rejoin_prompt(prompt,'stay');
  if (select status from public.waitlist_players where id=p1)<>'waiting' or (select court_number from public.waitlist_players where id=p1) is not null
    or exists(select 1 from public.hybrid_kotc_slots s join public.hybrid_kotc_teams t on t.id=s.team_id where s.facility_id=fid and s.player_id=p1 and t.status='current') then raise exception 'hybrid rejoin created an invalid active assignment'; end if;
  if (select group_id from public.waitlist_players where id=p1) is distinct from (select group_id from public.waitlist_players where id=p2) then raise exception 'original permanent group relationship changed'; end if;
  raise notice 'hybrid KOTC rejoin/substitute lifecycle PASS';
end $$;
rollback;
