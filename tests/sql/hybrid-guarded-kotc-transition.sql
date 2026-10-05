-- Local-only Stage 1B core transition test. The transaction rolls back all fixtures.
begin;
do $$
declare
  fid uuid:=gen_random_uuid(); other_fid uuid:=gen_random_uuid(); actor uuid:=gen_random_uuid();
  winner uuid:=gen_random_uuid(); loser uuid:=gen_random_uuid(); court2_team uuid:=gen_random_uuid();
  p1 uuid:=gen_random_uuid(); p2 uuid:=gen_random_uuid(); p3 uuid:=gen_random_uuid(); p4 uuid:=gen_random_uuid(); p5 uuid:=gen_random_uuid(); result jsonb; grp uuid:=gen_random_uuid();
begin
  insert into public.facilities(id,name,slug,code) values
    (fid,'Local hybrid result','local-hybrid-result-'||left(fid::text,8),left(fid::text,8)),
    (other_fid,'Local hybrid result other','local-hybrid-other-'||left(other_fid::text,8),left(other_fid::text,8));
  insert into auth.users(id,instance_id,aud,role,email)
    values(actor,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',actor||'@example.test');
  insert into public.facility_admin_credentials(facility_id,username,display_username,password_hash)
    values(fid,'admin','Admin',crypt('local-only-password',gen_salt('bf')));
  insert into public.admin_sessions(user_id,username,facility_id) values(actor,'admin',fid);
  insert into public.user_facility_sessions(user_id,facility_id) values(actor,fid);
  perform set_config('request.jwt.claim.sub',actor::text,true);
  insert into public.waitlist_config(facility_id,id,game_number,max_players,mode,court_count,geofence_enabled,hybrid_rotation_rule)
    values(fid,true,1,12,'hybrid_waitlist',2,false,'kotc'),(other_fid,true,4,12,'hybrid_waitlist',1,false,'kotc');
  insert into public.waitlist_courts(facility_id,court_number,game_number,team_mode,team_max_wins) values
    (fid,1,1,'king',2),(fid,2,7,'king',null),(other_fid,1,4,'king',null);
  insert into public.daily_waitlist_reset_state(facility_id,id) values(fid,true),(other_fid,true);
  insert into public.waitlist_players(id,facility_id,user_id,first_name,last_name,display_name,status,queue_position,court_number,group_id) values
    (p1,fid,actor,'Winner','','Winner','current',1,1,grp),
    (p2,fid,null,'Loser','','Loser','current',2,1,null),
    (p3,fid,null,'CourtTwo','','CourtTwo','current',3,2,null),
    (p4,fid,null,'Incoming','','Incoming','waiting',4,null,null),
    (p5,fid,null,'Substitute','','Substitute','current',5,1,null);
  insert into public.hybrid_kotc_court_state(facility_id,court_number,version,initialized_game_number) values(fid,1,5,1),(fid,2,9,7),(other_fid,1,3,4);
  insert into public.hybrid_kotc_teams(id,facility_id,court_number,court_side,appearance_game_number,status,consecutive_wins) values
    (winner,fid,1,1,1,'current',0),(loser,fid,1,2,1,'current',0),(court2_team,fid,2,1,7,'current',4);
  insert into public.hybrid_kotc_slots(facility_id,team_id,slot_number,player_id,is_substitute) values
    (fid,winner,1,p1,false),(fid,loser,1,p2,false),(fid,loser,2,p5,true),(fid,court2_team,1,p3,false);
  set local role authenticated;
  begin
    perform public.end_hybrid_kotc_game(1,winner,5);
    raise exception 'inner hybrid transition was browser-callable';
  exception when insufficient_privilege then null;
  end;
  result:=public.advance_hybrid_kotc_game(1,'win',fid,1,5);
  reset role;
  if result->>'version'<>'6' or result->>'game_number'<>'8' or result->>'winner_stays'<>'true' then raise exception 'guarded result response wrong: %',result; end if;
  if not exists(select 1 from public.hybrid_kotc_teams where id=winner and status='current' and consecutive_wins=1) then raise exception 'winner did not remain/streak'; end if;
  if not exists(select 1 from public.hybrid_kotc_teams where id=loser and status='retired') then raise exception 'loser did not retire'; end if;
  if not exists(select 1 from public.waitlist_players where id=p2 and status='rejoin' and court_number is null and rejoin_expires_at is not null) then raise exception 'loser player did not enter return lifecycle'; end if;
  if exists(select 1 from public.hybrid_kotc_substitutes where facility_id=fid and team_id=loser and player_id=p5)
    or exists(select 1 from public.hybrid_kotc_slots s join public.hybrid_kotc_teams t on t.id=s.team_id where s.facility_id=fid and s.player_id=p5 and t.id=loser and t.status='current')
    or not exists(select 1 from public.waitlist_players where id=p5 and rejoin_expires_at is null and status in('waiting','current')) then raise exception 'substitute did not dissolve to a valid single lifecycle'; end if;
  if not exists(select 1 from public.hybrid_kotc_teams where facility_id=fid and court_number=1 and court_side=2 and status='current' and id<>loser)
    or not exists(select 1 from public.hybrid_kotc_slots s join public.hybrid_kotc_teams t on t.id=s.team_id where t.facility_id=fid and t.court_number=1 and t.court_side=2 and s.player_id=p4 and s.slot_number=1)
    or (select count(*) from public.hybrid_kotc_slots s join public.hybrid_kotc_teams t on t.id=s.team_id where t.facility_id=fid and t.court_number=1 and t.court_side=2 and s.player_id is null)<>4 then raise exception 'incoming underfilled side was not packed with explicit empties'; end if;
  if (select group_id from public.waitlist_players where id=p1) is distinct from grp then raise exception 'temporary result corrupted permanent group'; end if;
  if (select version from public.hybrid_kotc_court_state where facility_id=fid and court_number=2)<>9
    or (select game_number from public.waitlist_courts where facility_id=fid and court_number=2)<>7
    or (select version from public.hybrid_kotc_court_state where facility_id=other_fid and court_number=1)<>3 then raise exception 'result crossed court/facility boundary'; end if;
  begin
    perform public.advance_hybrid_kotc_game(1,'win',fid,1,5);
    raise exception 'stale result unexpectedly succeeded';
  exception when others then
    if position('already changed' in sqlerrm)=0 then raise; end if;
  end;
  raise notice 'guarded hybrid KOTC core transition PASS';
end $$;
rollback;
