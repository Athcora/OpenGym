-- Per-court rules for Teams Mode: 2 on/2 off or King of the Court.
alter table public.waitlist_courts add column if not exists team_mode text not null default 'rotation';
alter table public.waitlist_courts add column if not exists team_max_wins integer default 2;

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

create or replace function public.join_king_team(p_player_id uuid,p_team_id uuid default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare player public.waitlist_players; target public.king_teams; old_team uuid; member_count integer; next_pos bigint; next_no integer;
begin
  perform pg_advisory_xact_lock(7429201);
  select * into player from public.waitlist_players where id=p_player_id for update;
  if player.id is null or (player.user_id<>auth.uid() and not public.is_waitlist_operator()) then raise exception 'You cannot move that player.'; end if;
  old_team:=player.team_id;
  if p_team_id is null then
    select coalesce(max(queue_position),0)+1 into next_pos from public.king_teams where status='waiting';
    select coalesce(max((regexp_match(name,'[0-9]+'))[1]::integer),0)+1 into next_no from public.king_teams;
    insert into public.king_teams(name,queue_position) values('Team '||next_no,next_pos) returning * into target;
  else
    select * into target from public.king_teams where id=p_team_id for update;
    if target.id is null then raise exception 'That team is unavailable.'; end if;
    select count(*) into member_count from public.waitlist_players where team_id=target.id and status<>'left';
    if member_count>=6 then raise exception 'That team is full.'; end if;
  end if;
  update public.waitlist_players set team_id=target.id,status=target.status,
    court_number=target.court_number,updated_at=now() where id=player.id;
  if old_team is not null and old_team<>target.id and not exists(select 1 from public.waitlist_players where team_id=old_team and status<>'left') then
    delete from public.king_teams where id=old_team;
  end if;
  perform public.king_fill_courts();
  return jsonb_build_object('message','You joined '||public.king_team_label(target.id)||'.','team_id',target.id);
end; $$;
grant execute on function public.join_king_team(uuid,uuid) to authenticated;

create or replace function public.end_team_rotation(p_court_number integer)
returns jsonb language plpgsql security definer set search_path=public as $$
declare cfg public.waitlist_config; court public.waitlist_courts; caller public.waitlist_players;
  first_team public.king_teams; second_team public.king_teams; next_pos bigint; next_game integer; snap jsonb;
begin
  perform pg_advisory_xact_lock(7429202);
  select * into cfg from public.waitlist_config where id for update;
  if cfg.mode<>'teams' then raise exception 'Team rotation is only available in Teams Mode.'; end if;
  select * into court from public.waitlist_courts where court_number=p_court_number for update;
  if court.team_mode<>'rotation' then raise exception 'This court is using King of the Court.'; end if;
  select * into first_team from public.king_teams where status='current' and court_number=p_court_number and court_side=1 for update;
  select * into second_team from public.king_teams where status='current' and court_number=p_court_number and court_side=2 for update;
  if first_team.id is null or second_team.id is null then raise exception 'Two active teams are required on this court.'; end if;
  select * into caller from public.waitlist_players where user_id=auth.uid();
  if not public.is_waitlist_operator() and (caller.id is null or caller.team_id not in(first_team.id,second_team.id) or caller.restricted) then
    raise exception 'Only a player on this court or an admin/host can advance the game.';
  end if;
  snap:=jsonb_build_object(
    'teams',(select jsonb_agg(to_jsonb(t) order by t.created_at) from public.king_teams t),
    'players',(select jsonb_agg(jsonb_build_object('id',p.id,'status',p.status,'court_number',p.court_number,'team_id',p.team_id)) from public.waitlist_players p),
    'court',to_jsonb(court),'config_game_number',cfg.game_number
  );
  insert into public.past_games(game_number,court_number,player_names)
    select court.game_number,p_court_number,coalesce(jsonb_agg(p.display_name order by t.court_side,p.created_at),'[]'::jsonb)
    from public.king_teams t left join public.waitlist_players p on p.team_id=t.id and p.status<>'left'
    where t.id in(first_team.id,second_team.id);
  select coalesce(max(queue_position),0)+1 into next_pos from public.king_teams where status='waiting';
  update public.king_teams set status='waiting',queue_position=next_pos,court_number=null,court_side=null,consecutive_wins=0,updated_at=now() where id=first_team.id;
  update public.king_teams set status='waiting',queue_position=next_pos+1,court_number=null,court_side=null,consecutive_wins=0,updated_at=now() where id=second_team.id;
  update public.waitlist_players set status='waiting',court_number=null,updated_at=now() where team_id in(first_team.id,second_team.id) and status<>'left';
  next_game:=greatest(cfg.game_number,(select coalesce(max(game_number),0) from public.waitlist_courts),(select coalesce(max(game_number),0) from public.past_games))+1;
  update public.waitlist_config set game_number=next_game,updated_at=now() where id;
  update public.waitlist_courts set game_number=next_game,started_at=now() where court_number=p_court_number;
  insert into public.king_round_history(court_number,game_number,winning_team_id,winning_team_name,losing_team_name,snapshot,actor_user_id)
    values(p_court_number,court.game_number,first_team.id,'2 on, 2 off','Both teams rotated',snap,auth.uid());
  perform public.king_compact_queue();
  perform public.king_fill_courts();
  insert into public.waitlist_events(actor_user_id,actor_name,event_type,message)
    values(auth.uid(),coalesce(caller.display_name,'Admin'),'team_rotation','Game '||court.game_number||' ended on Court '||p_court_number||'. Both teams rotated.');
  return jsonb_build_object('message','Both teams rotated out and the next two teams entered.','game_number',next_game);
end; $$;
grant execute on function public.end_team_rotation(integer) to authenticated;

-- King of the Court uses the selected court's own consecutive-game limit.
create or replace function public.end_team_king_game(p_court_number integer,p_winning_team_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare cfg public.waitlist_config; court public.waitlist_courts; winner public.king_teams; loser public.king_teams;
  caller public.waitlist_players; next_pos bigint; next_game integer; winner_stays boolean; snap jsonb;
begin
  perform pg_advisory_xact_lock(7429202);
  select * into cfg from public.waitlist_config where id for update;
  if cfg.mode<>'teams' then raise exception 'King of the Court is only available in Teams Mode.'; end if;
  select * into court from public.waitlist_courts where court_number=p_court_number for update;
  if court.team_mode<>'king' then raise exception 'This court is using 2 on, 2 off.'; end if;
  select * into winner from public.king_teams where id=p_winning_team_id and status='current' and court_number=p_court_number for update;
  select * into loser from public.king_teams where status='current' and court_number=p_court_number and id<>p_winning_team_id order by court_side limit 1 for update;
  if winner.id is null or loser.id is null then raise exception 'Two active teams are required on this court.'; end if;
  select * into caller from public.waitlist_players where user_id=auth.uid();
  if not public.is_waitlist_operator() and (caller.id is null or caller.team_id not in(winner.id,loser.id) or caller.restricted) then
    raise exception 'Only a player on this court or an admin/host can record the winner.';
  end if;
  snap:=jsonb_build_object(
    'teams',(select jsonb_agg(to_jsonb(t) order by t.created_at) from public.king_teams t),
    'players',(select jsonb_agg(jsonb_build_object('id',p.id,'status',p.status,'court_number',p.court_number,'team_id',p.team_id)) from public.waitlist_players p),
    'court',to_jsonb(court),'config_game_number',cfg.game_number
  );
  insert into public.past_games(game_number,court_number,player_names)
    select court.game_number,p_court_number,coalesce(jsonb_agg(p.display_name order by t.court_side,p.created_at),'[]'::jsonb)
    from public.king_teams t left join public.waitlist_players p on p.team_id=t.id and p.status<>'left'
    where t.id in(winner.id,loser.id);
  select coalesce(max(queue_position),0)+1 into next_pos from public.king_teams where status='waiting';
  update public.king_teams set status='waiting',queue_position=next_pos,court_number=null,court_side=null,consecutive_wins=0,updated_at=now() where id=loser.id;
  update public.waitlist_players set status='waiting',court_number=null,updated_at=now() where team_id=loser.id and status<>'left';
  winner_stays:=court.team_max_wins is null or winner.consecutive_wins+1<court.team_max_wins;
  if winner_stays then
    update public.king_teams set consecutive_wins=consecutive_wins+1,updated_at=now() where id=winner.id;
  else
    update public.king_teams set status='waiting',queue_position=next_pos+1,court_number=null,court_side=null,consecutive_wins=0,updated_at=now() where id=winner.id;
    update public.waitlist_players set status='waiting',court_number=null,updated_at=now() where team_id=winner.id and status<>'left';
  end if;
  next_game:=greatest(cfg.game_number,(select coalesce(max(game_number),0) from public.waitlist_courts),(select coalesce(max(game_number),0) from public.past_games))+1;
  update public.waitlist_config set game_number=next_game,updated_at=now() where id;
  update public.waitlist_courts set game_number=next_game,started_at=now() where court_number=p_court_number;
  insert into public.king_round_history(court_number,game_number,winning_team_id,winning_team_name,losing_team_name,snapshot,actor_user_id)
    values(p_court_number,court.game_number,winner.id,public.king_team_label(winner.id),public.king_team_label(loser.id),snap,auth.uid());
  perform public.king_compact_queue();
  perform public.king_fill_courts();
  insert into public.waitlist_events(actor_user_id,actor_name,event_type,message)
    values(auth.uid(),coalesce(caller.display_name,'Admin'),'king_game',public.king_team_label(winner.id)||' won Game '||court.game_number||' on Court '||p_court_number||'.');
  return jsonb_build_object('message','Advancement complete.','game_number',next_game,'winner',public.king_team_label(winner.id),'winner_stays',winner_stays);
end; $$;
grant execute on function public.end_team_king_game(integer,uuid) to authenticated;

-- Remove stale empty teams left by earlier Teams Mode builds, then refill courts.
delete from public.king_teams t
where not exists(select 1 from public.waitlist_players p where p.team_id=t.id and p.status<>'left');
select public.king_fill_courts();
