-- Per-court King of the Court variant whose rotating players must rejoin.
alter table public.king_teams add column if not exists rejoin_expires_at timestamptz;

create or replace function public.set_team_court_rules(p_court_number integer,p_team_mode text,p_max_wins integer default 2)
returns jsonb language plpgsql security definer set search_path=public as $$
begin
  if not public.is_waitlist_operator() then raise exception 'Admin or host access required.'; end if;
  if p_team_mode not in('rotation','king','king_rejoin') then raise exception 'Choose 2 on, 2 off, King of the Court, or King of the Court (Rejoin).'; end if;
  if p_team_mode in('king','king_rejoin') and p_max_wins is not null and p_max_wins not in(2,3) then raise exception 'Choose 2, 3, or Unlimited consecutive games.'; end if;
  update public.waitlist_courts set team_mode=p_team_mode,
    team_max_wins=case when p_team_mode='rotation' then 2 else p_max_wins end
    where court_number=p_court_number;
  return jsonb_build_object('message','Court rules updated.');
end; $$;
grant execute on function public.set_team_court_rules(integer,text,integer) to authenticated;

create or replace function public.king_fill_courts()
returns void language plpgsql security definer set search_path=public as $$
declare c record; side_no integer; next_team uuid;
begin
  for c in select court_number from public.waitlist_courts order by court_number loop
    for side_no in 1..2 loop
      if not exists(select 1 from public.king_teams where status='current' and court_number=c.court_number and court_side=side_no) then
        select t.id into next_team from public.king_teams t
        where t.status='waiting' and exists(
          select 1 from public.waitlist_players p where p.team_id=t.id and p.status in('waiting','current','sitout')
        ) order by t.queue_position,t.created_at limit 1 for update skip locked;
        if next_team is not null then
          update public.king_teams set status='current',court_number=c.court_number,court_side=side_no,
            queue_position=0,consecutive_wins=0,updated_at=now() where id=next_team;
          update public.waitlist_players set status='current',court_number=c.court_number,updated_at=now()
            where team_id=next_team and status in('waiting','current','sitout');
        end if;
        next_team:=null;
      end if;
    end loop;
  end loop;
  perform public.king_compact_queue();
end; $$;

create or replace function public.cleanup_king_rejoin_expirations()
returns jsonb language plpgsql security definer set search_path=public as $$
begin
  update public.rejoin_responses set choice='leave',answered_at=now()
    where choice is null and expires_at<=now();
  update public.waitlist_players set status='left',queue_position=null,team_id=null,court_number=null,
    rejoin_expires_at=null,updated_at=now() where status='rejoin' and rejoin_expires_at<=now();
  update public.king_teams t set rejoin_expires_at=null,updated_at=now()
    where rejoin_expires_at is not null and exists(
      select 1 from public.waitlist_players p where p.team_id=t.id and p.status in('waiting','current','sitout'));
  delete from public.king_teams t where t.rejoin_expires_at<=now()
    and not exists(select 1 from public.waitlist_players p where p.team_id=t.id and p.status in('waiting','current','sitout'));
  perform public.king_compact_queue();
  perform public.king_fill_courts();
  return jsonb_build_object('message','Expired team rejoin reservations cleared.');
end; $$;
grant execute on function public.cleanup_king_rejoin_expirations() to authenticated;

