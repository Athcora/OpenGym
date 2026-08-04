-- Admin controls for placing any active player on sit-out or removing them.
create or replace function public.admin_set_player_sitout(p_player_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare player public.waitlist_players;
begin
  if not public.is_waitlist_admin() then raise exception 'Admin access required.'; end if;
  select * into player from public.waitlist_players where id=p_player_id and status in('current','waiting') for update;
  if player.id is null then raise exception 'This player is no longer active.'; end if;
  perform public.save_admin_undo('sit out player');
  update public.waitlist_players set status='sitout',updated_at=now() where id=player.id;
  insert into public.waitlist_events(actor_user_id,actor_name,event_type,message)
    values(auth.uid(),'Admin','admin_sitout','The admin sat out '||player.display_name||' for one game.');
  return jsonb_build_object('message',player.display_name||' will sit out the next game.');
end;
$$;

create or replace function public.admin_leave_player(p_player_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare player public.waitlist_players;
begin
  if not public.is_waitlist_admin() then raise exception 'Admin access required.'; end if;
  select * into player from public.waitlist_players where id=p_player_id and status<>'left' for update;
  if player.id is null then raise exception 'This player has already left.'; end if;
  perform public.save_admin_undo('remove player');
  update public.waitlist_players
    set status='left',queue_position=null,rejoin_expires_at=null,updated_at=now()
    where id=player.id;
  insert into public.waitlist_events(actor_user_id,actor_name,event_type,message)
    values(auth.uid(),'Admin','admin_leave','The admin removed '||player.display_name||' from the waitlist.');
  return jsonb_build_object('message',player.display_name||' left the waitlist.');
end;
$$;

grant execute on function public.admin_set_player_sitout(uuid) to authenticated;
grant execute on function public.admin_leave_player(uuid) to authenticated;
