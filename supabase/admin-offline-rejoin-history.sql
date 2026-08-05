-- Admin-managed rejoin flow for walk-in players without phones, plus waitlist history.
create or replace function public.log_waitlist_player_change()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  if tg_op='INSERT' and new.user_id is not null and new.status<>'left' then
    insert into public.waitlist_events(actor_user_id,actor_name,event_type,message)
    values(new.user_id,new.display_name,'join',new.display_name||' joined the waitlist.');
  elsif tg_op='UPDATE' and old.status='left' and new.status<>'left' and new.user_id is not null then
    insert into public.waitlist_events(actor_user_id,actor_name,event_type,message)
    values(new.user_id,new.display_name,'join',new.display_name||' joined the waitlist.');
  elsif tg_op='UPDATE' and old.status<>'left' and new.status='left' then
    insert into public.waitlist_events(actor_user_id,actor_name,event_type,message)
    values(new.user_id,new.display_name,'leave',new.display_name||' left the waitlist.');
  end if;
  return new;
end;
$$;

drop trigger if exists waitlist_player_history on public.waitlist_players;
create trigger waitlist_player_history after insert or update of status on public.waitlist_players
for each row execute function public.log_waitlist_player_change();

create or replace function public.admin_list_offline_rejoins()
returns table(id uuid,display_name text,queue_position bigint,expires_at timestamptz)
language plpgsql security definer set search_path=public as $$
begin
  if not public.is_waitlist_admin() then raise exception 'Admin access required.'; end if;
  update public.waitlist_players set status='left',queue_position=null,rejoin_expires_at=null,updated_at=now()
    where user_id is null and status='rejoin' and rejoin_expires_at<=now();
  return query select p.id,p.display_name,p.queue_position,p.rejoin_expires_at
    from public.waitlist_players p where p.user_id is null and p.status='rejoin'
    order by p.queue_position;
end;
$$;

create or replace function public.admin_answer_offline_rejoin(p_player_id uuid,p_stay boolean)
returns jsonb language plpgsql security definer set search_path=public as $$
declare player public.waitlist_players;declare active_count integer;declare max_players integer;declare new_status text;
begin
  if not public.is_waitlist_admin() then raise exception 'Admin access required.'; end if;
  select * into player from public.waitlist_players where id=p_player_id and user_id is null and status='rejoin' for update;
  if player.id is null then raise exception 'This rejoin request is no longer available.'; end if;
  if player.rejoin_expires_at<=now() then
    update public.waitlist_players set status='left',queue_position=null,rejoin_expires_at=null,updated_at=now() where id=player.id;
    raise exception 'The 15-minute rejoin window has expired.';
  end if;
  perform public.save_admin_undo(case when p_stay then 'rejoin player' else 'remove rejoin player' end);
  select count(*) into active_count from public.waitlist_players where status in('current','waiting','sitout');
  select c.max_players into max_players from public.waitlist_config c where c.id;
  new_status:=case when active_count<max_players then 'current' else 'waiting' end;
  update public.waitlist_players set status=case when p_stay then new_status else 'left' end,
    queue_position=case when p_stay then player.queue_position else null end,rejoin_expires_at=null,updated_at=now() where id=player.id;
  if p_stay then
    insert into public.waitlist_events(actor_user_id,actor_name,event_type,message)
    values(auth.uid(),'Admin','admin_rejoin','The admin returned '||player.display_name||case when new_status='current' then ' directly to the current game.' else ' to their saved queue position.' end);
  end if;
  return jsonb_build_object('message',case when p_stay and new_status='current' then player.display_name||' rejoined the current game.' when p_stay then player.display_name||' rejoined at their saved position.' else player.display_name||' was removed.' end);
end;
$$;

create or replace function public.admin_list_waitlist_history()
returns table(id bigint,actor_name text,event_type text,message text,created_at timestamptz)
language plpgsql security definer set search_path=public as $$
begin
  if not public.is_waitlist_admin() then raise exception 'Admin access required.'; end if;
  return query select e.id,e.actor_name,e.event_type,e.message,e.created_at
    from public.waitlist_events e order by e.created_at desc limit 250;
end;
$$;

create or replace function public.next_game_player_ids(p_limit integer)
returns table(player_id uuid) language plpgsql security definer set search_path=public as $$
declare player_block record; remaining integer:=greatest(p_limit,0);
begin
  for player_block in
    select coalesce(group_id,id) block_id,count(*)::integer block_size,min(queue_position) first_position
    from public.waitlist_players
    where status='waiting'
    group by coalesce(group_id,id)
    order by min(queue_position),coalesce(group_id,id)
  loop
    exit when remaining<=0;
    if player_block.block_size<=remaining then
      return query
        select p.id from public.waitlist_players p
        where p.status='waiting' and coalesce(p.group_id,p.id)=player_block.block_id
        order by p.queue_position,p.id;
      remaining:=remaining-player_block.block_size;
    end if;
  end loop;
