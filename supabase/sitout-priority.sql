-- A sit-out skips exactly one game, then places the player at the front of the
-- following game's queue. The marker remains until that priority game is
-- recorded, allowing Past Games to show how the player entered that game.
alter table public.waitlist_players
  add column if not exists sitout_priority boolean not null default false,
  add column if not exists sitout_from_game integer;

drop function if exists public.sit_out_one_game();
create or replace function public.sit_out_one_game(p_skip_game integer default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare player public.waitlist_players; current_game integer; skipped_game integer;
begin
  perform pg_advisory_xact_lock(7429102);
  select * into player from public.waitlist_players
    where user_id=auth.uid() and status in('current','waiting') for update;
  if player.id is null then raise exception 'You are no longer active in the waitlist.'; end if;
  if player.status='current' and player.court_number is not null then
    select game_number into current_game from public.waitlist_courts where court_number=player.court_number;
  end if;
  if current_game is null then select game_number into current_game from public.waitlist_config where id; end if;
  skipped_game:=case when player.status='current' then current_game
    else greatest(coalesce(p_skip_game,current_game+1),current_game+1) end;
  update public.waitlist_players
    set status='sitout',sitout_priority=true,
        sitout_from_game=skipped_game,
        updated_at=now()
    where id=player.id;
  perform public.normalize_active_waitlist();
  return jsonb_build_object('message',case when player.status='current'
    then 'Leaving the current game counts as your sit-out. You have priority for the next game.'
    else 'You will skip Game '||skipped_game||' and have priority for Game '||(skipped_game+1)||'.' end,
    'skipped_game',skipped_game,'priority_game',skipped_game+1);
end;
$$;

drop function if exists public.admin_set_player_sitout(uuid);
create or replace function public.admin_set_player_sitout(p_player_id uuid,p_skip_game integer default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare player public.waitlist_players; current_game integer; skipped_game integer;
begin
  if not public.is_waitlist_operator() then raise exception 'Admin or host access required.'; end if;
  select * into player from public.waitlist_players where id=p_player_id and status in('current','waiting') for update;
  if player.id is null then raise exception 'This player is no longer active.'; end if;
  perform public.save_admin_undo('sit out player');
  if player.status='current' and player.court_number is not null then
    select game_number into current_game from public.waitlist_courts where court_number=player.court_number;
  end if;
  if current_game is null then select game_number into current_game from public.waitlist_config where id; end if;
  skipped_game:=case when player.status='current' then current_game
    else greatest(coalesce(p_skip_game,current_game+1),current_game+1) end;
  update public.waitlist_players
    set status='sitout',sitout_priority=true,
        sitout_from_game=skipped_game,
        updated_at=now()
    where id=player.id;
  perform public.normalize_active_waitlist();
  perform public.notify_waitlist_operator_player(player.user_id,'made you sit out for one game.');
  perform public.log_waitlist_operator_action('admin_sitout','sat out '||player.display_name||' for one game.');
  return jsonb_build_object('message',case when player.status='current'
    then player.display_name||' left the current game and has priority for the next game.'
    else player.display_name||' will skip Game '||skipped_game||' and have priority for Game '||(skipped_game+1)||'.' end);
end;
$$;

drop function if exists public.sit_out_and_leave_group();
create or replace function public.sit_out_and_leave_group(p_skip_game integer default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare caller public.waitlist_players; previous_group uuid; remaining_count integer; current_game integer; skipped_game integer;
begin
  perform pg_advisory_xact_lock(7429102);
  select * into caller from public.waitlist_players
    where user_id=auth.uid() and status in('current','waiting') for update;
  if caller.id is null then raise exception 'You are no longer active in the waitlist.'; end if;
  if caller.group_id is null then raise exception 'You are not currently in a group.'; end if;
  previous_group:=caller.group_id;
  if caller.status='current' and caller.court_number is not null then
    select game_number into current_game from public.waitlist_courts where court_number=caller.court_number;
  end if;
  if current_game is null then select game_number into current_game from public.waitlist_config where id; end if;
  skipped_game:=case when caller.status='current' then current_game
    else greatest(coalesce(p_skip_game,current_game+1),current_game+1) end;
  insert into public.group_notifications(user_id,message)
    select user_id,caller.display_name||' left your group to sit out one game.'
    from public.waitlist_players where group_id=previous_group and id<>caller.id and user_id is not null;
  update public.waitlist_players set group_id=null,status='sitout',sitout_priority=true,
    sitout_from_game=skipped_game,updated_at=now()
    where id=caller.id;
  select count(*) into remaining_count from public.waitlist_players where group_id=previous_group;
  if remaining_count<=1 then update public.waitlist_players set group_id=null,updated_at=now() where group_id=previous_group; end if;
  perform public.normalize_active_waitlist();
  return jsonb_build_object('message',case when caller.status='current'
    then 'You left the group and current game. This counts as your sit-out, and you have priority for the next game.'
    else 'You left the group, will skip Game '||skipped_game||', and have priority for Game '||(skipped_game+1)||'.' end);
end;
$$;

create or replace function public.next_game_player_ids(p_limit integer)
returns table(player_id uuid) language plpgsql security definer set search_path=public as $$
declare player_block record; remaining integer:=greatest(p_limit,0);
begin
  for player_block in
    select coalesce(group_id,id) block_id,count(*)::integer block_size,
      min(queue_position) first_position,bool_or(sitout_priority) has_priority
    from public.waitlist_players where status='waiting'
    group by coalesce(group_id,id)
    order by bool_or(sitout_priority) desc,min(queue_position),coalesce(group_id,id)
  loop
    exit when remaining<=0;
    if player_block.block_size<=remaining then
      return query select p.id from public.waitlist_players p
        where p.status='waiting' and coalesce(p.group_id,p.id)=player_block.block_id
        order by p.queue_position,p.id;
      remaining:=remaining-player_block.block_size;
    end if;
  end loop;
end;
$$;

create or replace function public.end_current_game()
returns jsonb language plpgsql security definer set search_path=public as $$
declare caller public.waitlist_players; config public.waitlist_config; total_active integer;
declare last_position bigint; actor text; response_rows jsonb:='[]'::jsonb; open_slots integer;
begin
  perform pg_advisory_xact_lock(7429101);
  select * into config from public.waitlist_config where id for update;
  select * into caller from public.waitlist_players where user_id=auth.uid();
  if not public.is_waitlist_operator() and(caller.id is null or caller.status<>'current' or caller.restricted)then
    raise exception 'Only an unrestricted current-game player or admin can start the next game.';
  end if;
  -- Every next-game action receives a reversible snapshot. Operators can
  -- reverse any latest advance; the player who pressed it can reverse theirs.
  perform public.save_admin_undo('start next game');

  insert into public.past_games(game_number,player_names)
    select config.game_number,coalesce(jsonb_agg(
      display_name||case when sitout_priority then ' (Sit-out priority)' else '' end
      order by queue_position),'[]'::jsonb)
    from public.waitlist_players
    where status='current' or (status='sitout' and sitout_from_game=config.game_number)
    on conflict(game_number)do nothing;

  -- A player who just completed their priority game no longer carries the marker.
  update public.waitlist_players set sitout_priority=false,updated_at=now()
    where status='current' and sitout_priority;
  -- The chosen game has now been skipped. Restore only those eligible players
  -- before selecting the next game; future sit-outs remain excluded.
  update public.waitlist_players
    set status='waiting',sitout_from_game=null,updated_at=now()
    where status='sitout' and sitout_from_game<=config.game_number;

  select coalesce(max(queue_position),0) into last_position
    from public.waitlist_players where status in('current','waiting','sitout','rejoin');
  with finished_order as(
    select id,row_number()over(order by queue_position)rn from public.waitlist_players where status='current'
  )
  update public.waitlist_players p set queue_position=last_position+finished_order.rn,updated_at=now()
    from finished_order where p.id=finished_order.id;

  if config.mode='rejoin' then
    update public.waitlist_players set status='rejoin',rejoin_expires_at=now()+interval '15 minutes',updated_at=now()
      where status='current' and user_id is null;
    with changed as(
      update public.waitlist_players p set status='rejoin',rejoin_expires_at=now()+interval '5 minutes',updated_at=now()
        where status='current' and user_id is not null returning p.id,p.user_id,p.queue_position,p.rejoin_expires_at
    )
    insert into public.rejoin_responses(user_id,game_number,original_position,expires_at)
      select user_id,config.game_number+1,queue_position,rejoin_expires_at from changed;
    select coalesce(jsonb_agg(jsonb_build_object('user_id',r.user_id,'response_id',r.id)),'[]'::jsonb)into response_rows
      from public.rejoin_responses r where r.game_number=config.game_number+1 and r.choice is null;
  end if;

  -- A player whose skipped game just ended is now the first eligible block
  -- for the following game. Move their whole group ahead of ordinary waiting
  -- players before filling the new current game.
  with priority_blocks as(
    select distinct coalesce(group_id,id) block_id
    from public.waitlist_players
    where status='waiting' and sitout_priority
  ),ranked as(
    select p.id,row_number()over(order by
      case when coalesce(p.group_id,p.id) in(select block_id from priority_blocks) then 0 else 1 end,
      p.queue_position,p.id) rn
    from public.waitlist_players p
    where p.status in('current','waiting') and p.queue_position is not null
  )
  update public.waitlist_players p set queue_position=ranked.rn,updated_at=now()
    from ranked where p.id=ranked.id;

  select count(*) into total_active from public.waitlist_players where status in('current','waiting','sitout');
  if total_active>config.max_players then
    if config.mode<>'rejoin' then update public.waitlist_players set status='waiting',updated_at=now() where status='current'; end if;
    with chosen as(select player_id from public.next_game_player_ids(config.max_players))
      update public.waitlist_players set status='current',updated_at=now() where id in(select player_id from chosen);
  else
    select greatest(config.max_players-count(*),0) into open_slots from public.waitlist_players where status='current';
    with chosen as(select player_id from public.next_game_player_ids(open_slots))
      update public.waitlist_players set status='current',updated_at=now() where id in(select player_id from chosen);
  end if;

  -- Rank eligible sit-out-priority players first after current-game players.
  with ranked as(
    select id,row_number()over(order by case when status='current' then 0 else 1 end,
      case when status='waiting' and sitout_priority then 0 else 1 end,queue_position,id) rn
    from public.waitlist_players where status in('current','waiting') and queue_position is not null
  )
  update public.waitlist_players p set queue_position=ranked.rn from ranked where p.id=ranked.id;

  update public.waitlist_config set game_number=game_number+1,updated_at=now()where id;
  actor:=coalesce(caller.display_name,'Admin');
  insert into public.waitlist_events(actor_user_id,actor_name,event_type,message)
    values(auth.uid(),actor,'next_game',actor||' started Game '||(config.game_number+1)||'.');
  return jsonb_build_object('message','Game '||(config.game_number+1)||' has started.','game_number',config.game_number+1,'rejoin_prompts',response_rows);
end;
$$;

grant execute on function public.sit_out_one_game(integer) to authenticated;
grant execute on function public.admin_set_player_sitout(uuid,integer) to authenticated;
grant execute on function public.sit_out_and_leave_group(integer) to authenticated;
grant execute on function public.next_game_player_ids(integer) to authenticated;
grant execute on function public.end_current_game() to authenticated;
