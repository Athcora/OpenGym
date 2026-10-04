-- Stage 6: a guarded post-result KOTC Sit Out remains CURRENT when the exact
-- earlier game is reversed; PRE must not resurrect its old slot/association.
begin;
do $$
declare
  fid uuid:=gen_random_uuid(); actor uuid:=gen_random_uuid(); b uuid:=gen_random_uuid(); c uuid:=gen_random_uuid();
  d uuid:=gen_random_uuid(); e uuid:=gen_random_uuid(); x uuid:=gen_random_uuid(); grp uuid:=gen_random_uuid();
  t1 uuid:=gen_random_uuid(); t2 uuid:=gen_random_uuid(); c2team uuid:=gen_random_uuid(); gid uuid; result jsonb; c2_before jsonb;
begin
  insert into public.facilities(id,name,slug,code) values(fid,'Stage6 post-result Sit Out Reverse','s6-sit-rev-'||left(fid::text,8),left(fid::text,8));
  insert into auth.users(id,instance_id,aud,role,email) values(actor,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',actor||'@example.test');
  insert into public.user_facility_sessions(user_id,facility_id) values(actor,fid);
  insert into public.facility_admin_credentials(facility_id,username,display_username,password_hash) values(fid,'admin','Admin',crypt('local-only-password',gen_salt('bf')));
  insert into public.admin_sessions(user_id,username,facility_id) values(actor,'admin',fid);
  perform set_config('request.jwt.claim.sub',actor::text,true);
  insert into public.waitlist_config(facility_id,id,game_number,max_players,mode,court_count,geofence_enabled,hybrid_rotation_rule) values(fid,true,1,24,'hybrid_waitlist',2,false,'kotc');
  insert into public.waitlist_courts(facility_id,court_number,game_number,team_mode,hybrid_rotation_rule) values(fid,1,1,'king','kotc'),(fid,2,9,'king','kotc');
  insert into public.daily_waitlist_reset_state(facility_id,id) values(fid,true);
  insert into public.hybrid_kotc_court_state(facility_id,court_number,version,initialized_game_number) values(fid,1,10,1),(fid,2,90,9);
  insert into public.waitlist_players(id,facility_id,user_id,first_name,last_name,display_name,status,queue_position,court_number,group_id) values
   (b,fid,actor,'B','','B','current',1,1,grp),(c,fid,null,'C','','C','current',2,1,grp),
   (d,fid,null,'D','','D','current',3,1,null),(e,fid,null,'E','','E','current',4,1,null),(x,fid,null,'X','','X','current',5,2,null);
  insert into public.waitlist_players(id,facility_id,first_name,last_name,display_name,status,queue_position)
   select gen_random_uuid(),fid,'Q'||n,'','Q'||n,'waiting',30+n from generate_series(1,12)n;
  insert into public.hybrid_kotc_teams(id,facility_id,court_number,court_side,appearance_game_number,status) values
   (t1,fid,1,1,1,'current'),(t2,fid,1,2,1,'current'),(c2team,fid,2,1,9,'current');
  insert into public.hybrid_kotc_slots(facility_id,team_id,slot_number,player_id,original_group_id,is_substitute) values
   (fid,t1,1,b,grp,false),(fid,t1,2,c,grp,false),(fid,t1,3,null,null,false),(fid,t1,4,null,null,false),(fid,t1,5,null,null,false),(fid,t1,6,null,null,false),
   (fid,t2,1,d,null,false),(fid,t2,2,e,null,false),(fid,t2,3,null,null,false),(fid,t2,4,null,null,false),(fid,t2,5,null,null,false),(fid,t2,6,null,null,false),
   (fid,c2team,1,x,null,false),(fid,c2team,2,null,null,false),(fid,c2team,3,null,null,false),(fid,c2team,4,null,null,false),(fid,c2team,5,null,null,false),(fid,c2team,6,null,null,false);
  select jsonb_build_object('version',(select version from public.hybrid_kotc_court_state where facility_id=fid and court_number=2),'slots',(select jsonb_agg(jsonb_build_object('n',slot_number,'p',player_id) order by slot_number) from public.hybrid_kotc_slots where team_id=c2team)) into c2_before;

  result:=public.advance_hybrid_kotc_game(1,'win',fid,1,10);
  if result->>'version'<>'11' or not exists(select 1 from public.hybrid_kotc_teams where id=t1 and status='current') then raise exception 'result fixture did not create successor: %',result; end if;
  select r.game_id into strict gid from public.court_game_reversals r join public.past_games g on g.id=r.game_id where r.facility_id=fid and g.court_number=1 order by g.ended_at desc limit 1;
  result:=public.sit_out_hybrid_kotc_player(1,b,fid,(select game_number from public.waitlist_courts where facility_id=fid and court_number=1),(select version from public.hybrid_kotc_court_state where facility_id=fid and court_number=1));
  if result->>'version'<>'12' or (select status from public.waitlist_players where id=b)<>'sitout' or not (select sitout_priority from public.waitlist_players where id=b) or exists(select 1 from public.hybrid_kotc_slots where player_id=b) then raise exception 'post-result Sit Out did not commit: %',result; end if;

  perform public.reverse_past_game_guarded(gid,fid);
  if (select version from public.hybrid_kotc_court_state where facility_id=fid and court_number=1)<>13
   or (select status from public.waitlist_players where id=b)<>'sitout' or not (select sitout_priority from public.waitlist_players where id=b)
   or exists(select 1 from public.hybrid_kotc_slots s join public.hybrid_kotc_teams t on t.id=s.team_id and t.facility_id=s.facility_id where s.player_id=b and t.status='current')
   or (select group_id from public.waitlist_players where id=b) is distinct from grp
   or (select count(*) from public.hybrid_kotc_slots where team_id=t1 and slot_number=1 and player_id is null)<>1
   or exists(select 1 from public.hybrid_kotc_substitutes hs left join public.hybrid_kotc_teams ht on ht.id=hs.team_id and ht.facility_id=hs.facility_id where hs.facility_id=fid and (ht.id is null or ht.status<>'current'))
   or exists(select 1 from public.past_games where id=gid) or exists(select 1 from public.court_game_reversals where game_id=gid)
   or c2_before is distinct from jsonb_build_object('version',(select version from public.hybrid_kotc_court_state where facility_id=fid and court_number=2),'slots',(select jsonb_agg(jsonb_build_object('n',slot_number,'p',player_id) order by slot_number) from public.hybrid_kotc_slots where team_id=c2team)) then
    raise exception 'post-result Sit Out was not preserved across exact Reverse';
  end if;
  raise notice 'post-result guarded Sit Out survives public exact Reverse: 10 -> 11 -> 12 -> 13';
end $$;
rollback;
