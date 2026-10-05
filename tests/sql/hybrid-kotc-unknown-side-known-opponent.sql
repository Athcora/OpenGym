-- Missing-side identification against one already-authoritative opponent.
begin;
do $$
declare fid uuid:=gen_random_uuid(); actor uuid:=gen_random_uuid(); reporter uuid:=gen_random_uuid(); mate uuid:=gen_random_uuid(); known_player uuid:=gen_random_uuid(); known_team uuid:=gen_random_uuid(); result jsonb;
begin
  insert into public.facilities(id,name,slug,code) values(fid,'Stage5 one known','s5-known-'||left(fid::text,8),left(fid::text,8));
  insert into auth.users(id,instance_id,aud,role,email) values(actor,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',actor||'@example.test');
  insert into public.user_facility_sessions(user_id,facility_id) values(actor,fid); perform set_config('request.jwt.claim.sub',actor::text,true);
  insert into public.waitlist_config(facility_id,id,game_number,max_players,mode,court_count,geofence_enabled,hybrid_rotation_rule) values(fid,true,1,24,'hybrid_waitlist',1,false,'kotc');
  insert into public.waitlist_courts(facility_id,court_number,game_number,team_mode) values(fid,1,1,'king');
  insert into public.daily_waitlist_reset_state(facility_id,id) values(fid,true);
  insert into public.hybrid_kotc_court_state(facility_id,court_number,version,initialized_game_number) values(fid,1,10,1);
  insert into public.waitlist_players(id,facility_id,user_id,first_name,last_name,display_name,status,queue_position,court_number) values
    (reporter,fid,actor,'Reporter','','Reporter','current',1,1),(mate,fid,null,'Mate','','Mate','current',2,1),(known_player,fid,null,'Known','','Known','current',3,1);
  insert into public.hybrid_kotc_teams(id,facility_id,court_number,court_side,appearance_game_number,status) values(known_team,fid,1,1,1,'current');
  insert into public.hybrid_kotc_slots(facility_id,team_id,slot_number,player_id) values(fid,known_team,1,known_player);
  if (public.prepare_hybrid_kotc_result(1,'lose',fid,1,10)->>'selection_required')<>'true' then raise exception 'unknown reporter did not require identification'; end if;
  begin perform public.confirm_hybrid_kotc_unknown_result(1,'lose',fid,1,10,array[reporter]); raise exception 'partial missing side accepted';
  exception when others then if position('All unassigned' in sqlerrm)=0 then raise; end if; end;
  result:=public.confirm_hybrid_kotc_unknown_result(1,'lose',fid,1,10,array[reporter,mate]);
  if result->>'identified_unknown_side'<>'true' or (select count(*) from public.past_games where facility_id=fid)<>1
    or (select group_id from public.waitlist_players where id=reporter) is not null
  then raise exception 'one-known-side confirmation failed: %',result; end if;
end $$;
rollback;
