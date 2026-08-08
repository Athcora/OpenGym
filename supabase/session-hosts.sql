alter table public.waitlist_players
  add column if not exists is_host boolean not null default false;

create or replace function public.is_waitlist_host()
returns boolean language sql stable security definer set search_path=public as $$
  select exists(
    select 1 from public.waitlist_players
    where user_id=auth.uid()
      and is_host
      and status in ('current','waiting','sitout','rejoin')
  );
$$;

create or replace function public.is_waitlist_operator()
returns boolean language sql stable security definer set search_path=public as $$
  select public.is_waitlist_admin() or public.is_waitlist_host();
$$;

create or replace function public.admin_set_session_host(p_player_id uuid,p_is_host boolean)
returns jsonb language plpgsql security definer set search_path=public as $$
declare target public.waitlist_players; host_count integer;
begin
  if not public.is_waitlist_admin() then raise exception 'Admin access required.'; end if;
  select * into target from public.waitlist_players where id=p_player_id and status in ('current','waiting','sitout','rejoin') for update;
  if target.id is null then raise exception 'That player is no longer active.'; end if;
  if target.user_id is null then raise exception 'Only a player using their own device can be appointed as a host.'; end if;
  if p_is_host then
    select count(*) into host_count from public.waitlist_players where is_host and status in ('current','waiting','sitout','rejoin') and id<>target.id;
    if host_count>=2 then raise exception 'A session can have no more than two hosts.'; end if;
  end if;
  update public.waitlist_players set is_host=p_is_host,updated_at=now() where id=target.id;
  insert into public.waitlist_events(actor_user_id,actor_name,event_type,message)
  values(auth.uid(),'Admin',case when p_is_host then 'host_appointed' else 'host_removed' end,
    case when p_is_host then 'The admin appointed '||target.display_name||' as a Session Host.' else 'The admin removed '||target.display_name||' as a Session Host.' end);
  insert into public.group_notifications(user_id,message)
  values(target.user_id,case when p_is_host then 'HOST_APPOINTED|The admin appointed you as a Session Host.' else 'HOST_REMOVED|The admin removed your Session Host permissions.' end);
  return jsonb_build_object('message',case when p_is_host then target.display_name||' is now a Session Host.' else target.display_name||' is no longer a Session Host.' end);
end;
$$;

grant execute on function public.is_waitlist_host() to authenticated;
grant execute on function public.is_waitlist_operator() to authenticated;
grant execute on function public.admin_set_session_host(uuid,boolean) to authenticated;

create or replace function public.clear_session_host_when_leaving()
returns trigger language plpgsql set search_path=public as $$
begin
  if new.status='left' then new.is_host:=false; end if;
  return new;
end;
$$;

drop trigger if exists clear_session_host_on_leave on public.waitlist_players;
create trigger clear_session_host_on_leave before update of status on public.waitlist_players
for each row execute function public.clear_session_host_when_leaving();
