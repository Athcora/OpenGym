-- Local Stage 5 size/group matrix.  This is deliberately behavioral: every
-- case enters through the authenticated public unknown-side confirmation RPC.
begin;
do $$
declare
  size integer; total integer; i integer; fid uuid; actor uuid; reporter uuid;
  player_id uuid; reporter_group uuid; selected uuid[]; result jsonb;
  first_group_id uuid; selected_group uuid[]; opponent_id uuid;
begin
  -- A single reporter may identify a full six-player side (with one real
  -- opponent), while permanent reporter parties of 3/4/5 retain their exact
  -- membership and yield the corresponding explicit empty slots.
  foreach size in array array[1,3,4,5] loop
    fid:=gen_random_uuid(); actor:=gen_random_uuid(); reporter:=gen_random_uuid();
    reporter_group:=case when size=1 then null else gen_random_uuid() end;
    total:=case when size=1 then 7 else 6 end;
    insert into public.facilities(id,name,slug,code) values(fid,'Stage5 size','s5-size-'||left(fid::text,8),left(fid::text,8));
    insert into auth.users(id,instance_id,aud,role,email) values(actor,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',actor||'@example.test');
    insert into public.user_facility_sessions(user_id,facility_id) values(actor,fid);
    perform set_config('request.jwt.claim.sub',actor::text,true);
    insert into public.waitlist_config(facility_id,id,game_number,max_players,mode,court_count,geofence_enabled,hybrid_rotation_rule)
      values(fid,true,1,24,'hybrid_waitlist',1,false,'kotc');
    insert into public.waitlist_courts(facility_id,court_number,game_number,team_mode) values(fid,1,1,'king');
    insert into public.daily_waitlist_reset_state(facility_id,id) values(fid,true);
    insert into public.hybrid_kotc_court_state(facility_id,court_number,version,initialized_game_number) values(fid,1,10,1);
    selected:='{}'::uuid[];
    for i in 1..total loop
      player_id:=case when i=1 then reporter else gen_random_uuid() end;
      insert into public.waitlist_players(id,facility_id,user_id,first_name,last_name,display_name,status,queue_position,court_number,group_id)
        values(player_id,fid,case when i=1 then actor else null end,'Player '||i,'','Player '||i,'current',i,1,
          case when i<=size then reporter_group else null end);
      if i<=size then selected:=array_append(selected,player_id); end if;
    end loop;
    result:=public.confirm_hybrid_kotc_unknown_result(1,'win',fid,1,10,selected);
    if result->>'identified_unknown_side'<>'true'
      or not exists(select 1 from public.hybrid_kotc_teams t join public.hybrid_kotc_slots s on s.facility_id=t.facility_id and s.team_id=t.id
        where t.facility_id=fid and t.court_number=1 and t.status='current' and t.consecutive_wins=1 and s.player_id=reporter)
      or (select count(*) from public.hybrid_kotc_slots s join public.hybrid_kotc_teams t on t.facility_id=s.facility_id and t.id=s.team_id
        where t.facility_id=fid and t.status='current' and t.consecutive_wins=1 and s.player_id is null)<>(6-size)
      or exists(select 1 from public.waitlist_players where facility_id=fid and id=any(selected) and group_id is distinct from reporter_group)
    then raise exception 'Stage5 size matrix failed for size %, result %',size,result; end if;
  end loop;

  -- A different permanent party can join a single reporter when it fits.
  fid:=gen_random_uuid(); actor:=gen_random_uuid(); reporter:=gen_random_uuid(); first_group_id:=gen_random_uuid(); selected_group:='{}'::uuid[];
  insert into public.facilities(id,name,slug,code) values(fid,'Stage5 fitting group','s5-fit-'||left(fid::text,8),left(fid::text,8));
  insert into auth.users(id,instance_id,aud,role,email) values(actor,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',actor||'@example.test');
  insert into public.user_facility_sessions(user_id,facility_id) values(actor,fid); perform set_config('request.jwt.claim.sub',actor::text,true);
  insert into public.waitlist_config(facility_id,id,game_number,max_players,mode,court_count,geofence_enabled,hybrid_rotation_rule) values(fid,true,1,24,'hybrid_waitlist',1,false,'kotc');
  insert into public.waitlist_courts(facility_id,court_number,game_number,team_mode) values(fid,1,1,'king');
  insert into public.daily_waitlist_reset_state(facility_id,id) values(fid,true);
  insert into public.hybrid_kotc_court_state(facility_id,court_number,version,initialized_game_number) values(fid,1,10,1);
  insert into public.waitlist_players(id,facility_id,user_id,first_name,last_name,display_name,status,queue_position,court_number)
    values(reporter,fid,actor,'Reporter','','Reporter','current',1,1);
  selected_group:=array_append(selected_group,reporter);
  for i in 2..6 loop
    player_id:=gen_random_uuid();
    insert into public.waitlist_players(id,facility_id,first_name,last_name,display_name,status,queue_position,court_number,group_id)
      values(player_id,fid,'Player '||i,'','Player '||i,'current',i,1,case when i in(2,3) then first_group_id else null end);
    if i in(2,3) then selected_group:=array_append(selected_group,player_id); end if;
  end loop;
  result:=public.confirm_hybrid_kotc_unknown_result(1,'lose',fid,1,10,selected_group);
  if result->>'identified_unknown_side'<>'true'
    or (select count(*) from public.hybrid_kotc_slots s join public.hybrid_kotc_teams t on t.id=s.team_id and t.facility_id=s.facility_id
       where t.facility_id=fid and t.status='retired' and s.player_id is null)<>3
    or exists(select 1 from public.waitlist_players where facility_id=fid and id=any(selected_group[2:3]) and group_id is distinct from first_group_id)
  then raise exception 'A fitting non-reporter permanent group was not preserved: %',result; end if;

  -- A reporter party of four cannot add a second indivisible party of three:
  -- there is no seven-player side and the failed request must create nothing.
  fid:=gen_random_uuid(); actor:=gen_random_uuid(); reporter:=gen_random_uuid(); reporter_group:=gen_random_uuid(); first_group_id:=gen_random_uuid(); selected:='{}'::uuid[];
  insert into public.facilities(id,name,slug,code) values(fid,'Stage5 nonfitting group','s5-no-fit-'||left(fid::text,8),left(fid::text,8));
  insert into auth.users(id,instance_id,aud,role,email) values(actor,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',actor||'@example.test');
  insert into public.user_facility_sessions(user_id,facility_id) values(actor,fid); perform set_config('request.jwt.claim.sub',actor::text,true);
  insert into public.waitlist_config(facility_id,id,game_number,max_players,mode,court_count,geofence_enabled,hybrid_rotation_rule) values(fid,true,1,24,'hybrid_waitlist',1,false,'kotc');
  insert into public.waitlist_courts(facility_id,court_number,game_number,team_mode) values(fid,1,1,'king');
  insert into public.daily_waitlist_reset_state(facility_id,id) values(fid,true);
  insert into public.hybrid_kotc_court_state(facility_id,court_number,version,initialized_game_number) values(fid,1,10,1);
  for i in 1..7 loop
    player_id:=case when i=1 then reporter else gen_random_uuid() end;
    insert into public.waitlist_players(id,facility_id,user_id,first_name,last_name,display_name,status,queue_position,court_number,group_id)
      values(player_id,fid,case when i=1 then actor else null end,'Player '||i,'','Player '||i,'current',i,1,
        case when i<=4 then reporter_group else first_group_id end);
    selected:=array_append(selected,player_id);
  end loop;
  begin
    perform public.confirm_hybrid_kotc_unknown_result(1,'win',fid,1,10,selected);
    raise exception 'A seven-player selected side was accepted';
  exception when others then
    if position('Selected teammates' in sqlerrm)=0 then raise; end if;
  end;
  if exists(select 1 from public.hybrid_kotc_teams where facility_id=fid)
    or (select game_number from public.waitlist_courts where facility_id=fid and court_number=1)<>1
  then raise exception 'Non-fitting permanent groups mutated state'; end if;
end $$;
rollback;
