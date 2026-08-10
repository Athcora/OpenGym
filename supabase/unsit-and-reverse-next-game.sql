-- Operator recovery controls for one-game sit-outs and accidental game advances.

create or replace function public.save_admin_undo(p_label text)
returns void language plpgsql security definer set search_path=public as $$
declare caller public.waitlist_players;
begin
  if not public.is_waitlist_operator() then
    select * into caller from public.waitlist_players where user_id=auth.uid();
    if p_label<>'start next game' or caller.id is null or caller.status<>'current' or caller.restricted then
      raise exception 'Admin or host access required.';
    end if;
  end if;
  insert into public.admin_undo(admin_user_id,label,snapshot)
    values(auth.uid(),p_label,public.capture_waitlist_state());
  delete from public.admin_undo where admin_user_id=auth.uid() and id not in(
    select id from public.admin_undo where admin_user_id=auth.uid() order by id desc limit 5
  );
  delete from public.admin_redo where admin_user_id=auth.uid();
end;
$$;

create or replace function public.restore_waitlist_state(p_state jsonb)
returns void language plpgsql security definer set search_path=public as $$
declare item jsonb;
begin
  delete from public.waitlist_players where true;
  for item in select * from jsonb_array_elements(p_state->'players') loop
    insert into public.waitlist_players(
      id,user_id,first_name,last_name,display_name,status,queue_position,restricted,
      rejoin_expires_at,created_at,updated_at,group_id,is_host,sitout_priority,sitout_from_game
    ) values(
      (item->>'id')::uuid,nullif(item->>'user_id','')::uuid,item->>'first_name',item->>'last_name',
      item->>'display_name',item->>'status',nullif(item->>'queue_position','')::bigint,
      coalesce((item->>'restricted')::boolean,false),nullif(item->>'rejoin_expires_at','')::timestamptz,
      (item->>'created_at')::timestamptz,now(),nullif(item->>'group_id','')::uuid,
      coalesce((item->>'is_host')::boolean,false),coalesce((item->>'sitout_priority')::boolean,false),
      nullif(item->>'sitout_from_game','')::integer
    );
  end loop;
  update public.waitlist_config set
    game_number=(p_state->'config'->>'game_number')::int,
    max_players=(p_state->'config'->>'max_players')::int,
    mode=p_state->'config'->>'mode',updated_at=now()
  where id;
  delete from public.past_games where true;
  for item in select * from jsonb_array_elements(p_state->'past_games') loop
    insert into public.past_games(id,game_number,player_names,ended_at)
    values((item->>'id')::uuid,(item->>'game_number')::int,item->'player_names',(item->>'ended_at')::timestamptz);
  end loop;
end;
$$;

create or replace function public.admin_unsit_player(p_player_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare player public.waitlist_players;
begin
  perform pg_advisory_xact_lock(7429102);
  if not public.is_waitlist_operator() then raise exception 'Admin or host access required.'; end if;
  select * into player from public.waitlist_players where id=p_player_id and status='sitout' for update;
  if player.id is null then raise exception 'This player is not currently sitting out.'; end if;
  perform public.save_admin_undo('unsit player');
  update public.waitlist_players set status='waiting',sitout_priority=false,sitout_from_game=null,updated_at=now()
    where id=player.id;
  perform public.normalize_active_waitlist();
  perform public.notify_waitlist_operator_player(player.user_id,'reversed your sit-out.');
  perform public.log_waitlist_operator_action('admin_unsit','reversed the sit-out for '||player.display_name||'.');
  return jsonb_build_object('message',player.display_name||'''s sit-out was reversed.');
end;
$$;

create or replace function public.reverse_next_game()
returns jsonb language plpgsql security definer set search_path=public as $$
declare entry public.admin_undo; snapshot_game integer; current_game integer; actor text;
begin
  perform pg_advisory_xact_lock(7429101);
  if public.is_waitlist_operator() then
    select * into entry from public.admin_undo where label='start next game' order by id desc limit 1 for update;
  else
    select * into entry from public.admin_undo where label='start next game' and admin_user_id=auth.uid() order by id desc limit 1 for update;
  end if;
  if entry.id is null then raise exception 'There is no recent next-game action you can reverse.'; end if;
  snapshot_game:=(entry.snapshot->'config'->>'game_number')::integer;
  select game_number into current_game from public.waitlist_config where id for update;
  if current_game<>snapshot_game+1 then raise exception 'This game can no longer be reversed because the waitlist has already advanced.'; end if;
  perform public.restore_waitlist_state(entry.snapshot);
  delete from public.rejoin_responses where game_number>snapshot_game;
  delete from public.admin_undo where id=entry.id;
  delete from public.admin_redo where admin_user_id=entry.admin_user_id;
  select coalesce(display_name,'Admin') into actor from public.waitlist_players where user_id=auth.uid();
  insert into public.waitlist_events(actor_user_id,actor_name,event_type,message)
    values(auth.uid(),coalesce(actor,'Admin'),'next_game_reversed',coalesce(actor,'Admin')||' reversed the start of Game '||(snapshot_game+1)||'.');
  return jsonb_build_object('message','Game '||(snapshot_game+1)||' was reversed. Game '||snapshot_game||' and its queue order are restored.');
end;
$$;

grant execute on function public.admin_unsit_player(uuid) to authenticated;
grant execute on function public.reverse_next_game() to authenticated;
