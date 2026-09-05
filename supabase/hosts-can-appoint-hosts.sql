create or replace function public.admin_set_session_host(p_player_id uuid,p_is_host boolean)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  target public.waitlist_players;
  caller public.waitlist_players;
  caller_is_admin boolean:=public.is_waitlist_admin();
  host_count integer;
  actor_label text;
begin
  select * into caller
  from public.waitlist_players
  where user_id=auth.uid() and is_host and status in ('current','waiting','sitout','rejoin')
  limit 1;

  if not caller_is_admin and caller.id is null then
    raise exception 'Admin or host access required.';
  end if;
  if not caller_is_admin and not p_is_host then
    raise exception 'Only an admin can remove host permissions.';
  end if;

  perform pg_advisory_xact_lock(hashtext('waitlist-session-host-limit'));
  select * into target
  from public.waitlist_players
  where id=p_player_id and status in ('current','waiting','sitout','rejoin')
  for update;

  if target.id is null then raise exception 'That player is no longer active.'; end if;
  if target.user_id is null then raise exception 'Only a player using their own device can be appointed as a host.'; end if;
  if not caller_is_admin and target.id=caller.id then raise exception 'Hosts cannot change their own permissions.'; end if;

  if p_is_host then
    select count(*) into host_count
    from public.waitlist_players
    where is_host and status in ('current','waiting','sitout','rejoin') and id<>target.id;
    if host_count>=2 then raise exception 'A session can have no more than two hosts.'; end if;
  end if;

  update public.waitlist_players set is_host=p_is_host,updated_at=now() where id=target.id;
  actor_label:=case when caller_is_admin then 'Admin' else caller.display_name end;
  insert into public.waitlist_events(actor_user_id,actor_name,event_type,message)
  values(auth.uid(),actor_label,case when p_is_host then 'host_appointed' else 'host_removed' end,
    case when p_is_host then actor_label||' appointed '||target.display_name||' as a Session Host.' else 'The admin removed '||target.display_name||' as a Session Host.' end);
  insert into public.group_notifications(user_id,message)
  values(target.user_id,case when p_is_host then 'HOST_APPOINTED|'||actor_label||' appointed you as a Session Host.' else 'HOST_REMOVED|The admin removed your Session Host permissions.' end);
  return jsonb_build_object('message',case when p_is_host then target.display_name||' is now a Session Host.' else target.display_name||' is no longer a Session Host.' end);
end;
$$;

grant execute on function public.admin_set_session_host(uuid,boolean) to authenticated;
