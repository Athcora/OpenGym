-- Local-only first-game bootstrap matrix. It preserves the current roster of
-- each court, retains permanent groups, creates two six-slot sides per court,
-- and rejects a duplicate start without changing the completed board.
begin;
do $$
declare
  fid uuid:='78666666-6666-4666-8666-666666666661';
  actor uuid:='78666666-6666-4666-8666-666666666662';
  group_one uuid:='78666666-6666-4666-8666-666666666690';
  group_two uuid:='78666666-6666-4666-8666-666666666691';
  result jsonb; before_retry jsonb; after_retry jsonb;
begin
  delete from public.facilities where id=fid;
  delete from auth.users where id=actor;
  insert into public.facilities(id,name,slug,code) values(fid,'Local KOTC bootstrap','local-kotc-bootstrap','LKB');
  insert into auth.users(id,instance_id,aud,role,email) values(actor,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','bootstrap-admin@example.test');
  insert into public.user_facility_sessions(user_id,facility_id) values(actor,fid);
  insert into public.facility_admin_credentials(facility_id,username,display_username,password_hash) values(fid,'admin','Admin',crypt('local',gen_salt('bf')));
  insert into public.admin_sessions(user_id,username,facility_id) values(actor,'admin',fid);
  perform set_config('request.jwt.claim.sub',actor::text,true);
  insert into public.waitlist_config(facility_id,id,game_number,max_players,mode,court_count,geofence_enabled,hybrid_rotation_rule)
    values(fid,true,7,24,'hybrid_waitlist',2,false,'kotc');
  insert into public.waitlist_courts(facility_id,court_number,game_number,team_mode) values(fid,1,7,'king'),(fid,2,9,'king');
  insert into public.daily_waitlist_reset_state(facility_id,id) values(fid,true);
  insert into public.waitlist_players(id,facility_id,user_id,first_name,last_name,display_name,status,queue_position,court_number,group_id) values
    ('78666666-6666-4666-8666-666666666663',fid,actor,'A','','A','current',1,1,group_one),
    ('78666666-6666-4666-8666-666666666664',fid,null,'B','','B','current',2,1,group_one),
    ('78666666-6666-4666-8666-666666666665',fid,null,'C','','C','current',3,1,null),
    ('78666666-6666-4666-8666-666666666666',fid,null,'D','','D','current',4,1,null),
    ('78666666-6666-4666-8666-666666666667',fid,null,'E','','E','current',5,2,group_two),
    ('78666666-6666-4666-8666-666666666668',fid,null,'F','','F','current',6,2,group_two),
    ('78666666-6666-4666-8666-666666666669',fid,null,'G','','G','current',7,2,null),
    ('78666666-6666-4666-8666-666666666670',fid,null,'W','','W','waiting',8,null,null);
  result:=public.bootstrap_hybrid_kotc_games(fid);
  if result->>'message'<>'Waitlist KOTC games started.' then raise exception 'bootstrap did not return success: %',result; end if;
  if (select count(*) from public.hybrid_kotc_teams where facility_id=fid and status='current')<>4 then raise exception 'expected two initial sides on both courts'; end if;
  if exists(select 1 from public.hybrid_kotc_teams t where t.facility_id=fid and (select count(*) from public.hybrid_kotc_slots s where s.facility_id=fid and s.team_id=t.id)<>6) then raise exception 'initial sides do not have six explicit slots'; end if;
  if exists(select 1 from public.waitlist_players p where p.facility_id=fid and p.status='current' and p.court_number not in(1,2)) then raise exception 'bootstrap moved a current player to another court'; end if;
  if exists(select 1 from public.waitlist_players p where p.facility_id=fid and p.group_id in(group_one,group_two) group by p.group_id having count(distinct p.court_number)<>1) then raise exception 'bootstrap split a permanent group'; end if;
  if (select status from public.waitlist_players where id='78666666-6666-4666-8666-666666666670')<>'waiting' then raise exception 'bootstrap consumed waiting player despite current court roster'; end if;
  if exists(select 1 from public.hybrid_kotc_court_state where facility_id=fid and (initialized_game_number is null or version<>1)) then raise exception 'initial state/version missing'; end if;
  select public.capture_hybrid_kotc_state() into before_retry;
  begin
    perform public.bootstrap_hybrid_kotc_games(fid);
    raise exception 'duplicate bootstrap was accepted';
  exception when others then
    if position('already started' in lower(sqlerrm))=0 then raise; end if;
  end;
  select public.capture_hybrid_kotc_state() into after_retry;
  if before_retry is distinct from after_retry then raise exception 'rejected duplicate bootstrap changed the board'; end if;
  raise notice 'hybrid KOTC first-game bootstrap PASS';
end $$;
rollback;
