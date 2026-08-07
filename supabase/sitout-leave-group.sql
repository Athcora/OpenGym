create or replace function public.sit_out_and_leave_group()
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  caller public.waitlist_players;
  previous_group uuid;
  remaining_count integer;
begin
  perform pg_advisory_xact_lock(7429102);

  select * into caller
  from public.waitlist_players
  where user_id=auth.uid() and status in ('current','waiting')
  for update;

  if caller.id is null then raise exception 'You are no longer active in the waitlist.'; end if;
  if caller.group_id is null then raise exception 'You are not currently in a group.'; end if;
  if not exists(
    select 1 from public.waitlist_players member
    where member.group_id=caller.group_id and member.id<>caller.id and member.status='current'
  ) then raise exception 'Your group is not currently playing.'; end if;

  previous_group:=caller.group_id;
  insert into public.group_notifications(user_id,message)
  select user_id,caller.display_name||' left your group to sit out one game.'
  from public.waitlist_players
  where group_id=previous_group and id<>caller.id and user_id is not null;

  update public.waitlist_players
  set group_id=null,status='sitout',updated_at=now()
  where id=caller.id;

  select count(*) into remaining_count
  from public.waitlist_players where group_id=previous_group;
  if remaining_count<=1 then
    update public.waitlist_players set group_id=null,updated_at=now()
    where group_id=previous_group;
  end if;

  return jsonb_build_object(
    'message','You left the group and will sit out one game. You will have priority for the following game.'
  );
end;
$$;

grant execute on function public.sit_out_and_leave_group() to authenticated;
