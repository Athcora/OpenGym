begin;
do $$
declare fid uuid:=gen_random_uuid(); other_fid uuid:=gen_random_uuid(); actor uuid:=gen_random_uuid(); team uuid:=gen_random_uuid(); player uuid:=gen_random_uuid(); round_id bigint; past_id uuid:=gen_random_uuid();
begin
  insert into public.facilities(id,name,slug,code) values(fid,'Reverse king','reverse-king-'||left(fid::text,8),left(fid::text,8)),(other_fid,'Other king','other-king-'||left(other_fid::text,8),left(other_fid::text,8));
  insert into auth.users(id,instance_id,aud,role,email) values(actor,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',actor||'@example.test');
  insert into public.facility_admin_credentials(facility_id,username,display_username,password_hash) values(fid,'reverseadmin','Reverse admin',crypt('x',gen_salt('bf')));
  insert into public.admin_sessions(user_id,username,facility_id) values(actor,'reverseadmin',fid); insert into public.user_facility_sessions(user_id,facility_id) values(actor,fid);
  perform set_config('request.jwt.claim.sub',actor::text,true);
  insert into public.waitlist_config(facility_id,id,game_number) values(fid,true,2),(other_fid,true,9);
  insert into public.waitlist_courts(facility_id,court_number,game_number) values(fid,1,2),(other_fid,1,9);
  insert into public.waitlist_players(id,facility_id,first_name,last_name,display_name,status,queue_position) values(player,fid,'Player','','Player','waiting',1);
  insert into public.king_teams(id,facility_id,name,status,queue_position,consecutive_wins) values(team,fid,'after','waiting',9,4);
  insert into public.past_games(id,facility_id,game_number,court_number,player_names,reversible) values(past_id,fid,2,1,'[]',true);
  insert into public.king_round_history(facility_id,court_number,game_number,winning_team_id,winning_team_name,losing_team_name,actor_user_id,snapshot) values
    (fid,1,2,team,'after','loser',actor,jsonb_build_object('teams',jsonb_build_array(jsonb_build_object('id',team,'name','before','status','current','queue_position',1,'court_number',1,'court_side',1,'consecutive_wins',1,'created_at',now())),'players',jsonb_build_array(jsonb_build_object('id',player,'status','current','court_number',1,'team_id',team)),'court',jsonb_build_object('game_number',1,'started_at',to_jsonb(now())),'config_game_number',1)) returning id into round_id;
  perform public.reverse_king_game();
  if not exists(select 1 from public.king_teams where id=team and facility_id=fid and name='before' and status='current' and court_number=1)
    or not exists(select 1 from public.waitlist_players where id=player and facility_id=fid and status='current' and court_number=1 and team_id=team)
    or exists(select 1 from public.past_games where id=past_id) or not exists(select 1 from public.king_round_history where id=round_id and reversed_at is not null)
    or (select game_number from public.waitlist_courts where facility_id=other_fid and court_number=1)<>9
  then raise exception 'runtime Reverse did not restore only its facility/court'; end if;
end $$;
rollback;
