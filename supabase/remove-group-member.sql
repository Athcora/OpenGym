create or replace function public.remove_player_from_group(p_target_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  caller public.waitlist_players;
  target public.waitlist_players;
  remaining_count integer;
begin
  perform pg_advisory_xact_lock(7429102);

  select * into caller
  from public.waitlist_players
  where user_id=auth.uid()
  for update;

  select * into target
  from public.waitlist_players
  where id=p_target_id
  for update;

  if caller.id is null then raise exception 'Player not found.'; end if;
  if target.id is null then raise exception 'Group member not found.'; end if;
  if caller.id=target.id then raise exception 'Use Leave Group to leave your own group.'; end if;
  if caller.group_id is null or target.group_id is null or caller.group_id<>target.group_id then
    raise exception 'You can only remove someone from your own group.';
  end if;

  insert into public.group_notifications(user_id,message)
  select user_id,caller.display_name||' removed '||target.display_name||' from your group.'
  from public.waitlist_players
  where group_id=caller.group_id and user_id is not null;

  update public.waitlist_players
  set group_id=null,updated_at=now()
  where id=target.id;

  select count(*) into remaining_count
  from public.waitlist_players
  where group_id=caller.group_id;

  if remaining_count<=1 then
    update public.waitlist_players
    set group_id=null,updated_at=now()
    where group_id=caller.group_id;
  end if;

  return jsonb_build_object('message',target.display_name||' was removed from your group.');
end;
$$;

grant execute on function public.remove_player_from_group(uuid) to authenticated;