create or replace function public.end_team_king_game(p_court_number integer,p_winning_team_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare cfg public.waitlist_config; court public.waitlist_courts; winner public.king_teams; loser public.king_teams;
  caller public.waitlist_players; next_pos bigint; next_game integer; winner_stays boolean; snap jsonb;
  prompts jsonb:='[]'::jsonb; expiry timestamptz:=now()+interval '5 minutes'; rec record;
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
  update public.king_teams set status='waiting',queue_position=next_pos,court_number=null,court_side=null,consecutive_wins=0,
    rejoin_expires_at=case when court.team_mode='king_rejoin' then expiry else null end,updated_at=now() where id=loser.id;
  if court.team_mode='king_rejoin' then
    update public.waitlist_players set status='rejoin',court_number=null,rejoin_expires_at=expiry,updated_at=now()
      where team_id=loser.id and status<>'left';
  else
    update public.waitlist_players set status='waiting',court_number=null,updated_at=now() where team_id=loser.id and status<>'left';
  end if;
  if winner_stays then
    update public.king_teams set consecutive_wins=consecutive_wins+1,updated_at=now() where id=winner.id;
  else
    update public.king_teams set status='waiting',queue_position=next_pos+1,court_number=null,court_side=null,consecutive_wins=0,
      rejoin_expires_at=case when court.team_mode='king_rejoin' then expiry else null end,updated_at=now() where id=winner.id;
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

create or replace function public.answer_rejoin_prompt(p_response_id uuid,p_choice text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare prompt public.rejoin_responses; player public.waitlist_players; team public.king_teams;
  config public.waitlist_config; open_slots integer; joined_current boolean;
begin
  perform pg_advisory_xact_lock(7429101);
  if p_choice not in('stay','leave') then raise exception 'Choose rejoin or leave.'; end if;
  select * into prompt from public.rejoin_responses where id=p_response_id and user_id=auth.uid() for update;
  select * into player from public.waitlist_players where user_id=auth.uid() for update;
  if prompt.id is null or player.id is null then raise exception 'Rejoin request not found.'; end if;
  if prompt.choice is not null then raise exception 'This rejoin request was already answered.'; end if;
  if prompt.expires_at<=now() then p_choice:='leave'; end if;
  update public.rejoin_responses set choice=p_choice,answered_at=now() where id=prompt.id;
  if p_choice='leave' then
    update public.waitlist_players set status='left',queue_position=null,team_id=null,court_number=null,rejoin_expires_at=null,updated_at=now() where id=player.id;
    perform public.cleanup_king_rejoin_expirations();
    return jsonb_build_object('message','You left the waitlist.');
  end if;
  if player.team_id is not null and exists(select 1 from public.king_teams where id=player.team_id) then
    select * into team from public.king_teams where id=player.team_id for update;
    update public.king_teams set rejoin_expires_at=null,updated_at=now() where id=team.id;
    update public.waitlist_players set status=team.status,court_number=team.court_number,rejoin_expires_at=null,updated_at=now() where id=player.id;
    perform public.king_fill_courts();
    select * into team from public.king_teams where id=player.team_id;
    update public.waitlist_players set status=team.status,court_number=team.court_number,updated_at=now() where id=player.id;
    return jsonb_build_object('message','You rejoined your team in its saved position.');
  end if;
  update public.waitlist_players set status='waiting',queue_position=prompt.original_position,rejoin_expires_at=null,updated_at=now() where id=player.id;
  select * into config from public.waitlist_config where id for update;
  select greatest(config.max_players-count(*),0) into open_slots from public.waitlist_players where status='current';
  with chosen as(select id from public.waitlist_players where status='waiting' order by queue_position limit open_slots)
    update public.waitlist_players set status='current',updated_at=now() where id in(select id from chosen);
  select exists(select 1 from public.waitlist_players where id=player.id and status='current') into joined_current;
  return jsonb_build_object('message',case when joined_current then 'You rejoined the current game.' else 'You kept your saved position in line.' end);
end; $$;
grant execute on function public.answer_rejoin_prompt(uuid,text) to authenticated;

create or replace function public.clear_king_team_rejoin_timer()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  if new.team_id is not null and new.status in('waiting','current','sitout') then
    update public.king_teams set rejoin_expires_at=null,updated_at=now() where id=new.team_id and rejoin_expires_at is not null;
  end if;
  return new;
end; $$;
drop trigger if exists clear_king_team_rejoin_timer on public.waitlist_players;
create trigger clear_king_team_rejoin_timer after insert or update of team_id,status on public.waitlist_players
for each row execute function public.clear_king_team_rejoin_timer();
