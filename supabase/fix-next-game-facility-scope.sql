-- Every Next Game path must affect exactly one facility and each live court
-- may contain at most max_players.  Runtime functions use an elevated role,
-- so this explicit facility predicate is required in addition to RLS.

create or replace function public.repair_facility_court_assignments(p_facility_id uuid default public.current_facility_id())
returns void language plpgsql security definer set search_path=public as $$
declare cfg public.waitlist_config;
begin
  select * into cfg from public.waitlist_config
    where facility_id=p_facility_id and id for update;
  if cfg.id is null then return; end if;

  -- A current player without an active court is not playing.  Return them to
  -- the shared queue instead of rendering them on Court 1 by fallback.
  update public.waitlist_players p set status='waiting',court_number=null,updated_at=now()
  where p.facility_id=p_facility_id and p.status='current' and (
    p.court_number is null or not exists(
      select 1 from public.waitlist_courts c
      where c.facility_id=p_facility_id and c.court_number=p.court_number));

  -- Keep the oldest max_players on every court and return only overflow to
  -- the shared queue.  This also heals legacy overfilled games safely.
  with ranked as(
    select p.id,row_number() over(partition by p.court_number order by p.queue_position,p.created_at,p.id) as rn
    from public.waitlist_players p
    where p.facility_id=p_facility_id and p.status='current' and p.court_number is not null
  )
  update public.waitlist_players p set status='waiting',court_number=null,updated_at=now()
  from ranked r where p.id=r.id and r.rn>cfg.max_players;

  perform public.fill_open_court_slots();
end;
$$;

create or replace function public.end_court_game(p_court_number integer)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  reversal_before jsonb; caller public.waitlist_players; cfg public.waitlist_config;
  court public.waitlist_courts; next_game integer; actor text;
  response_rows jsonb:='[]'::jsonb; last_position bigint; fid uuid:=public.current_facility_id();
begin
  perform pg_advisory_xact_lock(7429101);
  perform public.repair_facility_court_assignments(fid);
  select * into cfg from public.waitlist_config where facility_id=fid and id for update;
  reversal_before:=public.capture_court_reversal_state();
  select * into court from public.waitlist_courts
    where facility_id=fid and court_number=p_court_number for update;
  if court.court_number is null then raise exception 'That court is not active.'; end if;
  select * into caller from public.waitlist_players where facility_id=fid and user_id=auth.uid();
  if not public.is_waitlist_operator() and(
    caller.id is null or caller.status<>'current' or caller.court_number<>p_court_number or caller.restricted
  ) then raise exception 'Only an unrestricted player on this court or an admin/host can start its next game.'; end if;
  perform public.save_admin_undo('start next game');
  insert into public.past_games(facility_id,game_number,player_names,court_number)
    select fid,court.game_number,coalesce(jsonb_agg(display_name order by queue_position),'[]'::jsonb),p_court_number
    from public.waitlist_players
    where facility_id=fid and status='current' and court_number=p_court_number
    on conflict(facility_id,game_number) do nothing;
  select coalesce(max(queue_position),0) into last_position from public.waitlist_players
    where facility_id=fid and status in('current','waiting','sitout','rejoin');
  with finished as(
    select id,row_number()over(order by queue_position,id) rn from public.waitlist_players
    where facility_id=fid and status='current' and court_number=p_court_number
  ) update public.waitlist_players p set queue_position=last_position+finished.rn,court_number=null,updated_at=now()
    from finished where p.id=finished.id;
  if cfg.mode='rejoin' then
    update public.waitlist_players set status='rejoin',rejoin_expires_at=now()+case when user_id is null then interval '15 minutes' else interval '5 minutes' end
      where facility_id=fid and status='current' and court_number is null and queue_position>last_position;
    with changed as(
      select * from public.waitlist_players where facility_id=fid and status='rejoin'
        and queue_position>last_position and user_id is not null
    ), ins as(
      insert into public.rejoin_responses(facility_id,user_id,game_number,original_position,expires_at)
      select fid,user_id,court.game_number+1,queue_position,rejoin_expires_at from changed
      returning id,user_id
    ) select coalesce(jsonb_agg(jsonb_build_object('user_id',user_id,'response_id',id)),'[]'::jsonb) into response_rows from ins;
  else
    update public.waitlist_players set status='waiting'
      where facility_id=fid and status='current' and court_number is null and queue_position>last_position;
  end if;
  update public.waitlist_players set status='waiting',sitout_from_game=null,updated_at=now()
    where facility_id=fid and status='sitout' and sitout_from_game<=court.game_number;
  next_game:=greatest(
    (select coalesce(max(game_number),0) from public.waitlist_courts where facility_id=fid),
    (select coalesce(max(game_number),0) from public.past_games where facility_id=fid)
  )+1;
  update public.waitlist_courts set game_number=next_game,started_at=now()
    where facility_id=fid and court_number=p_court_number;
  update public.waitlist_config set game_number=next_game,updated_at=now() where facility_id=fid and id;
  perform public.fill_open_court_slots();
  actor:=coalesce(caller.display_name,'Admin');
  insert into public.waitlist_events(facility_id,actor_user_id,actor_name,event_type,message)
    values(fid,auth.uid(),actor,'next_game',actor||' started Game '||next_game||' on Court '||p_court_number||'.');
  perform public.record_court_reversal(reversal_before,p_court_number);
  return jsonb_build_object('message','Game '||next_game||' started on Court '||p_court_number||'.','game_number',next_game,'court_number',p_court_number,'rejoin_prompts',response_rows);
