-- Teams rejoin is an overall waitlist mode. Courts only choose rotation or king.
update public.waitlist_courts set team_mode='king' where team_mode='king_rejoin';

create or replace function public.set_team_court_rules(p_court_number integer,p_team_mode text,p_max_wins integer default 2)
returns jsonb language plpgsql security definer set search_path=public as $$
begin
  if not public.is_waitlist_operator() then raise exception 'Admin or host access required.'; end if;
  if p_team_mode not in('rotation','king') then raise exception 'Choose 2 on, 2 off or King of the Court.'; end if;
  if p_team_mode='king' and p_max_wins is not null and p_max_wins not in(2,3) then raise exception 'Choose 2, 3, or Unlimited consecutive games.'; end if;
  update public.waitlist_courts set team_mode=p_team_mode,
    team_max_wins=case when p_team_mode='rotation' then 2 else p_max_wins end
    where court_number=p_court_number;
  return jsonb_build_object('message','Court rules updated.');
end; $$;
grant execute on function public.set_team_court_rules(integer,text,integer) to authenticated;

create or replace function public.initialize_king_mode()
returns void language plpgsql security definer set search_path=public as $$
declare p record; created_team uuid; next_pos bigint:=0;
begin
  if not exists(select 1 from public.waitlist_config where id and mode in('teams','teams_rejoin')) then return; end if;
  for p in select * from public.waitlist_players where status<>'left' and team_id is null order by queue_position,id loop
    next_pos:=next_pos+1;
    insert into public.king_teams(name,queue_position) values('Team '||next_pos,next_pos) returning id into created_team;
    update public.waitlist_players set team_id=created_team,status='waiting',court_number=null where id=p.id;
  end loop;
  perform public.king_fill_courts();
end; $$;

