-- Local Stage 5 result identification contract.  Each fixture is rolled back.
begin;
do $$
declare
  fid uuid:=gen_random_uuid(); other_fid uuid:=gen_random_uuid(); actor uuid:=gen_random_uuid();
  reporter uuid:=gen_random_uuid(); mate uuid:=gen_random_uuid(); opponent_a uuid:=gen_random_uuid(); opponent_b uuid:=gen_random_uuid();
  waiting uuid:=gen_random_uuid(); other_court uuid:=gen_random_uuid(); left_player uuid:=gen_random_uuid(); sitout uuid:=gen_random_uuid(); other_facility_player uuid:=gen_random_uuid();
  reporter_group uuid:=gen_random_uuid(); opponent_group uuid:=gen_random_uuid(); pre jsonb; result jsonb; reversal_game_id uuid; before_teams integer; before_slots integer;
begin
  insert into public.facilities(id,name,slug,code) values
    (fid,'Stage 5 unknown','stage5-unknown-'||left(fid::text,8),left(fid::text,8)),
    (other_fid,'Stage 5 other','stage5-other-'||left(other_fid::text,8),left(other_fid::text,8));
  insert into auth.users(id,instance_id,aud,role,email) values
    (actor,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',actor||'@example.test');
  insert into public.facility_admin_credentials(facility_id,username,display_username,password_hash)
    values(fid,'stage5admin','Stage 5 admin',crypt('local-only-password',gen_salt('bf')));
  insert into public.admin_sessions(user_id,username,facility_id) values(actor,'stage5admin',fid);
  insert into public.user_facility_sessions(user_id,facility_id) values(actor,fid);
  perform set_config('request.jwt.claim.sub',actor::text,true);
  insert into public.waitlist_config(facility_id,id,game_number,max_players,mode,court_count,geofence_enabled,hybrid_rotation_rule)
    values(fid,true,1,24,'hybrid_waitlist',2,false,'kotc'),(other_fid,true,1,12,'hybrid_waitlist',1,false,'kotc');
  insert into public.waitlist_courts(facility_id,court_number,game_number,team_mode,team_max_wins) values
    (fid,1,1,'king',null),(fid,2,1,'king',null),(other_fid,1,1,'king',null);
  insert into public.daily_waitlist_reset_state(facility_id,id) values(fid,true),(other_fid,true);
  insert into public.hybrid_kotc_court_state(facility_id,court_number,version,initialized_game_number) values(fid,1,10,1),(fid,2,17,1),(other_fid,1,3,1);
  insert into public.waitlist_players(id,facility_id,user_id,first_name,last_name,display_name,status,queue_position,court_number,group_id) values
    (reporter,fid,actor,'Reporter','','Reporter','current',1,1,reporter_group),
    (mate,fid,null,'Mate','','Mate','current',2,1,reporter_group),
    (opponent_a,fid,null,'Opponent A','','Opponent A','current',3,1,opponent_group),
    (opponent_b,fid,null,'Opponent B','','Opponent B','current',4,1,opponent_group),
    (waiting,fid,null,'Waiting','','Waiting','waiting',5,null,null),
    (other_court,fid,null,'Other court','','Other court','current',6,2,null),
    (left_player,fid,null,'Left','','Left','left',7,null,null),
    (sitout,fid,null,'Sitout','','Sitout','sitout',8,null,null),
    (other_facility_player,other_fid,null,'Other facility','','Other facility','current',1,1,null);

  -- The normal public path returns selection-required, but creates nothing:
  -- this is the Back/Cancel zero-mutation boundary.
  select count(*) into before_teams from public.hybrid_kotc_teams where facility_id=fid;
  select count(*) into before_slots from public.hybrid_kotc_slots where facility_id=fid;
  pre:=public.advance_hybrid_kotc_game(1,'win',fid,1,10);
  if pre->>'selection_required'<>'true' or pre->>'reporter_player_id'<>reporter::text
    or pre->'locked_player_ids'<>jsonb_build_array(reporter,mate)
    or pre->'candidate_player_ids'<>jsonb_build_array(reporter,mate,opponent_a,opponent_b)
    or (select count(*) from public.hybrid_kotc_teams where facility_id=fid)<>before_teams
    or (select count(*) from public.hybrid_kotc_slots where facility_id=fid)<>before_slots
    or (select game_number from public.waitlist_courts where facility_id=fid and court_number=1)<>1
    or (select version from public.hybrid_kotc_court_state where facility_id=fid and court_number=1)<>10
  then raise exception 'selection preflight/back mutated state or leaked candidates: %',pre; end if;

  -- Reporter and permanent party cannot be partially selected; foreign, waiting,
  -- other-court, left, and sit-out ids are rejected before a team exists.
  begin perform public.confirm_hybrid_kotc_unknown_result(1,'win',fid,1,10,array[reporter]); raise exception 'partial reporter group accepted';
  exception when others then if position('groups must be selected together' in sqlerrm)=0 then raise; end if; end;
  begin perform public.confirm_hybrid_kotc_unknown_result(1,'win',fid,1,10,array[opponent_a,opponent_b]); raise exception 'caller spoofed a different reporter side';
  exception when others then if position('Selected teammates' in sqlerrm)=0 then raise; end if; end;
  begin perform public.confirm_hybrid_kotc_unknown_result(1,'win',fid,1,10,array[reporter,mate,waiting]); raise exception 'waiting candidate accepted';
  exception when others then if position('Selected teammates' in sqlerrm)=0 then raise; end if; end;
  begin perform public.confirm_hybrid_kotc_unknown_result(1,'win',fid,1,10,array[reporter,mate,other_court]); raise exception 'other-court candidate accepted';
  exception when others then if position('Selected teammates' in sqlerrm)=0 then raise; end if; end;
  begin perform public.confirm_hybrid_kotc_unknown_result(1,'win',fid,1,10,array[reporter,mate,left_player]); raise exception 'left candidate accepted';
  exception when others then if position('Selected teammates' in sqlerrm)=0 then raise; end if; end;
  begin perform public.confirm_hybrid_kotc_unknown_result(1,'win',fid,1,10,array[reporter,mate,sitout]); raise exception 'sit-out candidate accepted';
  exception when others then if position('Selected teammates' in sqlerrm)=0 then raise; end if; end;
  begin perform public.confirm_hybrid_kotc_unknown_result(1,'win',other_fid,1,10,array[reporter,mate]); raise exception 'cross-facility confirmation accepted';
  exception when others then if position('facility' in lower(sqlerrm))=0 then raise; end if; end;
  if (select count(*) from public.hybrid_kotc_teams where facility_id=fid)<>0 then raise exception 'failed confirmation left a temporary team'; end if;

  -- Confirm an underfilled two-player reporter side. Remaining current players
  -- become the opposing unknown side; Stage 1B then records the Win and rotates.
  result:=public.confirm_hybrid_kotc_unknown_result(1,'win',fid,1,10,array[reporter,mate]);
  if result->>'identified_unknown_side'<>'true' or result->>'version'<>'11' or result->>'game_number'<>'2'
    or not exists(select 1 from public.hybrid_kotc_teams t join public.hybrid_kotc_slots s on s.facility_id=t.facility_id and s.team_id=t.id where t.facility_id=fid and t.court_number=1 and t.status='current' and s.player_id=reporter and t.consecutive_wins=1)
    or (select group_id from public.waitlist_players where id=reporter) is distinct from reporter_group
    or (select group_id from public.waitlist_players where id=mate) is distinct from reporter_group
    or (select count(*) from public.hybrid_kotc_slots s join public.hybrid_kotc_teams t on t.id=s.team_id and t.facility_id=s.facility_id where t.facility_id=fid and t.court_number=1 and t.status='retired' and s.player_id is null)<>4
  then raise exception 'underfilled identification/result did not preserve Stage 1B behavior: %',result; end if;
  select id into strict reversal_game_id from public.past_games where facility_id=fid and court_number=1 order by game_number desc,id desc limit 1;
  if not exists(select 1 from public.court_game_reversals r where r.facility_id=fid and r.game_id=reversal_game_id)
    or (select r.before_state->'hybrid_kotc_teams' from public.court_game_reversals r where r.game_id=reversal_game_id) <> '[]'::jsonb then
    raise exception 'unknown-side exact Reverse did not retain the pre-identification state'; end if;
  if (public.read_hybrid_kotc_board()#>>'{courts,0,teams,0,consecutive_wins}')<>'1' then raise exception 'Stage 4 board did not expose identified streak'; end if;
  perform public.reverse_past_game_guarded(reversal_game_id,fid);
  if exists(select 1 from public.hybrid_kotc_teams where facility_id=fid and court_number=1)
    or (select version from public.hybrid_kotc_court_state where facility_id=fid and court_number=1)<>12
    or (select game_number from public.waitlist_courts where facility_id=fid and court_number=1)<>1
    or not exists(select 1 from public.waitlist_players where id=reporter and status='current' and court_number=1)
  then raise exception 'Reverse did not restore unknown pre-confirm state'; end if;

  -- A stale game or version confirmation must not materialize slots/teams.
  update public.waitlist_courts set game_number=2 where facility_id=fid and court_number=1;
  begin perform public.confirm_hybrid_kotc_unknown_result(1,'lose',fid,1,10,array[reporter,mate]); raise exception 'stale game confirmation succeeded';
  exception when others then if position('already changed' in lower(sqlerrm))=0 then raise; end if; end;
  update public.waitlist_courts set game_number=1 where facility_id=fid and court_number=1;
  update public.hybrid_kotc_court_state set version=20 where facility_id=fid and court_number=1;
  begin perform public.confirm_hybrid_kotc_unknown_result(1,'lose',fid,1,10,array[reporter,mate]); raise exception 'stale confirmation succeeded';
  exception when others then if position('changed' in lower(sqlerrm))=0 then raise; end if; end;
  if exists(select 1 from public.hybrid_kotc_teams where facility_id=fid and court_number=1) then raise exception 'stale confirmation created a side'; end if;
end $$;
rollback;