end;
$$;

create or replace function public.king_team_label(p_id uuid)
returns text language sql stable security definer set search_path=public as $$
  select coalesce(nullif(string_agg(p.display_name,' + ' order by p.queue_position,p.created_at),''),t.name)
  from public.king_teams t left join public.waitlist_players p
    on p.facility_id=t.facility_id and p.team_id=t.id and p.status<>'left'
  where t.facility_id=public.current_facility_id() and t.id=p_id group by t.name;
$$;

create or replace function public.king_compact_queue()
returns void language plpgsql security definer set search_path=public as $$
declare fid uuid:=public.current_facility_id();
begin
  with ranked as(
    select id,row_number()over(order by queue_position,created_at,id) rn
    from public.king_teams where facility_id=fid and status='waiting'
  ) update public.king_teams t set queue_position=r.rn,updated_at=now() from ranked r
    where t.facility_id=fid and t.id=r.id;
end;
$$;

create or replace function public.king_fill_courts()
returns void language plpgsql security definer set search_path=public as $$
declare c record; side_no integer; next_team uuid; fid uuid:=public.current_facility_id();
begin
  for c in select court_number from public.waitlist_courts where facility_id=fid order by court_number loop
    for side_no in 1..2 loop
      if not exists(select 1 from public.king_teams where facility_id=fid and status='current' and court_number=c.court_number and court_side=side_no) then
        select t.id into next_team from public.king_teams t where t.facility_id=fid and t.status='waiting'
          and exists(select 1 from public.waitlist_players p where p.facility_id=fid and p.team_id=t.id and p.status<>'left')
          order by t.queue_position,t.created_at,t.id limit 1 for update skip locked;
        if next_team is not null then
          update public.king_teams set status='current',court_number=c.court_number,court_side=side_no,
            queue_position=0,consecutive_wins=0,updated_at=now() where facility_id=fid and id=next_team;
          update public.waitlist_players set status='current',court_number=c.court_number,updated_at=now()
            where facility_id=fid and team_id=next_team and status<>'left';
        end if;
        next_team:=null;
      end if;
    end loop;
  end loop;
  perform public.king_compact_queue();
end;
$$;

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
  if cfg.mode='teams_rejoin' then
    select count(*) into eligible_waiting from public.king_teams t where t.facility_id=fid and t.status='waiting' and exists(select 1 from public.waitlist_players p where p.facility_id=fid and p.team_id=t.id and p.status in('waiting','current','sitout'));
    deficit:=greatest(2-eligible_waiting,0); keep_second:=deficit>=1; keep_first:=deficit>=2;
  end if;
  update public.king_teams set status=case when keep_first then 'current' else 'waiting' end,queue_position=case when keep_first then 0 else next_pos end,court_number=case when keep_first then p_court_number else null end,court_side=case when keep_first then 1 else null end,consecutive_wins=0,rejoin_expires_at=case when cfg.mode='teams_rejoin' then expiry else null end,updated_at=now() where facility_id=fid and id=first_team.id;
  update public.king_teams set status=case when keep_second then 'current' else 'waiting' end,queue_position=case when keep_second then 0 else next_pos+1 end,court_number=case when keep_second then p_court_number else null end,court_side=case when keep_second then 2 else null end,consecutive_wins=0,rejoin_expires_at=case when cfg.mode='teams_rejoin' then expiry else null end,updated_at=now() where facility_id=fid and id=second_team.id;
  if cfg.mode='teams_rejoin' then
    update public.waitlist_players set status='rejoin',court_number=null,rejoin_expires_at=expiry,updated_at=now() where facility_id=fid and team_id in(first_team.id,second_team.id) and status<>'left';
  else update public.waitlist_players set status='waiting',court_number=null,rejoin_expires_at=null,updated_at=now() where facility_id=fid and team_id in(first_team.id,second_team.id) and status<>'left'; end if;
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

