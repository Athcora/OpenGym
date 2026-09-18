-- In normal Teams mode, a completed 2-on-2-off court with no eligible
-- waiting teams replays its two current teams.  Moving both teams to the
-- shared queue first relied on king_fill_courts() to restore them; a live
-- race exposed that this could leave every player off-court.  Keep both
-- teams current atomically instead.
create or replace function public.end_team_rotation(p_court_number integer)
returns jsonb language plpgsql security definer set search_path=public as $$
declare cfg public.waitlist_config; court public.waitlist_courts; caller public.waitlist_players;
  first_team public.king_teams; second_team public.king_teams; next_pos bigint; next_game integer; snap jsonb;
  expiry timestamptz:=now()+interval '5 minutes'; prompts jsonb:='[]'::jsonb; rec record;
  eligible_waiting integer:=0; deficit integer:=0; keep_first boolean:=false; keep_second boolean:=false;
  reversal_before jsonb; fid uuid:=public.current_facility_id();
begin
  perform pg_advisory_xact_lock(7429202);
  select * into cfg from public.waitlist_config where facility_id=fid and id for update;
  reversal_before:=public.capture_court_reversal_state();
  if cfg.mode not in('teams','teams_rejoin') then raise exception 'Team rotation is only available in Teams Mode.'; end if;
  select * into court from public.waitlist_courts where facility_id=fid and court_number=p_court_number for update;
  if court.team_mode<>'rotation' then raise exception 'This court is using King of the Court.'; end if;
  select * into first_team from public.king_teams where facility_id=fid and status='current' and court_number=p_court_number and court_side=1 for update;
  select * into second_team from public.king_teams where facility_id=fid and status='current' and court_number=p_court_number and court_side=2 for update;
  if first_team.id is null or second_team.id is null then raise exception 'Two active teams are required on this court.'; end if;
  select * into caller from public.waitlist_players where facility_id=fid and user_id=auth.uid();
  if not public.is_waitlist_operator() and (caller.id is null or caller.restricted or (caller.team_id not in(first_team.id,second_team.id) and not exists(select 1 from public.team_substitutes s where s.facility_id=fid and s.player_id=caller.id and s.team_id in(first_team.id,second_team.id)))) then raise exception 'Only a player on this court or an admin/host can advance the game.'; end if;
  snap:=jsonb_build_object('teams',(select jsonb_agg(to_jsonb(t) order by t.created_at) from public.king_teams t where t.facility_id=fid),'players',(select jsonb_agg(jsonb_build_object('id',p.id,'status',p.status,'court_number',p.court_number,'team_id',p.team_id,'queue_position',p.queue_position,'rejoin_expires_at',p.rejoin_expires_at)) from public.waitlist_players p where p.facility_id=fid),'court',to_jsonb(court),'config_game_number',cfg.game_number);
  insert into public.past_games(facility_id,game_number,court_number,player_names)
    select fid,court.game_number,p_court_number,coalesce(jsonb_agg(p.display_name order by t.court_side,p.queue_position,p.created_at),'[]'::jsonb)
    from public.king_teams t left join public.waitlist_players p on p.facility_id=fid and p.team_id=t.id and p.status<>'left'
    where t.facility_id=fid and t.id in(first_team.id,second_team.id) on conflict(facility_id,game_number) do nothing;
  select coalesce(max(queue_position),0)+1 into next_pos from public.king_teams where facility_id=fid and status='waiting';
  select count(*) into eligible_waiting from public.king_teams t
    where t.facility_id=fid and t.status='waiting'
      and exists(select 1 from public.waitlist_players p where p.facility_id=fid and p.team_id=t.id and p.status in('waiting','current','sitout'));
  if cfg.mode='teams_rejoin' then
    deficit:=greatest(2-eligible_waiting,0); keep_second:=deficit>=1; keep_first:=deficit>=2;
  elsif eligible_waiting=0 then
    -- Regular mode has no rejoin cycle.  There is nobody to rotate in, so
    -- replay the teams in their exact current sides and preserve all members.
    keep_first:=true; keep_second:=true;
  end if;
  update public.king_teams set status=case when keep_first then 'current' else 'waiting' end,queue_position=case when keep_first then 0 else next_pos end,court_number=case when keep_first then p_court_number else null end,court_side=case when keep_first then 1 else null end,consecutive_wins=0,rejoin_expires_at=case when cfg.mode='teams_rejoin' and not keep_first then expiry else null end,updated_at=now() where facility_id=fid and id=first_team.id;
  update public.king_teams set status=case when keep_second then 'current' else 'waiting' end,queue_position=case when keep_second then 0 else next_pos+1 end,court_number=case when keep_second then p_court_number else null end,court_side=case when keep_second then 2 else null end,consecutive_wins=0,rejoin_expires_at=case when cfg.mode='teams_rejoin' and not keep_second then expiry else null end,updated_at=now() where facility_id=fid and id=second_team.id;
  if cfg.mode='teams_rejoin' then
    update public.waitlist_players set status='rejoin',court_number=null,rejoin_expires_at=expiry,updated_at=now() where facility_id=fid and team_id in(first_team.id,second_team.id) and status<>'left' and not ((team_id=first_team.id and keep_first) or (team_id=second_team.id and keep_second));
  else
    update public.waitlist_players set status='waiting',court_number=null,rejoin_expires_at=null,updated_at=now() where facility_id=fid and team_id in(first_team.id,second_team.id) and status<>'left' and not ((team_id=first_team.id and keep_first) or (team_id=second_team.id and keep_second));
  end if;
  update public.waitlist_players set status='current',court_number=p_court_number,rejoin_expires_at=null,updated_at=now() where facility_id=fid and status<>'left' and ((team_id=first_team.id and keep_first) or (team_id=second_team.id and keep_second));
  next_game:=greatest(cfg.game_number,(select coalesce(max(game_number),0) from public.waitlist_courts where facility_id=fid),(select coalesce(max(game_number),0) from public.past_games where facility_id=fid))+1;
  if cfg.mode='teams_rejoin' then
    for rec in insert into public.rejoin_responses(facility_id,user_id,game_number,original_position,expires_at)
      select fid,p.user_id,next_game,p.queue_position,expiry from public.waitlist_players p where p.facility_id=fid and p.status='rejoin' and p.rejoin_expires_at=expiry and p.user_id is not null returning id,user_id
    loop prompts:=prompts||jsonb_build_array(jsonb_build_object('id',rec.id,'user_id',rec.user_id)); end loop;
  end if;
  update public.waitlist_config set game_number=next_game,updated_at=now() where facility_id=fid and id;
  update public.waitlist_courts set game_number=next_game,started_at=now() where facility_id=fid and court_number=p_court_number;
  insert into public.king_round_history(facility_id,court_number,game_number,winning_team_id,winning_team_name,losing_team_name,snapshot,actor_user_id) values(fid,p_court_number,court.game_number,first_team.id,'2 on, 2 off','Both teams rotated',snap,auth.uid());
  perform public.king_compact_queue(); perform public.king_fill_courts();
  insert into public.waitlist_events(facility_id,actor_user_id,actor_name,event_type,message) values(fid,auth.uid(),coalesce(caller.display_name,'Admin'),'team_rotation','Game '||court.game_number||' ended on Court '||p_court_number||'. Both teams rotated.');
  perform public.record_court_reversal(reversal_before,p_court_number);
  return jsonb_build_object('message','Both teams rotated out and the next two teams entered.','game_number',next_game,'rejoin_prompts',prompts);
end;
$$;

grant execute on function public.end_team_rotation(integer) to service_role;
notify pgrst,'reload schema';
