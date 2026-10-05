-- Disposable, transaction-rolled-back fixtures; local Supabase only.
begin;
do $$
declare
  mode_name text; fid uuid; actor uuid; p1 uuid; p2 uuid; grp uuid; team uuid;
  before_state jsonb; captured jsonb; expected_players jsonb; actual_players jsonb;
begin
  foreach mode_name in array array['regular','rejoin','teams','teams_rejoin'] loop
    fid:=gen_random_uuid(); actor:=gen_random_uuid(); p1:=gen_random_uuid();
    p2:=gen_random_uuid(); grp:=gen_random_uuid(); team:=null;
    insert into public.facilities(id,name,slug,code)
      values(fid,'Local legacy history', 'local-history-'||fid, left(fid::text,8));
    insert into auth.users(id,instance_id,aud,role,email)
      values(actor,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',actor||'@example.test');
    insert into public.facility_admin_credentials(facility_id,username,display_username,password_hash)
      values(fid,'localadmin','Local Admin',crypt('local-only-password',gen_salt('bf')));
    insert into public.admin_sessions(user_id,username,facility_id) values(actor,'localadmin',fid);
    insert into public.user_facility_sessions(user_id,facility_id) values(actor,fid);
    insert into public.waitlist_config(facility_id,id,game_number,max_players,mode,court_count,geofence_enabled)
      values(fid,true,1,12,mode_name,1,false);
    insert into public.waitlist_courts(facility_id,court_number,game_number) values(fid,1,1);
    insert into public.daily_waitlist_reset_state(facility_id,id) values(fid,true);
    perform set_config('request.jwt.claim.sub',actor::text,true);
    if mode_name in ('teams','teams_rejoin') then
      team:=gen_random_uuid();
      insert into public.king_teams(id,facility_id,name,status,queue_position,court_number,court_side)
        values(team,fid,'Team 1','current',1,1,1);
    end if;
    insert into public.waitlist_players(id,facility_id,first_name,last_name,display_name,status,queue_position,court_number,group_id,team_id)
      values(p1,fid,'First','','First','current',1,1,grp,team),
            (p2,fid,'Second','','Second','current',2,1,grp,team);
    before_state:=public.capture_waitlist_state();
    if jsonb_array_length(before_state->'players')<>2 or before_state->'config'->>'mode'<>mode_name then
      raise exception '% capture failed',mode_name;
    end if;
    perform public.save_admin_undo('local legacy history');
    update public.waitlist_players set display_name='Edited',group_id=null where id=p1;
    update public.waitlist_config set game_number=9 where facility_id=fid;
    set local role authenticated;
    perform public.admin_undo_last();
    reset role;
    captured:=public.capture_waitlist_state();
    select jsonb_agg(value-'updated_at' order by value->>'id') into expected_players from jsonb_array_elements(before_state->'players');
    select jsonb_agg(value-'updated_at' order by value->>'id') into actual_players from jsonb_array_elements(captured->'players');
    if actual_players is distinct from expected_players then raise exception '% Undo player identities/relationships differ',mode_name; end if;
    if captured->'config'->>'mode'<>mode_name or captured->'config'->>'game_number'<>'1' then
      raise exception '% Undo config mismatch',mode_name;
    end if;
    if captured->'courts' is distinct from before_state->'courts' then raise exception '% Undo court state mismatch',mode_name; end if;
    if team is not null and not exists(select 1 from public.king_teams where id=team and facility_id=fid and name='Team 1') then
      raise exception '% Undo team identity mismatch',mode_name;
    end if;
    set local role authenticated;
    perform public.admin_redo_last();
    reset role;
    if not exists(select 1 from public.waitlist_players where id=p1 and display_name='Edited' and group_id is null and team_id is not distinct from team) then
      raise exception '% Redo did not restore edited player',mode_name;
    end if;
    if not exists(select 1 from public.waitlist_players where id=p2 and group_id=grp and team_id is not distinct from team) then
      raise exception '% Redo changed unrelated permanent grouping',mode_name;
    end if;
    if not exists(select 1 from public.waitlist_config where facility_id=fid and mode=mode_name and game_number=9) then
      raise exception '% Redo config mismatch',mode_name;
    end if;
    if exists(select 1 from public.hybrid_kotc_teams where facility_id=fid)
      or exists(select 1 from public.hybrid_kotc_slots where facility_id=fid)
      or exists(select 1 from public.hybrid_kotc_substitutes where facility_id=fid)
      or exists(select 1 from public.hybrid_kotc_court_state where facility_id=fid) then
      raise exception '% Admin history unexpectedly requires/creates hybrid rows',mode_name;
    end if;
    raise notice '% legacy capture/Undo/Redo PASS',mode_name;
  end loop;
end $$;
rollback;
