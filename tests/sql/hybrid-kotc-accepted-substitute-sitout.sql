-- Stage 6 durable local regression: an accepted substitute is an authoritative
-- current-appearance association even before it occupies a concrete slot.
begin;
do $$
declare
  fid uuid:=gen_random_uuid(); actor uuid:=gen_random_uuid(); target_user uuid:=gen_random_uuid();
  a uuid:=gen_random_uuid(); b uuid:=gen_random_uuid(); c uuid:=gen_random_uuid(); d uuid:=gen_random_uuid();
  opponent uuid:=gen_random_uuid(); target uuid:=gen_random_uuid(); t1 uuid:=gen_random_uuid(); t2 uuid:=gen_random_uuid();
  request jsonb; accepted jsonb; satout jsonb; request_id uuid; current_game integer; current_version bigint;
begin
  insert into public.facilities(id,name,slug,code) values(fid,'Stage6 accepted substitute Sit Out','s6-sub-sit-'||left(fid::text,8),left(fid::text,8));
  insert into auth.users(id,instance_id,aud,role,email) values
    (actor,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',actor||'@example.test'),
    (target_user,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',target_user||'@example.test');
  insert into public.user_facility_sessions(user_id,facility_id) values(actor,fid),(target_user,fid);
  insert into public.facility_admin_credentials(facility_id,username,display_username,password_hash)
    values(fid,'admin','Admin',crypt('local-only-password',gen_salt('bf')));
  insert into public.admin_sessions(user_id,username,facility_id) values(actor,'admin',fid);
  perform set_config('request.jwt.claim.sub',actor::text,true);
  insert into public.waitlist_config(facility_id,id,game_number,max_players,mode,court_count,geofence_enabled,hybrid_rotation_rule)
    values(fid,true,1,24,'hybrid_waitlist',2,false,'kotc');
  insert into public.waitlist_courts(facility_id,court_number,game_number,team_mode) values(fid,1,1,'king'),(fid,2,7,'king');
  insert into public.daily_waitlist_reset_state(facility_id,id) values(fid,true);
  insert into public.hybrid_kotc_court_state(facility_id,court_number,version,initialized_game_number) values(fid,1,10,1),(fid,2,70,7);
  insert into public.waitlist_players(id,facility_id,user_id,first_name,last_name,display_name,status,queue_position,court_number) values
    (a,fid,actor,'A','','A','current',1,1),(b,fid,null,'B','','B','current',2,1),
    (c,fid,null,'C','','C','current',3,1),(d,fid,null,'D','','D','current',4,1),
    (opponent,fid,null,'Opponent','','Opponent','current',5,1),
    (target,fid,target_user,'Target','','Target','waiting',20,null);
  insert into public.hybrid_kotc_teams(id,facility_id,court_number,court_side,appearance_game_number,status)
    values(t1,fid,1,1,1,'current'),(t2,fid,1,2,1,'current');
  insert into public.hybrid_kotc_slots(facility_id,team_id,slot_number,player_id,is_substitute) values
    (fid,t1,1,a,false),(fid,t1,2,b,false),(fid,t1,3,c,false),(fid,t1,4,d,false),(fid,t1,5,null,false),(fid,t1,6,null,false),
    (fid,t2,1,opponent,false),(fid,t2,2,null,false),(fid,t2,3,null,false),(fid,t2,4,null,false),(fid,t2,5,null,false),(fid,t2,6,null,false);

  request:=public.request_hybrid_kotc_substitute(1,t1,target,fid,1,10);
  request_id:=(request->>'request_id')::uuid;
  perform set_config('request.jwt.claim.sub',target_user::text,true);
  accepted:=public.answer_hybrid_kotc_substitute(request_id,true);
  if accepted->>'version'<>'11' or not exists(select 1 from public.hybrid_kotc_substitutes where facility_id=fid and team_id=t1 and player_id=target)
    or (select status from public.waitlist_players where id=target)<>'waiting'
    or exists(select 1 from public.hybrid_kotc_slots where facility_id=fid and team_id=t1 and player_id=target) then
    raise exception 'accepted-substitute setup was not authoritative: %',accepted;
  end if;

  select game_number into current_game from public.waitlist_courts where facility_id=fid and court_number=1;
  select version into current_version from public.hybrid_kotc_court_state where facility_id=fid and court_number=1;
  satout:=public.sit_out_hybrid_kotc_player(1,target,fid,current_game,current_version);
  if satout->>'version'<>'12' or satout->>'substitute_cleared'<>'true' or satout->>'slot_cleared'<>'false'
    or (select status from public.waitlist_players where id=target)<>'sitout'
    or not (select sitout_priority from public.waitlist_players where id=target)
    or exists(select 1 from public.hybrid_kotc_substitutes where facility_id=fid and player_id=target)
    or exists(select 1 from public.hybrid_kotc_slots where facility_id=fid and player_id=target)
    or (select count(*) from public.hybrid_kotc_slots where facility_id=fid and team_id=t1)<>6
    or (select count(*) from public.hybrid_kotc_slots where facility_id=fid and team_id=t1 and player_id is null)<>2
    or (select version from public.hybrid_kotc_court_state where facility_id=fid and court_number=1)<>12
    or (select version from public.hybrid_kotc_court_state where facility_id=fid and court_number=2)<>70 then
    raise exception 'accepted-substitute Sit Out did not atomically preserve hybrid invariants: %',satout;
  end if;

  begin
    perform public.sit_out_hybrid_kotc_player(1,target,fid,current_game,11);
    raise exception 'stale accepted-substitute Sit Out was accepted';
  exception when others then
    if position('changed' in lower(sqlerrm))=0 then raise; end if;
  end;
  begin
    perform public.sit_out_hybrid_kotc_player(1,target,fid,current_game,12);
    raise exception 'repeated accepted-substitute Sit Out was accepted';
  exception when others then
    if position('changed' in lower(sqlerrm))=0 and position('not active' in lower(sqlerrm))=0 then raise; end if;
  end;
  if (select version from public.hybrid_kotc_court_state where facility_id=fid and court_number=1)<>12
    or exists(select 1 from public.hybrid_kotc_substitutes where facility_id=fid and player_id=target) then
    raise exception 'rejected accepted-substitute Sit Out mutated state';
  end if;
  raise notice 'accepted-substitute guarded Sit Out lifecycle PASS';
end $$;
rollback;
