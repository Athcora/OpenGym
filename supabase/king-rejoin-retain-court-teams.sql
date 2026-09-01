-- Keep rejoin-reserved team cards on their court when the shared waitlist has
-- too few active teams to replace every rotating team.
create or replace function public.end_team_king_game(p_court_number integer,p_winning_team_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare cfg public.waitlist_config; court public.waitlist_courts; winner public.king_teams; loser public.king_teams;
  caller public.waitlist_players; next_pos bigint; next_game integer; winner_stays boolean; snap jsonb;
  prompts jsonb:='[]'::jsonb; expiry timestamptz:=now()+interval '5 minutes'; rec record;
  eligible_waiting integer:=0; vacancies integer:=0; deficit integer:=0;
  keep_loser_current boolean:=false; keep_winner_current boolean:=false;
begin
  perform pg_advisory_xact_lock(7429202);
  select * into cfg from public.waitlist_config where id for update;
  if cfg.mode<>'teams' then raise exception 'King of the Court is only available in Teams Mode.'; end if;
  select * into court from public.waitlist_courts where court_number=p_court_number for update;
  if court.team_mode not in('king','king_rejoin') then raise exception 'This court is using 2 on, 2 off.'; end if;
  select * into winner from public.king_teams where id=p_winning_team_id and status='current' and court_number=p_court_number for update;
  select * into loser from public.king_teams where status='current' and court_number=p_court_number and id<>p_winning_team_id order by court_side limit 1 for update;
  if winner.id is null or loser.id is null then raise exception 'Two active teams are required on this court.'; end if;
  select * into caller from public.waitlist_players where user_id=auth.uid();
  if not public.is_waitlist_operator() and (caller.id is null or caller.team_id not in(winner.id,loser.id) or caller.restricted) then
    raise exception 'Only a player on this court or an admin/host can record the winner.';
  end if;
  snap:=jsonb_build_object(
    'teams',(select jsonb_agg(to_jsonb(t) order by t.created_at) from public.king_teams t),
    'players',(select jsonb_agg(jsonb_build_object('id',p.id,'status',p.status,'court_number',p.court_number,'team_id',p.team_id,'queue_position',p.queue_position,'rejoin_expires_at',p.rejoin_expires_at)) from public.waitlist_players p),
    'court',to_jsonb(court),'config_game_number',cfg.game_number);
  insert into public.past_games(game_number,court_number,player_names)
    select court.game_number,p_court_number,coalesce(jsonb_agg(p.display_name order by t.court_side,p.queue_position,p.created_at),'[]'::jsonb)
    from public.king_teams t left join public.waitlist_players p on p.team_id=t.id and p.status<>'left'
    where t.id in(winner.id,loser.id);
  next_game:=greatest(cfg.game_number,(select coalesce(max(game_number),0) from public.waitlist_courts),(select coalesce(max(game_number),0) from public.past_games))+1;
  select coalesce(max(queue_position),0)+1 into next_pos from public.king_teams where status='waiting';
  winner_stays:=court.team_max_wins is null or winner.consecutive_wins+1<court.team_max_wins;

  if court.team_mode='king_rejoin' then
    select count(*) into eligible_waiting from public.king_teams t
      where t.status='waiting' and exists(
        select 1 from public.waitlist_players p
        where p.team_id=t.id and p.status in('waiting','current','sitout'));
    vacancies:=case when winner_stays then 1 else 2 end;
    deficit:=greatest(vacancies-eligible_waiting,0);
    keep_loser_current:=deficit>=1;
    keep_winner_current:=not winner_stays and deficit>=2;
  end if;

  update public.king_teams set
    status=case when keep_loser_current then 'current' else 'waiting' end,
    queue_position=case when keep_loser_current then 0 else next_pos end,
    court_number=case when keep_loser_current then p_court_number else null end,
    court_side=case when keep_loser_current then loser.court_side else null end,
    consecutive_wins=0,
    rejoin_expires_at=case when court.team_mode='king_rejoin' then expiry else null end,
    updated_at=now() where id=loser.id;
  if court.team_mode='king_rejoin' then
    update public.waitlist_players set status='rejoin',court_number=null,rejoin_expires_at=expiry,updated_at=now()
      where team_id=loser.id and status<>'left';
  else
    update public.waitlist_players set status='waiting',court_number=null,updated_at=now() where team_id=loser.id and status<>'left';
  end if;

  if winner_stays then
    update public.king_teams set consecutive_wins=consecutive_wins+1,updated_at=now() where id=winner.id;
  else
    update public.king_teams set
      status=case when keep_winner_current then 'current' else 'waiting' end,
      queue_position=case when keep_winner_current then 0 else next_pos+1 end,
      court_number=case when keep_winner_current then p_court_number else null end,
      court_side=case when keep_winner_current then winner.court_side else null end,
      consecutive_wins=0,
      rejoin_expires_at=case when court.team_mode='king_rejoin' then expiry else null end,
      updated_at=now() where id=winner.id;
    if court.team_mode='king_rejoin' then
      update public.waitlist_players set status='rejoin',court_number=null,rejoin_expires_at=expiry,updated_at=now()
        where team_id=winner.id and status<>'left';
    else
      update public.waitlist_players set status='waiting',court_number=null,updated_at=now() where team_id=winner.id and status<>'left';
    end if;
  end if;
  if court.team_mode='king_rejoin' then
    for rec in
      insert into public.rejoin_responses(user_id,game_number,original_position,expires_at)
      select p.user_id,next_game,p.queue_position,p.rejoin_expires_at from public.waitlist_players p
      where p.status='rejoin' and p.rejoin_expires_at=expiry and p.user_id is not null
      returning id,user_id
    loop prompts:=prompts||jsonb_build_array(jsonb_build_object('id',rec.id,'user_id',rec.user_id)); end loop;
  end if;
  update public.waitlist_config set game_number=next_game,updated_at=now() where id;
  update public.waitlist_courts set game_number=next_game,started_at=now() where court_number=p_court_number;
  insert into public.king_round_history(court_number,game_number,winning_team_id,winning_team_name,losing_team_name,snapshot,actor_user_id)
    values(p_court_number,court.game_number,winner.id,public.king_team_label(winner.id),public.king_team_label(loser.id),snap,auth.uid());
  perform public.king_compact_queue(); perform public.king_fill_courts();
  insert into public.waitlist_events(actor_user_id,actor_name,event_type,message)
    values(auth.uid(),coalesce(caller.display_name,'Admin'),'king_game',public.king_team_label(winner.id)||' won Game '||court.game_number||' on Court '||p_court_number||'.');
  return jsonb_build_object('message','Advancement complete.','game_number',next_game,'winner',public.king_team_label(winner.id),'winner_stays',winner_stays,'rejoin_prompts',prompts);
end; $$;
grant execute on function public.end_team_king_game(integer,uuid) to authenticated;
