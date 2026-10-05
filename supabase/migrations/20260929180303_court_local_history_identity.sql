-- `waitlist_courts.game_number` is a court-local display identity. `past_games`
-- keeps its existing facility-wide unique ordinal; reversal continues to target
-- the immutable past-game UUID. The facility advisory lock already protects the
-- shared queue and serializes allocation of the history ordinal.
create or replace function public.end_court_game(p_court_number integer)
returns jsonb language plpgsql security definer set search_path=public as $$
declare reversal_before jsonb; caller public.waitlist_players; cfg public.waitlist_config; court public.waitlist_courts; next_game integer; history_game integer; actor text; response_rows jsonb:='[]'::jsonb; last_position bigint; fid uuid:=public.current_facility_id();
begin
  perform pg_advisory_xact_lock(7429101); perform public.repair_facility_court_assignments(fid);
  select * into cfg from public.waitlist_config where facility_id=fid and id for update;
  if cfg.mode='hybrid_waitlist' and cfg.hybrid_rotation_rule<>'two_on_two_off' then raise exception 'Use the guarded Waitlist KOTC result action for this court.'; end if;
  reversal_before:=public.capture_court_reversal_state(); select * into court from public.waitlist_courts where facility_id=fid and court_number=p_court_number for update;
  if court.court_number is null then raise exception 'That court is not active.'; end if;
  select * into caller from public.waitlist_players where facility_id=fid and user_id=auth.uid();
  if not public.is_waitlist_operator() and(caller.id is null or caller.status<>'current' or caller.court_number<>p_court_number or caller.restricted) then raise exception 'Only an unrestricted player on this court or an admin/host can start its next game.'; end if;
  perform public.save_admin_undo('start next game');
  select coalesce(max(game_number),0)+1 into history_game from public.past_games where facility_id=fid;
  insert into public.past_games(facility_id,game_number,player_names,court_number) select fid,history_game,coalesce(jsonb_agg(display_name order by queue_position),'[]'::jsonb),p_court_number from public.waitlist_players where facility_id=fid and status='current' and court_number=p_court_number;
  select coalesce(max(queue_position),0) into last_position from public.waitlist_players where facility_id=fid and status in('current','waiting','sitout','rejoin');
  with finished as(select id,row_number()over(order by queue_position,id) rn from public.waitlist_players where facility_id=fid and status='current' and court_number=p_court_number) update public.waitlist_players p set queue_position=last_position+finished.rn,court_number=null,updated_at=now() from finished where p.id=finished.id;
  if cfg.mode in('rejoin','hybrid_waitlist') then
    update public.waitlist_players set status='rejoin',rejoin_expires_at=now()+case when user_id is null then interval '15 minutes' else interval '5 minutes' end where facility_id=fid and status='current' and court_number is null and queue_position>last_position;
    with changed as(select * from public.waitlist_players where facility_id=fid and status='rejoin' and queue_position>last_position and user_id is not null),ins as(insert into public.rejoin_responses(facility_id,user_id,game_number,original_position,expires_at) select fid,user_id,court.game_number+1,queue_position,rejoin_expires_at from changed returning id,user_id) select coalesce(jsonb_agg(jsonb_build_object('user_id',user_id,'response_id',id)),'[]'::jsonb) into response_rows from ins;
  else update public.waitlist_players set status='waiting' where facility_id=fid and status='current' and court_number is null and queue_position>last_position; end if;
  update public.waitlist_players set status='waiting',sitout_from_game=null,updated_at=now() where facility_id=fid and status='sitout' and sitout_from_game<=court.game_number;
  next_game:=court.game_number+1;
  update public.waitlist_courts set game_number=next_game,started_at=now() where facility_id=fid and court_number=p_court_number;
  update public.waitlist_config set game_number=greatest(game_number,next_game),updated_at=now() where facility_id=fid and id;
  perform public.fill_open_court_slots(); actor:=coalesce(caller.display_name,'Admin');
  insert into public.waitlist_events(facility_id,actor_user_id,actor_name,event_type,message) values(fid,auth.uid(),actor,'next_game',actor||' started Game '||next_game||' on Court '||p_court_number||'.');
  perform public.record_court_reversal(reversal_before,p_court_number);
  return jsonb_build_object('message','Game '||next_game||' started on Court '||p_court_number||'.','game_number',next_game,'court_number',p_court_number,'rejoin_prompts',response_rows);
end; $$;
revoke all on function public.end_court_game(integer) from public,anon;
grant execute on function public.end_court_game(integer) to authenticated,opengym_runtime;
notify pgrst,'reload schema';
