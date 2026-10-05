-- Stage 2: Hybrid Waitlist begins as the existing Rejoin engine. KOTC is
-- explicitly dormant until a later guarded rule transition enables it.
create or replace function public.set_open_gym_mode(p_mode text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare current_mode text; fid uuid:=public.current_facility_id();
begin
  if fid is null then raise exception 'Select a facility first.'; end if;
  if not public.is_waitlist_admin() then raise exception 'Admin access required.'; end if;
  if p_mode not in('regular','rejoin','teams','teams_rejoin','hybrid_waitlist') then raise exception 'Unknown waitlist mode.'; end if;
  perform pg_advisory_xact_lock(7429201);
  select mode into current_mode from public.waitlist_config where facility_id=fid and id for update;
  if current_mode is null then raise exception 'Facility configuration not found.'; end if;
  if current_mode=p_mode then return jsonb_build_object('message','Mode unchanged.'); end if;
  perform public.save_admin_undo('change waitlist mode');
  if p_mode in('teams','teams_rejoin') and current_mode in('teams','teams_rejoin') then
    update public.waitlist_config set mode=p_mode,updated_at=now() where facility_id=fid and id;
    update public.waitlist_courts set team_mode='king' where facility_id=fid and team_mode='king_rejoin';
  elsif p_mode in('teams','teams_rejoin') then
    update public.waitlist_config set mode=p_mode,updated_at=now() where facility_id=fid and id;
    update public.waitlist_courts set team_mode='king' where facility_id=fid and team_mode='king_rejoin';
    delete from public.rejoin_responses where facility_id=fid and choice is null;
    update public.waitlist_players set rejoin_expires_at=null,status=case when status='rejoin' then 'waiting' else status end,updated_at=now() where facility_id=fid and status<>'left';
    perform public.initialize_king_mode();
  elsif current_mode in('teams','teams_rejoin') then
    with ordered as(select p.id,row_number() over(order by case when t.status='current' then 0 when t.status='waiting' then 1 else 2 end,case when t.status='current' then t.court_number end nulls last,case when t.status='current' then t.court_side end nulls last,case when t.status='waiting' then t.queue_position end nulls last,p.queue_position nulls last,p.created_at,p.id) as new_position from public.waitlist_players p left join public.king_teams t on t.facility_id=fid and t.id=p.team_id where p.facility_id=fid and p.status<>'left')
    update public.waitlist_players p set status=case when p.status='sitout' then 'sitout' else 'waiting' end,queue_position=ordered.new_position,court_number=null,team_id=null,rejoin_expires_at=null,updated_at=now() from ordered where p.facility_id=fid and p.id=ordered.id;
    delete from public.rejoin_responses where facility_id=fid and choice is null; delete from public.team_fill_ins where facility_id=fid; delete from public.team_substitute_requests where facility_id=fid; delete from public.team_substitutes where facility_id=fid; delete from public.king_teams where facility_id=fid; delete from public.king_mode_state where facility_id=fid;
    update public.waitlist_config set mode=p_mode,hybrid_rotation_rule=case when p_mode='hybrid_waitlist' then 'two_on_two_off' else hybrid_rotation_rule end,hybrid_auto_kotc_threshold_teams=case when p_mode='hybrid_waitlist' then null else hybrid_auto_kotc_threshold_teams end,hybrid_auto_kotc_armed=case when p_mode='hybrid_waitlist' then false else hybrid_auto_kotc_armed end,updated_at=now() where facility_id=fid and id;
    perform public.fill_open_court_slots();
  else
    update public.waitlist_config set mode=p_mode,hybrid_rotation_rule=case when p_mode='hybrid_waitlist' then 'two_on_two_off' else hybrid_rotation_rule end,hybrid_auto_kotc_threshold_teams=case when p_mode='hybrid_waitlist' then null else hybrid_auto_kotc_threshold_teams end,hybrid_auto_kotc_armed=case when p_mode='hybrid_waitlist' then false else hybrid_auto_kotc_armed end,updated_at=now() where facility_id=fid and id;
  end if;
  perform public.log_waitlist_operator_action('mode_change','changed the waitlist mode to '||p_mode||'.');
  return jsonb_build_object('message','Waitlist mode changed to '||p_mode||'.');
end; $$;

create or replace function public.end_court_game(p_court_number integer)
returns jsonb language plpgsql security definer set search_path=public as $$
declare reversal_before jsonb; caller public.waitlist_players; cfg public.waitlist_config; court public.waitlist_courts; next_game integer; actor text; response_rows jsonb:='[]'::jsonb; last_position bigint; fid uuid:=public.current_facility_id();
begin
  perform pg_advisory_xact_lock(7429101); perform public.repair_facility_court_assignments(fid);
  select * into cfg from public.waitlist_config where facility_id=fid and id for update;
  if cfg.mode='hybrid_waitlist' and cfg.hybrid_rotation_rule<>'two_on_two_off' then raise exception 'Use the guarded Waitlist KOTC result action for this court.'; end if;
  reversal_before:=public.capture_court_reversal_state(); select * into court from public.waitlist_courts where facility_id=fid and court_number=p_court_number for update;
  if court.court_number is null then raise exception 'That court is not active.'; end if;
  select * into caller from public.waitlist_players where facility_id=fid and user_id=auth.uid();
  if not public.is_waitlist_operator() and(caller.id is null or caller.status<>'current' or caller.court_number<>p_court_number or caller.restricted) then raise exception 'Only an unrestricted player on this court or an admin/host can start its next game.'; end if;
  perform public.save_admin_undo('start next game');
  insert into public.past_games(facility_id,game_number,player_names,court_number) select fid,court.game_number,coalesce(jsonb_agg(display_name order by queue_position),'[]'::jsonb),p_court_number from public.waitlist_players where facility_id=fid and status='current' and court_number=p_court_number on conflict(facility_id,game_number) do nothing;
  select coalesce(max(queue_position),0) into last_position from public.waitlist_players where facility_id=fid and status in('current','waiting','sitout','rejoin');
  with finished as(select id,row_number()over(order by queue_position,id) rn from public.waitlist_players where facility_id=fid and status='current' and court_number=p_court_number) update public.waitlist_players p set queue_position=last_position+finished.rn,court_number=null,updated_at=now() from finished where p.id=finished.id;
  if cfg.mode in('rejoin','hybrid_waitlist') then
    update public.waitlist_players set status='rejoin',rejoin_expires_at=now()+case when user_id is null then interval '15 minutes' else interval '5 minutes' end where facility_id=fid and status='current' and court_number is null and queue_position>last_position;
    with changed as(select * from public.waitlist_players where facility_id=fid and status='rejoin' and queue_position>last_position and user_id is not null),ins as(insert into public.rejoin_responses(facility_id,user_id,game_number,original_position,expires_at) select fid,user_id,court.game_number+1,queue_position,rejoin_expires_at from changed returning id,user_id) select coalesce(jsonb_agg(jsonb_build_object('user_id',user_id,'response_id',id)),'[]'::jsonb) into response_rows from ins;
  else update public.waitlist_players set status='waiting' where facility_id=fid and status='current' and court_number is null and queue_position>last_position; end if;
  update public.waitlist_players set status='waiting',sitout_from_game=null,updated_at=now() where facility_id=fid and status='sitout' and sitout_from_game<=court.game_number;
  next_game:=greatest((select coalesce(max(game_number),0) from public.waitlist_courts where facility_id=fid),(select coalesce(max(game_number),0) from public.past_games where facility_id=fid))+1;
  update public.waitlist_courts set game_number=next_game,started_at=now() where facility_id=fid and court_number=p_court_number; update public.waitlist_config set game_number=next_game,updated_at=now() where facility_id=fid and id; perform public.fill_open_court_slots();
  actor:=coalesce(caller.display_name,'Admin'); insert into public.waitlist_events(facility_id,actor_user_id,actor_name,event_type,message) values(fid,auth.uid(),actor,'next_game',actor||' started Game '||next_game||' on Court '||p_court_number||'.'); perform public.record_court_reversal(reversal_before,p_court_number);
  return jsonb_build_object('message','Game '||next_game||' started on Court '||p_court_number||'.','game_number',next_game,'court_number',p_court_number,'rejoin_prompts',response_rows);
end; $$;

revoke all on function public.set_open_gym_mode(text),public.end_court_game(integer) from public,anon;
grant execute on function public.set_open_gym_mode(text),public.end_court_game(integer) to authenticated,opengym_runtime;
notify pgrst,'reload schema';