create or replace function public.end_team_king_game(p_court_number integer,p_winning_team_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare cfg public.waitlist_config; court public.waitlist_courts; winner public.king_teams; loser public.king_teams;
  caller public.waitlist_players; next_pos bigint; next_game integer; winner_stays boolean; snap jsonb;
  prompts jsonb:='[]'::jsonb; expiry timestamptz:=now()+interval '5 minutes'; rec record; rejoin_mode boolean:=false;
  eligible_waiting integer:=0; deficit integer:=0; keep_loser_current boolean:=false; keep_winner_current boolean:=false; rotate_loser boolean:=true;
  reversal_before jsonb; fid uuid:=public.current_facility_id();
begin
  perform pg_advisory_xact_lock(7429202);
  select * into cfg from public.waitlist_config where facility_id=fid and id for update; reversal_before:=public.capture_court_reversal_state(); rejoin_mode:=cfg.mode='teams_rejoin';
  if cfg.mode not in('teams','teams_rejoin') then raise exception 'King of the Court is only available in Teams Mode.'; end if;
  select * into court from public.waitlist_courts where facility_id=fid and court_number=p_court_number for update;
  if court.team_mode<>'king' then raise exception 'This court is using 2 on, 2 off.'; end if;
  select * into winner from public.king_teams where facility_id=fid and id=p_winning_team_id and status='current' and court_number=p_court_number for update;
  select * into loser from public.king_teams where facility_id=fid and status='current' and court_number=p_court_number and id<>p_winning_team_id order by court_side limit 1 for update;
  if winner.id is null or loser.id is null then raise exception 'Two active teams are required on this court.'; end if;
  select * into caller from public.waitlist_players where facility_id=fid and user_id=auth.uid();
  if not public.is_waitlist_operator() and (caller.id is null or caller.restricted or (caller.team_id not in(winner.id,loser.id) and not exists(select 1 from public.team_substitutes s where s.facility_id=fid and s.player_id=caller.id and s.team_id in(winner.id,loser.id)))) then raise exception 'Only a player on this court or an admin/host can record the winner.'; end if;
  snap:=jsonb_build_object('teams',(select jsonb_agg(to_jsonb(t) order by t.created_at) from public.king_teams t where t.facility_id=fid),'players',(select jsonb_agg(jsonb_build_object('id',p.id,'status',p.status,'court_number',p.court_number,'team_id',p.team_id,'queue_position',p.queue_position,'rejoin_expires_at',p.rejoin_expires_at)) from public.waitlist_players p where p.facility_id=fid),'court',to_jsonb(court),'config_game_number',cfg.game_number);
  insert into public.past_games(facility_id,game_number,court_number,player_names) select fid,court.game_number,p_court_number,coalesce(jsonb_agg(p.display_name order by t.court_side,p.queue_position,p.created_at),'[]'::jsonb) from public.king_teams t left join public.waitlist_players p on p.facility_id=fid and p.team_id=t.id and p.status<>'left' where t.facility_id=fid and t.id in(winner.id,loser.id) on conflict(facility_id,game_number) do nothing;
  next_game:=greatest(cfg.game_number,(select coalesce(max(game_number),0) from public.waitlist_courts where facility_id=fid),(select coalesce(max(game_number),0) from public.past_games where facility_id=fid))+1;
  select coalesce(max(queue_position),0)+1 into next_pos from public.king_teams where facility_id=fid and status='waiting';
  winner_stays:=court.team_max_wins is null or winner.consecutive_wins+1<court.team_max_wins; rotate_loser:=not rejoin_mode or winner_stays;
  if rejoin_mode then select count(*) into eligible_waiting from public.king_teams t where t.facility_id=fid and t.status='waiting' and exists(select 1 from public.waitlist_players p where p.facility_id=fid and p.team_id=t.id and p.status in('waiting','current','sitout')); deficit:=greatest(1-eligible_waiting,0); keep_loser_current:=rotate_loser and deficit>=1; keep_winner_current:=not winner_stays and deficit>=1; end if;
  if rotate_loser then
    update public.king_teams set status=case when keep_loser_current then 'current' else 'waiting' end,queue_position=case when keep_loser_current then 0 else next_pos end,court_number=case when keep_loser_current then p_court_number else null end,court_side=case when keep_loser_current then loser.court_side else null end,consecutive_wins=0,rejoin_expires_at=case when rejoin_mode then expiry else null end,updated_at=now() where facility_id=fid and id=loser.id;
    if rejoin_mode then update public.waitlist_players set status='rejoin',court_number=null,rejoin_expires_at=expiry,updated_at=now() where facility_id=fid and team_id=loser.id and status<>'left'; else update public.waitlist_players set status='waiting',court_number=null,rejoin_expires_at=null,updated_at=now() where facility_id=fid and team_id=loser.id and status<>'left'; end if;
  else
    update public.king_teams set status='current',queue_position=0,court_number=p_court_number,court_side=loser.court_side,consecutive_wins=0,rejoin_expires_at=null,updated_at=now() where facility_id=fid and id=loser.id;
    update public.waitlist_players set status='current',court_number=p_court_number,rejoin_expires_at=null,updated_at=now() where facility_id=fid and team_id=loser.id and status<>'left';
  end if;
  if winner_stays then update public.king_teams set consecutive_wins=consecutive_wins+1,updated_at=now() where facility_id=fid and id=winner.id;
  else
    update public.king_teams set status=case when keep_winner_current then 'current' else 'waiting' end,queue_position=case when keep_winner_current then 0 else next_pos+case when rotate_loser then 1 else 0 end end,court_number=case when keep_winner_current then p_court_number else null end,court_side=case when keep_winner_current then winner.court_side else null end,consecutive_wins=0,rejoin_expires_at=case when rejoin_mode then expiry else null end,updated_at=now() where facility_id=fid and id=winner.id;
    if rejoin_mode then update public.waitlist_players set status='rejoin',court_number=null,rejoin_expires_at=expiry,updated_at=now() where facility_id=fid and team_id=winner.id and status<>'left'; else update public.waitlist_players set status='waiting',court_number=null,rejoin_expires_at=null,updated_at=now() where facility_id=fid and team_id=winner.id and status<>'left'; end if;
  end if;
  if rejoin_mode then for rec in insert into public.rejoin_responses(facility_id,user_id,game_number,original_position,expires_at) select fid,p.user_id,next_game,p.queue_position,expiry from public.waitlist_players p where p.facility_id=fid and p.status='rejoin' and p.rejoin_expires_at=expiry and p.user_id is not null returning id,user_id loop prompts:=prompts||jsonb_build_array(jsonb_build_object('id',rec.id,'user_id',rec.user_id)); end loop; end if;
  update public.waitlist_config set game_number=next_game,updated_at=now() where facility_id=fid and id;
  update public.waitlist_courts set game_number=next_game,started_at=now() where facility_id=fid and court_number=p_court_number;
  insert into public.king_round_history(facility_id,court_number,game_number,winning_team_id,winning_team_name,losing_team_name,snapshot,actor_user_id) values(fid,p_court_number,court.game_number,winner.id,public.king_team_label(winner.id),public.king_team_label(loser.id),snap,auth.uid());
  perform public.king_compact_queue(); perform public.king_fill_courts();
  insert into public.waitlist_events(facility_id,actor_user_id,actor_name,event_type,message) values(fid,auth.uid(),coalesce(caller.display_name,'Admin'),'king_game',public.king_team_label(winner.id)||' won Game '||court.game_number||' on Court '||p_court_number||'.');
  perform public.record_court_reversal(reversal_before,p_court_number);
  return jsonb_build_object('message','Advancement complete.','game_number',next_game,'winner',public.king_team_label(winner.id),'winner_stays',winner_stays,'rejoin_prompts',prompts);
end;
$$;

-- Heal existing legacy rows now.  This changes only invalid active rows:
-- 12 properly assigned players remain on each court; the remainder wait.
do $$ declare f record; begin
  for f in select id from public.facilities where active loop
    perform public.repair_facility_court_assignments(f.id);
  end loop;
end $$;

grant execute on function public.repair_facility_court_assignments(uuid) to authenticated;
grant execute on function public.end_court_game(integer) to authenticated;
grant execute on function public.end_team_rotation(integer) to authenticated;
grant execute on function public.end_team_king_game(integer,uuid) to authenticated;
notify pgrst,'reload schema';
