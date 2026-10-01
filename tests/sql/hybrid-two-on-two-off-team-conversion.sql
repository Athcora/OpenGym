-- Local-only Stage 2 contract: both legacy team modes normalize to the
-- dormant Rejoin-backed hybrid without turning temporary teams into groups.
begin;
do $$
declare
  fid uuid:=gen_random_uuid(); admin uuid:=gen_random_uuid(); v_group_id uuid:=gen_random_uuid();
  team_mode text; i integer; before_group_members integer; current_count integer;
begin
  insert into auth.users(id,instance_id,aud,role,email)
  values(admin,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',admin||'@example.test');
  insert into public.facilities(id,name,slug,code)
  values(fid,'Local hybrid team conversion','local-hybrid-team-'||left(fid::text,8),left(fid::text,8));
  insert into public.facility_admin_credentials(facility_id,username,display_username,password_hash)
  values(fid,'admin','Admin',crypt('x',gen_salt('bf')));
  insert into public.admin_sessions(user_id,username,facility_id) values(admin,'admin',fid);
  insert into public.user_facility_sessions(user_id,facility_id) values(admin,fid);
  insert into public.waitlist_config(facility_id,id,game_number,max_players,mode,court_count,geofence_enabled)
  values(fid,true,1,12,'regular',1,false);
  insert into public.waitlist_courts(facility_id,court_number,game_number,team_mode)
  values(fid,1,1,'rotation');
  insert into public.daily_waitlist_reset_state(facility_id,id) values(fid,true);
  perform set_config('request.jwt.claim.sub',admin::text,true);
  for i in 1..12 loop
    insert into public.waitlist_players(facility_id,first_name,last_name,display_name,status,queue_position,court_number,group_id)
    values(fid,'P'||i,'','P'||i,case when i<=6 then 'current' else 'waiting' end,i,case when i<=6 then 1 else null end,case when i in(1,2) then v_group_id else null end);
  end loop;
  foreach team_mode in array array['teams','teams_rejoin'] loop
    perform public.set_open_gym_mode(team_mode);
    if not exists(select 1 from public.king_teams where facility_id=fid)
      or not exists(select 1 from public.waitlist_players where facility_id=fid and team_id is not null) then
      raise exception '% setup did not form temporary teams',team_mode;
    end if;
    select count(*) into before_group_members from public.waitlist_players where facility_id=fid and group_id=v_group_id;
    perform public.set_open_gym_mode('hybrid_waitlist');
    if not exists(select 1 from public.waitlist_config where facility_id=fid and mode='hybrid_waitlist' and hybrid_rotation_rule='two_on_two_off' and hybrid_auto_kotc_threshold_teams is null and not hybrid_auto_kotc_armed) then
      raise exception '% did not enter dormant two_on_two_off hybrid',team_mode;
    end if;
    if exists(select 1 from public.king_teams where facility_id=fid)
      or exists(select 1 from public.king_mode_state where facility_id=fid)
      or exists(select 1 from public.waitlist_players where facility_id=fid and team_id is not null) then
      raise exception '% temporary team runtime leaked into hybrid',team_mode;
    end if;
    if (select count(*) from public.waitlist_players where facility_id=fid and group_id=v_group_id)<>before_group_members then
      raise exception '% conversion changed permanent group membership',team_mode;
    end if;
    select count(*) into current_count from public.waitlist_players where facility_id=fid and status='current' and court_number=1;
    if current_count<>12 then raise exception '% conversion did not restore the configured twelve-player individual court',team_mode; end if;
    if exists(select 1 from public.hybrid_kotc_teams where facility_id=fid)
      or exists(select 1 from public.hybrid_kotc_slots where facility_id=fid) then
      raise exception '% conversion created KOTC runtime',team_mode;
    end if;
    perform public.admin_undo_last();
    if not exists(select 1 from public.waitlist_config where facility_id=fid and mode=team_mode)
      or not exists(select 1 from public.king_teams where facility_id=fid)
      or not exists(select 1 from public.waitlist_players where facility_id=fid and team_id is not null) then
      raise exception '% Admin Undo did not restore legacy temporary teams',team_mode;
    end if;
    perform public.admin_redo_last();
    if not exists(select 1 from public.waitlist_config where facility_id=fid and mode='hybrid_waitlist')
      or exists(select 1 from public.king_teams where facility_id=fid)
      or exists(select 1 from public.waitlist_players where facility_id=fid and team_id is not null) then
      raise exception '% Admin Redo did not restore hybrid conversion',team_mode;
    end if;
    -- Return to a legacy team mode so the second branch starts from an actual
    -- team lifecycle rather than a fabricated table state.
    perform public.set_open_gym_mode('regular');
  end loop;
  raise notice 'Teams and Teams Rejoin -> dormant hybrid conversion PASS';
end $$;
rollback;
