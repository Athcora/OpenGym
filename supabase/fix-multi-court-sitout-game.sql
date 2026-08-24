-- Use the player's actual court game when a current player sits out.
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
  update public.waitlist_players set status='sitout',sitout_priority=true,
    sitout_from_game=skipped_game,updated_at=now() where id=player.id;
  perform public.normalize_active_waitlist();
  return jsonb_build_object('message',case when player.status='current'
    then 'Leaving the current game counts as your sit-out. You have priority for the next game.'
    else 'You will skip Game '||skipped_game||' and have priority for Game '||(skipped_game+1)||'.' end,
    'skipped_game',skipped_game,'priority_game',skipped_game+1);
end; $$;

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
  update public.waitlist_players set status='sitout',sitout_priority=true,
    sitout_from_game=skipped_game,updated_at=now() where id=player.id;
  perform public.normalize_active_waitlist();
  perform public.notify_waitlist_operator_player(player.user_id,'made you sit out for one game.');
  perform public.log_waitlist_operator_action('admin_sitout','sat out '||player.display_name||' for one game.');
  return jsonb_build_object('message',case when player.status='current'
    then player.display_name||' left the current game and has priority for the next game.'
    else player.display_name||' will skip Game '||skipped_game||' and have priority for Game '||(skipped_game+1)||'.' end);
end; $$;

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
    sitout_from_game=skipped_game,updated_at=now() where id=caller.id;
  select count(*) into remaining_count from public.waitlist_players where group_id=previous_group;
  if remaining_count<=1 then update public.waitlist_players set group_id=null,updated_at=now() where group_id=previous_group; end if;
  perform public.normalize_active_waitlist();
  return jsonb_build_object('message',case when caller.status='current'
    then 'You left the group and current game. This counts as your sit-out, and you have priority for the next game.'
    else 'You left the group, will skip Game '||skipped_game||', and have priority for Game '||(skipped_game+1)||'.' end);
end; $$;

grant execute on function public.sit_out_one_game(integer) to authenticated;
grant execute on function public.admin_set_player_sitout(uuid,integer) to authenticated;
grant execute on function public.sit_out_and_leave_group(integer) to authenticated;
