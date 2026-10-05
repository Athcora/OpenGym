-- Stage 7: a successor accepted substitute survives Reverse of the prior game.
begin;
do $$
declare fid uuid:=gen_random_uuid(); actor uuid:=gen_random_uuid(); sub_user uuid:=gen_random_uuid();
  b uuid:=gen_random_uuid(); c uuid:=gen_random_uuid(); d uuid:=gen_random_uuid(); e uuid:=gen_random_uuid(); sub uuid:=gen_random_uuid();
  t1 uuid:=gen_random_uuid(); t2 uuid:=gen_random_uuid(); gid uuid; req uuid; result jsonb;
begin
  insert into public.facilities(id,name,slug,code) values(fid,'Stage7 successor substitute','s7-sub-'||left(fid::text,8),left(fid::text,8));
  insert into auth.users(id,instance_id,aud,role,email) values
    (actor,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',actor||'@example.test'),
    (sub_user,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',sub_user||'@example.test');
  insert into public.user_facility_sessions(user_id,facility_id) values(actor,fid),(sub_user,fid);
  insert into public.facility_admin_credentials(facility_id,username,display_username,password_hash) values(fid,'admin','Admin',crypt('local-only-password',gen_salt('bf')));
  insert into public.admin_sessions(user_id,username,facility_id) values(actor,'admin',fid);
  perform set_config('request.jwt.claim.sub',actor::text,true);
  insert into public.waitlist_config(facility_id,id,game_number,max_players,mode,court_count,geofence_enabled,hybrid_rotation_rule) values(fid,true,1,24,'hybrid_waitlist',1,false,'kotc');
  insert into public.waitlist_courts(facility_id,court_number,game_number,team_mode) values(fid,1,1,'king');
  insert into public.daily_waitlist_reset_state(facility_id,id) values(fid,true);
  insert into public.hybrid_kotc_court_state(facility_id,court_number,version,initialized_game_number) values(fid,1,10,1);
  insert into public.waitlist_players(id,facility_id,user_id,first_name,last_name,display_name,status,queue_position,court_number) values
    (b,fid,actor,'B','','B','current',1,1),(c,fid,null,'C','','C','current',2,1),(d,fid,null,'D','','D','current',3,1),(e,fid,null,'E','','E','current',4,1),(sub,fid,sub_user,'S','','S','waiting',100,null);
  insert into public.waitlist_players(id,facility_id,first_name,last_name,display_name,status,queue_position) select gen_random_uuid(),fid,'Q'||n,'','Q'||n,'waiting',30+n from generate_series(1,12)n;
  insert into public.hybrid_kotc_teams(id,facility_id,court_number,court_side,appearance_game_number,status) values(t1,fid,1,1,1,'current'),(t2,fid,1,2,1,'current');
  insert into public.hybrid_kotc_slots(facility_id,team_id,slot_number,player_id,is_substitute) values
    (fid,t1,1,b,false),(fid,t1,2,c,false),(fid,t1,3,null,false),(fid,t1,4,null,false),(fid,t1,5,null,false),(fid,t1,6,null,false),
    (fid,t2,1,d,false),(fid,t2,2,e,false),(fid,t2,3,null,false),(fid,t2,4,null,false),(fid,t2,5,null,false),(fid,t2,6,null,false);
  result:=public.advance_hybrid_kotc_game(1,'win',fid,1,10);
  if result->>'version'<>'11' or not exists(select 1 from public.hybrid_kotc_teams where id=t1 and status='current') then raise exception 'no successor'; end if;
  select r.game_id into strict gid from public.court_game_reversals r join public.past_games g on g.id=r.game_id where r.facility_id=fid and g.court_number=1 order by g.ended_at desc limit 1;
  result:=public.request_hybrid_kotc_substitute(1,t1,sub,fid,2,11); req:=(result->>'request_id')::uuid;
  perform set_config('request.jwt.claim.sub',sub_user::text,true); result:=public.answer_hybrid_kotc_substitute(req,true);
  if result->>'version'<>'12' or not exists(select 1 from public.hybrid_kotc_substitutes where team_id=t1 and player_id=sub) then raise exception 'successor substitute acceptance failed: %',result; end if;
  perform set_config('request.jwt.claim.sub',actor::text,true); perform public.reverse_past_game_guarded(gid,fid);
  if (select version from public.hybrid_kotc_court_state where facility_id=fid and court_number=1)<>13
    or not exists(select 1 from public.hybrid_kotc_substitutes where team_id=t1 and player_id=sub)
    or exists(select 1 from public.hybrid_kotc_slots where player_id=sub)
    or (select count(*) from public.hybrid_kotc_slots where team_id=t1)<>6
    or exists(select 1 from public.hybrid_kotc_substitutes hs left join public.hybrid_kotc_teams ht on ht.id=hs.team_id where ht.id is null or ht.status<>'current')
    or exists(select 1 from public.past_games where id=gid) or exists(select 1 from public.court_game_reversals where game_id=gid)
  then raise exception 'successor substitute did not survive exact Reverse'; end if;
  raise notice 'successor substitute survives public exact Reverse: 10 -> 11 -> 12 -> 13';
end $$;
rollback;
