-- Facility-presence requirements apply to every player, including session hosts
-- and players in either teams mode. Administrators remain exempt so they can
-- manage a facility remotely.
create or replace function public.remove_self_for_geofence()
returns jsonb language plpgsql security definer set search_path=public as $$
declare p public.waitlist_players; c public.waitlist_config; prompt public.geofence_return_prompts; remaining integer;
begin
  if public.is_waitlist_admin() then raise exception 'This return window is only for players.'; end if;
  select * into c from public.waitlist_config where id;
  if not c.geofence_enabled then raise exception 'The facility location check is not active for this waitlist.'; end if;
  select * into p from public.waitlist_players where user_id=auth.uid() for update;
  if p.id is null then raise exception 'Player not found.'; end if;
  select * into prompt from public.geofence_return_prompts where player_id=p.id and resolved_at is null and expires_at>now() order by removed_at desc limit 1;
  if prompt.id is not null then return jsonb_build_object('id',prompt.id,'removed_at',prompt.removed_at,'saved_position_until',prompt.saved_position_until,'expires_at',prompt.expires_at); end if;
  if p.status not in ('current','waiting','sitout') or p.queue_position is null then raise exception 'You are not currently in the waitlist.'; end if;
  insert into public.geofence_return_prompts(player_id,user_id,original_status,original_position) values(p.id,auth.uid(),p.status,p.queue_position) returning * into prompt;
  update public.waitlist_players set status='left',queue_position=null,group_id=null,rejoin_expires_at=null,updated_at=now() where id=p.id;
  if p.group_id is not null then select count(*) into remaining from public.waitlist_players where group_id=p.group_id and status in ('current','waiting','sitout'); if remaining<2 then update public.waitlist_players set group_id=null,updated_at=now() where group_id=p.group_id; end if; end if;
  if c.mode not in ('teams','teams_rejoin') then perform public.normalize_active_waitlist(); end if;
  insert into public.waitlist_events(actor_user_id,actor_name,event_type,message) values(auth.uid(),p.display_name,'geofence_leave',p.display_name||' was removed after leaving the facility area.');
  return jsonb_build_object('id',prompt.id,'removed_at',prompt.removed_at,'saved_position_until',prompt.saved_position_until,'expires_at',prompt.expires_at);
end; $$;

grant execute on function public.remove_self_for_geofence() to authenticated;
