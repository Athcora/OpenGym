begin;
do $$
declare fid uuid:=gen_random_uuid(); actor uuid:=gen_random_uuid(); winner uuid:=gen_random_uuid(); loser uuid:=gen_random_uuid(); p uuid; i int; result jsonb; skipped_group uuid:=gen_random_uuid(); fitting_group uuid:=gen_random_uuid(); exact_gid uuid;
begin
  insert into public.facilities(id,name,slug,code) values(fid,'Local cap','local-cap-'||left(fid::text,8),left(fid::text,8));
  insert into auth.users(id,instance_id,aud,role,email) values(actor,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',actor||'@example.test');
  insert into public.facility_admin_credentials(facility_id,username,display_username,password_hash) values(fid,'admin','Admin',crypt('local-only-password',gen_salt('bf')));
  insert into public.admin_sessions(user_id,username,facility_id) values(actor,'admin',fid);
  insert into public.user_facility_sessions(user_id,facility_id) values(actor,fid);
  perform set_config('request.jwt.claim.sub',actor::text,true);
  insert into public.waitlist_config(facility_id,id,game_number,max_players,mode,court_count,geofence_enabled,hybrid_rotation_rule) values(fid,true,1,12,'hybrid_waitlist',1,false,'kotc');
  insert into public.waitlist_courts(facility_id,court_number,game_number,team_mode,team_max_wins) values(fid,1,1,'king',2);
  insert into public.daily_waitlist_reset_state(facility_id,id) values(fid,true);
  p:=gen_random_uuid(); insert into public.waitlist_players(id,facility_id,user_id,first_name,last_name,display_name,status,queue_position,court_number) values(p,fid,actor,'Reporter','','Reporter','current',1,1);
  insert into public.waitlist_players(id,facility_id,first_name,last_name,display_name,status,queue_position,court_number) values(gen_random_uuid(),fid,'Loser','','Loser','current',2,1);
  -- Side 1 takes A1/A2, skips B (five players cannot fit four remaining
  -- slots), then takes the later fitting C party. B is reconsidered first for
  -- side 2, where B+Z fill the six slots.
  for i in 1..2 loop insert into public.waitlist_players(id,facility_id,first_name,last_name,display_name,status,queue_position) values(gen_random_uuid(),fid,'A'||i,'','A'||i,'waiting',10+i); end loop;
  for i in 1..5 loop insert into public.waitlist_players(id,facility_id,first_name,last_name,display_name,status,queue_position,group_id) values(gen_random_uuid(),fid,'B'||i,'','B'||i,'waiting',12+i,skipped_group); end loop;
  for i in 1..4 loop insert into public.waitlist_players(id,facility_id,first_name,last_name,display_name,status,queue_position,group_id) values(gen_random_uuid(),fid,'C'||i,'','C'||i,'waiting',17+i,fitting_group); end loop;
  insert into public.waitlist_players(id,facility_id,first_name,last_name,display_name,status,queue_position) values(gen_random_uuid(),fid,'Z','','Z','waiting',22);
  insert into public.hybrid_kotc_court_state(facility_id,court_number,version) values(fid,1,10);
  insert into public.hybrid_kotc_teams(id,facility_id,court_number,court_side,appearance_game_number,status,consecutive_wins) values(winner,fid,1,1,1,'current',1),(loser,fid,1,2,1,'current',0);
  -- Each active side has a true six-slot structural shape before the result;
  -- slots 2–6 are explicit empty rows, not omitted rows.
  insert into public.hybrid_kotc_slots(facility_id,team_id,slot_number,player_id)
    select fid,winner,1,p
    union all select fid,loser,1,(select id from public.waitlist_players where facility_id=fid and display_name='Loser')
    union all select fid,winner,n,null from generate_series(2,6) n
    union all select fid,loser,n,null from generate_series(2,6) n;
  result:=public.advance_hybrid_kotc_game(1,'win',fid,1,10);
  if result->>'winner_stays'<>'false' or result->>'version'<>'11' then raise exception 'cap response incorrect'; end if;
  if exists(select 1 from public.hybrid_kotc_teams where id in(winner,loser) and status='current')
    or (select count(*) from public.hybrid_kotc_teams where facility_id=fid and status='current')<>2
    or exists(select 1 from public.hybrid_kotc_teams where facility_id=fid and status='current' and consecutive_wins<>0)
    or (select count(*) from public.hybrid_kotc_slots s join public.hybrid_kotc_teams t on t.id=s.team_id where t.facility_id=fid and t.status='current' and s.player_id is not null)<>12
    or exists(select 1 from public.waitlist_players where facility_id=fid and group_id in(skipped_group,fitting_group) group by group_id having bool_or(status='current') is distinct from true)
    or (select count(*) from public.hybrid_kotc_slots s join public.hybrid_kotc_teams t on t.id=s.team_id join public.waitlist_players wp on wp.id=s.player_id where t.facility_id=fid and t.status='current' and t.court_side=1 and wp.group_id=fitting_group)<>4
    or (select count(*) from public.hybrid_kotc_slots s join public.hybrid_kotc_teams t on t.id=s.team_id join public.waitlist_players wp on wp.id=s.player_id where t.facility_id=fid and t.status='current' and t.court_side=1 and wp.group_id=skipped_group)<>0
    or (select count(*) from public.hybrid_kotc_slots s join public.hybrid_kotc_teams t on t.id=s.team_id join public.waitlist_players wp on wp.id=s.player_id where t.facility_id=fid and t.status='current' and t.court_side=2 and wp.group_id=skipped_group)<>5
  then raise exception 'cap lifecycle or skipped-party successor packing wrong'; end if;

  select id into strict exact_gid from public.past_games
    where facility_id=fid and court_number=1 order by ended_at desc, id desc limit 1;
  perform public.reverse_past_game_guarded(exact_gid,fid);
  if (select version from public.hybrid_kotc_court_state where facility_id=fid and court_number=1)<>12
    or (select game_number from public.waitlist_courts where facility_id=fid and court_number=1)<>1
    or not exists(select 1 from public.hybrid_kotc_teams where id=winner and status='current' and consecutive_wins=1)
    or not exists(select 1 from public.hybrid_kotc_teams where id=loser and status='current' and consecutive_wins=0)
    or not exists(select 1 from public.hybrid_kotc_slots where team_id=winner and slot_number=1 and player_id=p)
    or (select count(*) from public.hybrid_kotc_slots where team_id=winner)<>6
    or (select count(*) from public.hybrid_kotc_slots where team_id=loser)<>6
    or (select count(*) from public.hybrid_kotc_slots where team_id=winner and slot_number between 2 and 6 and player_id is null)<>5
    or (select count(*) from public.hybrid_kotc_slots where team_id=loser and slot_number between 2 and 6 and player_id is null)<>5
    or exists(select 1 from public.waitlist_players where facility_id=fid and group_id=skipped_group and status<>'waiting')
    or exists(select 1 from public.waitlist_players where facility_id=fid and group_id=fitting_group and status<>'waiting')
    or (select max(queue_position) from public.waitlist_players where facility_id=fid and group_id=skipped_group)
       >= (select min(queue_position) from public.waitlist_players where facility_id=fid and group_id=fitting_group)
    or (select count(*) from public.waitlist_players where facility_id=fid and group_id=skipped_group)<>5
    or (select count(*) from public.waitlist_players where facility_id=fid and group_id=fitting_group)<>4
    or exists(select 1 from public.hybrid_kotc_substitutes where team_id in (winner,loser))
    or exists(select 1 from public.hybrid_kotc_slots s join public.hybrid_kotc_teams t on t.id=s.team_id where t.facility_id=fid and t.status='current' and s.player_id is not null group by s.player_id having count(*)>1)
    or exists(select 1 from public.hybrid_kotc_slots s left join public.hybrid_kotc_teams t on t.id=s.team_id where t.id is null)
    or exists(select 1 from public.hybrid_kotc_teams where facility_id=fid and id not in(winner,loser) and status='current')
    or exists(select 1 from public.past_games pg where pg.id=exact_gid)
    or exists(select 1 from public.court_game_reversals r where r.game_id=exact_gid)
  then raise exception 'cap exact Reverse did not restore PRE cap semantics'; end if;
  raise notice 'hybrid KOTC cap lifecycle + forced-off exact Reverse PASS';
end $$;
rollback;