end;
$$;

create or replace function public.end_current_game()
returns jsonb language plpgsql security definer set search_path=public as $$
declare caller public.waitlist_players;declare config public.waitlist_config;declare total_active integer;
declare last_position bigint;declare actor text;declare response_rows jsonb:='[]'::jsonb;declare open_slots integer;
begin
  perform pg_advisory_xact_lock(7429101);
  select * into config from public.waitlist_config where id for update;
  select * into caller from public.waitlist_players where user_id=auth.uid();
  if not public.is_waitlist_admin() and(caller.id is null or caller.status<>'current' or caller.restricted)then
    raise exception 'Only an unrestricted current-game player or admin can start the next game.';
  end if;
  if public.is_waitlist_admin() then perform public.save_admin_undo('start next game');end if;
  insert into public.past_games(game_number,player_names)
    select config.game_number,coalesce(jsonb_agg(display_name order by queue_position),'[]'::jsonb) from public.waitlist_players where status='current'
    on conflict(game_number)do nothing;

  -- Reserve every finished player's next position now, before anybody answers
  -- a rejoin prompt. Existing waiters stay first and the finished game's order
  -- is preserved across account and admin-added players.
  select coalesce(max(queue_position),0) into last_position
    from public.waitlist_players where status in('current','waiting','sitout','rejoin');
  with finished_order as(
    select id,row_number()over(order by queue_position)rn
      from public.waitlist_players where status='current'
  )
  update public.waitlist_players p
    set queue_position=last_position+finished_order.rn,updated_at=now()
    from finished_order where p.id=finished_order.id;

  -- Regular mode is a continuous queue: every finished player stays active and
  -- rotates behind the existing waiters until that player or an admin removes
  -- them. Only Rejoin mode temporarily removes finished players for confirmation.
  if config.mode='rejoin' then
    update public.waitlist_players set status='rejoin',rejoin_expires_at=now()+interval '15 minutes',updated_at=now()
      where status='current' and user_id is null;
  end if;

  -- Rejoin mode always requires every account player from the finished game
  -- to confirm that they are staying, even when the remaining queue is small.
  if config.mode='rejoin' then
    with changed as(
      update public.waitlist_players p
        set status='rejoin',rejoin_expires_at=now()+interval '5 minutes',updated_at=now()
        where status='current' and user_id is not null
        returning p.id,p.user_id,p.queue_position,p.rejoin_expires_at
    )
    insert into public.rejoin_responses(user_id,game_number,original_position,expires_at)
      select user_id,config.game_number+1,queue_position,rejoin_expires_at from changed;
    select coalesce(jsonb_agg(jsonb_build_object('user_id',r.user_id,'response_id',r.id)),'[]'::jsonb)into response_rows
      from public.rejoin_responses r where r.game_number=config.game_number+1 and r.choice is null;
  end if;

  select count(*) into total_active from public.waitlist_players where status in('current','waiting','sitout');
  if total_active>config.max_players then
    if config.mode<>'rejoin' then
      update public.waitlist_players set status='waiting',updated_at=now() where status='current';
    end if;
    with chosen as(select player_id from public.next_game_player_ids(config.max_players))
      update public.waitlist_players set status='current',updated_at=now() where id in(select player_id from chosen);
    select coalesce(min(queue_position),1)into last_position from public.waitlist_players where status='waiting';
    with skipped as(select id,row_number()over(order by queue_position)rn from public.waitlist_players where status='sitout')
      update public.waitlist_players p set status='waiting',queue_position=last_position-skipped.rn,updated_at=now() from skipped where p.id=skipped.id;
  else
    select greatest(config.max_players-count(*),0) into open_slots from public.waitlist_players where status='current';
    with chosen as(select player_id from public.next_game_player_ids(open_slots))
      update public.waitlist_players set status='current',updated_at=now() where id in(select player_id from chosen);
  end if;
  update public.waitlist_config set game_number=game_number+1,updated_at=now()where id;
  actor:=coalesce(caller.display_name,'Admin');
  insert into public.waitlist_events(actor_user_id,actor_name,event_type,message)values(auth.uid(),actor,'next_game',actor||' started Game '||(config.game_number+1)||'.');
  return jsonb_build_object('message','Game '||(config.game_number+1)||' has started.','game_number',config.game_number+1,'rejoin_prompts',response_rows);
end;
$$;

grant execute on function public.admin_list_offline_rejoins() to authenticated;
grant execute on function public.admin_answer_offline_rejoin(uuid,boolean) to authenticated;
grant execute on function public.admin_list_waitlist_history() to authenticated;
