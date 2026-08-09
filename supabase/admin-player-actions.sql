-- Admin controls for placing any active player on sit-out or removing them.
create or replace function public.notify_waitlist_operator_player(p_user_id uuid,p_action text)
returns void language plpgsql security definer set search_path=public as $$
declare actor_label text;
begin
  if p_user_id is null then return; end if;
  actor_label:=case when exists(select 1 from public.waitlist_players where user_id=auth.uid() and is_host and status in('current','waiting','sitout','rejoin')) then 'A host' else 'An admin' end;
  insert into public.group_notifications(user_id,message)
  values(p_user_id,'OPERATOR_ACTION|'||actor_label||' '||p_action);
end;
$$;

create or replace function public.admin_set_player_sitout(p_player_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare player public.waitlist_players;
begin
  if not public.is_waitlist_operator() then raise exception 'Admin or host access required.'; end if;
  select * into player from public.waitlist_players where id=p_player_id and status in('current','waiting') for update;
  if player.id is null then raise exception 'This player is no longer active.'; end if;
  perform public.save_admin_undo('sit out player');
  update public.waitlist_players set status='sitout',updated_at=now() where id=player.id;
  perform public.notify_waitlist_operator_player(player.user_id,'made you sit out for one game.');
  perform public.log_waitlist_operator_action('admin_sitout','sat out '||player.display_name||' for one game.');
  return jsonb_build_object('message',player.display_name||' will sit out the next game.');
end;
$$;

create or replace function public.admin_leave_player(p_player_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare player public.waitlist_players; remaining_group_members integer;
begin
  if not public.is_waitlist_operator() then raise exception 'Admin or host access required.'; end if;
  select * into player from public.waitlist_players where id=p_player_id and status<>'left' for update;
  if player.id is null then raise exception 'This player has already left.'; end if;
  perform public.save_admin_undo('remove player');
  update public.waitlist_players
    set status='left',queue_position=null,group_id=null,rejoin_expires_at=null,updated_at=now()
    where id=player.id;
  perform public.notify_waitlist_operator_player(player.user_id,'removed you from the waitlist.');
  if player.group_id is not null then
    select count(*) into remaining_group_members
    from public.waitlist_players
    where group_id=player.group_id and status in ('current','waiting','sitout');
    if remaining_group_members<2 then
      update public.waitlist_players set group_id=null,updated_at=now()
      where group_id=player.group_id;
    end if;
  end if;
  perform public.normalize_active_waitlist();
  perform public.log_waitlist_operator_action('admin_leave','removed '||player.display_name||' from the waitlist.');
  return jsonb_build_object('message',player.display_name||' left the waitlist.');
end;
$$;

grant execute on function public.admin_set_player_sitout(uuid) to authenticated;
grant execute on function public.admin_leave_player(uuid) to authenticated;