create or replace function public.set_open_gym_mode(p_mode text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare current_mode text; saved jsonb; team_to_delete uuid; player_to_clear uuid;
begin
  if not exists(select 1 from public.admin_sessions where user_id=auth.uid()) then raise exception 'Admin access required.'; end if;
  if p_mode not in('regular','rejoin','teams','teams_rejoin') then raise exception 'Unknown waitlist mode.'; end if;
  select mode into current_mode from public.waitlist_config where id for update;
  if current_mode=p_mode then return jsonb_build_object('message','Mode unchanged.'); end if;

  if p_mode in('teams','teams_rejoin') and current_mode in('teams','teams_rejoin') then
    update public.waitlist_config set mode=p_mode,updated_at=now() where id;
    update public.waitlist_courts set team_mode='king' where team_mode='king_rejoin';
  elsif p_mode in('teams','teams_rejoin') then
    insert into public.king_mode_state(id,regular_state,saved_at)
      values(true,public.capture_waitlist_state(),now())
      on conflict(id) do update set regular_state=excluded.regular_state,saved_at=now();
    update public.waitlist_config set mode=p_mode,updated_at=now() where id;
    update public.waitlist_courts set team_mode='king' where team_mode='king_rejoin';
    perform public.initialize_king_mode();
  elsif current_mode in('teams','teams_rejoin') then
    select regular_state into saved from public.king_mode_state where id;
    if saved is not null then perform public.restore_waitlist_state(saved); end if;
    update public.waitlist_config set mode=p_mode,updated_at=now() where id;
    for team_to_delete in select id from public.king_teams loop delete from public.king_teams where id=team_to_delete; end loop;
    for player_to_clear in select id from public.waitlist_players where team_id is not null loop update public.waitlist_players set team_id=null where id=player_to_clear; end loop;
  else
    update public.waitlist_config set mode=p_mode,updated_at=now() where id;
  end if;
  return jsonb_build_object('message','Waitlist mode changed to '||p_mode||'.');
end; $$;
grant execute on function public.set_open_gym_mode(text) to authenticated;

create or replace function public.end_team_rotation(p_court_number integer)
returns jsonb language plpgsql security definer set search_path=public as $$
declare cfg public.waitlist_config; court public.waitlist_courts; caller public.waitlist_players;
  first_team public.king_teams; second_team public.king_teams; next_pos bigint; next_game integer; snap jsonb;
  expiry timestamptz:=now()+interval '5 minutes'; prompts jsonb:='[]'::jsonb; rec record;
  eligible_waiting integer:=0; deficit integer:=0; keep_first boolean:=false; keep_second boolean:=false;
begin
  perform pg_advisory_xact_lock(7429202);
  select * into cfg from public.waitlist_config where id for update;
  if cfg.mode not in('teams','teams_rejoin') then raise exception 'Team rotation is only available in Teams Mode.'; end if;
  select * into court from public.waitlist_courts where court_number=p_court_number for update;
  if court.team_mode<>'rotation' then raise exception 'This court is using King of the Court.'; end if;
  select * into first_team from public.king_teams where status='current' and court_number=p_court_number and court_side=1 for update;
  select * into second_team from public.king_teams where status='current' and court_number=p_court_number and court_side=2 for update;
  if first_team.id is null or second_team.id is null then raise exception 'Two active teams are required on this court.'; end if;
  select * into caller from public.waitlist_players where user_id=auth.uid();
  if not public.is_waitlist_operator() and (caller.id is null or caller.restricted or (caller.team_id not in(first_team.id,second_team.id) and not exists(select 1 from public.team_substitutes s where s.player_id=caller.id and s.team_id in(first_team.id,second_team.id)))) then raise exception 'Only a player on this court or an admin/host can advance the game.'; end if;
  snap:=jsonb_build_object(
    'teams',(select jsonb_agg(to_jsonb(t) order by t.created_at) from public.king_teams t),
    'players',(select jsonb_agg(jsonb_build_object('id',p.id,'status',p.status,'court_number',p.court_number,'team_id',p.team_id,'queue_position',p.queue_position,'rejoin_expires_at',p.rejoin_expires_at)) from public.waitlist_players p),
    'court',to_jsonb(court),'config_game_number',cfg.game_number);
  insert into public.past_games(game_number,court_number,player_names)
    select court.game_number,p_court_number,coalesce(jsonb_agg(p.display_name order by t.court_side,p.queue_position,p.created_at),'[]'::jsonb)
    from public.king_teams t left join public.waitlist_players p on p.team_id=t.id and p.status<>'left' where t.id in(first_team.id,second_team.id);
  select coalesce(max(queue_position),0)+1 into next_pos from public.king_teams where status='waiting';
  if cfg.mode='teams_rejoin' then
    select count(*) into eligible_waiting from public.king_teams t where t.status='waiting' and exists(select 1 from public.waitlist_players p where p.team_id=t.id and p.status in('waiting','current','sitout'));
    deficit:=greatest(2-eligible_waiting,0); keep_second:=deficit>=1; keep_first:=deficit>=2;
  end if;
  update public.king_teams set status=case when keep_first then 'current' else 'waiting' end,
    queue_position=case when keep_first then 0 else next_pos end,court_number=case when keep_first then p_court_number else null end,
    court_side=case when keep_first then 1 else null end,consecutive_wins=0,rejoin_expires_at=case when cfg.mode='teams_rejoin' then expiry else null end,updated_at=now() where id=first_team.id;
  update public.king_teams set status=case when keep_second then 'current' else 'waiting' end,
    queue_position=case when keep_second then 0 else next_pos+1 end,court_number=case when keep_second then p_court_number else null end,
    court_side=case when keep_second then 2 else null end,consecutive_wins=0,rejoin_expires_at=case when cfg.mode='teams_rejoin' then expiry else null end,updated_at=now() where id=second_team.id;
  if cfg.mode='teams_rejoin' then
    update public.waitlist_players set status='rejoin',court_number=null,rejoin_expires_at=expiry,updated_at=now() where team_id in(first_team.id,second_team.id) and status<>'left';
  else
    update public.waitlist_players set status='waiting',court_number=null,rejoin_expires_at=null,updated_at=now() where team_id in(first_team.id,second_team.id) and status<>'left';
  end if;
  next_game:=greatest(cfg.game_number,(select coalesce(max(game_number),0) from public.waitlist_courts),(select coalesce(max(game_number),0) from public.past_games))+1;
  if cfg.mode='teams_rejoin' then
    for rec in insert into public.rejoin_responses(user_id,game_number,original_position,expires_at)
      select p.user_id,next_game,p.queue_position,expiry from public.waitlist_players p where p.status='rejoin' and p.rejoin_expires_at=expiry and p.user_id is not null returning id,user_id
    loop prompts:=prompts||jsonb_build_array(jsonb_build_object('id',rec.id,'user_id',rec.user_id)); end loop;
  end if;
  update public.waitlist_config set game_number=next_game,updated_at=now() where id;
  update public.waitlist_courts set game_number=next_game,started_at=now() where court_number=p_court_number;
  insert into public.king_round_history(court_number,game_number,winning_team_id,winning_team_name,losing_team_name,snapshot,actor_user_id)
    values(p_court_number,court.game_number,first_team.id,'2 on, 2 off','Both teams rotated',snap,auth.uid());
  perform public.king_compact_queue(); perform public.king_fill_courts();
  insert into public.waitlist_events(actor_user_id,actor_name,event_type,message) values(auth.uid(),coalesce(caller.display_name,'Admin'),'team_rotation','Game '||court.game_number||' ended on Court '||p_court_number||'. Both teams rotated.');
  return jsonb_build_object('message','Both teams rotated out and the next two teams entered.','game_number',next_game,'rejoin_prompts',prompts);
end; $$;
grant execute on function public.end_team_rotation(integer) to authenticated;

create or replace function public.end_team_king_game(p_court_number integer,p_winning_team_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare cfg public.waitlist_config; court public.waitlist_courts; winner public.king_teams; loser public.king_teams;
  caller public.waitlist_players; next_pos bigint; next_game integer; winner_stays boolean; snap jsonb;
  prompts jsonb:='[]'::jsonb; expiry timestamptz:=now()+interval '5 minutes'; rec record; rejoin_mode boolean:=false;
  eligible_waiting integer:=0; deficit integer:=0; keep_loser_current boolean:=false; keep_winner_current boolean:=false; rotate_loser boolean:=true;
begin
  perform pg_advisory_xact_lock(7429202);
  select * into cfg from public.waitlist_config where id for update; rejoin_mode:=cfg.mode='teams_rejoin';
  if cfg.mode not in('teams','teams_rejoin') then raise exception 'King of the Court is only available in Teams Mode.'; end if;
  select * into court from public.waitlist_courts where court_number=p_court_number for update;
  if court.team_mode<>'king' then raise exception 'This court is using 2 on, 2 off.'; end if;
  select * into winner from public.king_teams where id=p_winning_team_id and status='current' and court_number=p_court_number for update;
  select * into loser from public.king_teams where status='current' and court_number=p_court_number and id<>p_winning_team_id order by court_side limit 1 for update;
  if winner.id is null or loser.id is null then raise exception 'Two active teams are required on this court.'; end if;
  select * into caller from public.waitlist_players where user_id=auth.uid();
  if not public.is_waitlist_operator() and (caller.id is null or caller.restricted or (caller.team_id not in(winner.id,loser.id) and not exists(select 1 from public.team_substitutes s where s.player_id=caller.id and s.team_id in(winner.id,loser.id)))) then raise exception 'Only a player on this court or an admin/host can record the winner.'; end if;
  snap:=jsonb_build_object('teams',(select jsonb_agg(to_jsonb(t) order by t.created_at) from public.king_teams t),'players',(select jsonb_agg(jsonb_build_object('id',p.id,'status',p.status,'court_number',p.court_number,'team_id',p.team_id,'queue_position',p.queue_position,'rejoin_expires_at',p.rejoin_expires_at)) from public.waitlist_players p),'court',to_jsonb(court),'config_game_number',cfg.game_number);
  insert into public.past_games(game_number,court_number,player_names) select court.game_number,p_court_number,coalesce(jsonb_agg(p.display_name order by t.court_side,p.queue_position,p.created_at),'[]'::jsonb) from public.king_teams t left join public.waitlist_players p on p.team_id=t.id and p.status<>'left' where t.id in(winner.id,loser.id);
  next_game:=greatest(cfg.game_number,(select coalesce(max(game_number),0) from public.waitlist_courts),(select coalesce(max(game_number),0) from public.past_games))+1;
  select coalesce(max(queue_position),0)+1 into next_pos from public.king_teams where status='waiting';
  winner_stays:=court.team_max_wins is null or winner.consecutive_wins+1<court.team_max_wins;
  rotate_loser:=not rejoin_mode or winner_stays;
  if rejoin_mode then
    select count(*) into eligible_waiting from public.king_teams t where t.status='waiting' and exists(select 1 from public.waitlist_players p where p.team_id=t.id and p.status in('waiting','current','sitout'));
    deficit:=greatest(1-eligible_waiting,0); keep_loser_current:=rotate_loser and deficit>=1; keep_winner_current:=not winner_stays and deficit>=1;
  end if;
  if rotate_loser then
    update public.king_teams set status=case when keep_loser_current then 'current' else 'waiting' end,queue_position=case when keep_loser_current then 0 else next_pos end,court_number=case when keep_loser_current then p_court_number else null end,court_side=case when keep_loser_current then loser.court_side else null end,consecutive_wins=0,rejoin_expires_at=case when rejoin_mode then expiry else null end,updated_at=now() where id=loser.id;
    if rejoin_mode then update public.waitlist_players set status='rejoin',court_number=null,rejoin_expires_at=expiry,updated_at=now() where team_id=loser.id and status<>'left';
    else update public.waitlist_players set status='waiting',court_number=null,rejoin_expires_at=null,updated_at=now() where team_id=loser.id and status<>'left'; end if;
  else
    update public.king_teams set status='current',queue_position=0,court_number=p_court_number,court_side=loser.court_side,consecutive_wins=0,rejoin_expires_at=null,updated_at=now() where id=loser.id;
    update public.waitlist_players set status='current',court_number=p_court_number,rejoin_expires_at=null,updated_at=now() where team_id=loser.id and status<>'left';
  end if;
  if winner_stays then update public.king_teams set consecutive_wins=consecutive_wins+1,updated_at=now() where id=winner.id;
  else
    update public.king_teams set status=case when keep_winner_current then 'current' else 'waiting' end,queue_position=case when keep_winner_current then 0 else next_pos+case when rotate_loser then 1 else 0 end end,court_number=case when keep_winner_current then p_court_number else null end,court_side=case when keep_winner_current then winner.court_side else null end,consecutive_wins=0,rejoin_expires_at=case when rejoin_mode then expiry else null end,updated_at=now() where id=winner.id;
    if rejoin_mode then update public.waitlist_players set status='rejoin',court_number=null,rejoin_expires_at=expiry,updated_at=now() where team_id=winner.id and status<>'left';
    else update public.waitlist_players set status='waiting',court_number=null,rejoin_expires_at=null,updated_at=now() where team_id=winner.id and status<>'left'; end if;
  end if;
  if rejoin_mode then
    for rec in insert into public.rejoin_responses(user_id,game_number,original_position,expires_at) select p.user_id,next_game,p.queue_position,expiry from public.waitlist_players p where p.status='rejoin' and p.rejoin_expires_at=expiry and p.user_id is not null returning id,user_id
    loop prompts:=prompts||jsonb_build_array(jsonb_build_object('id',rec.id,'user_id',rec.user_id)); end loop;
  end if;
  update public.waitlist_config set game_number=next_game,updated_at=now() where id;
  update public.waitlist_courts set game_number=next_game,started_at=now() where court_number=p_court_number;
  insert into public.king_round_history(court_number,game_number,winning_team_id,winning_team_name,losing_team_name,snapshot,actor_user_id) values(p_court_number,court.game_number,winner.id,public.king_team_label(winner.id),public.king_team_label(loser.id),snap,auth.uid());
  perform public.king_compact_queue(); perform public.king_fill_courts();
  insert into public.waitlist_events(actor_user_id,actor_name,event_type,message) values(auth.uid(),coalesce(caller.display_name,'Admin'),'king_game',public.king_team_label(winner.id)||' won Game '||court.game_number||' on Court '||p_court_number||'.');
  return jsonb_build_object('message','Advancement complete.','game_number',next_game,'winner',public.king_team_label(winner.id),'winner_stays',winner_stays,'rejoin_prompts',prompts);
end; $$;
grant execute on function public.end_team_king_game(integer,uuid) to authenticated;
