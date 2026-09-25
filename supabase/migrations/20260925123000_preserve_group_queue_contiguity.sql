-- Keep active group members contiguous when an interior member leaves.
-- The group-action advisory lock serializes all callers of this helper.
begin;

create or replace function public.detach_group_member_preserving_queue(
  p_facility_id uuid,
  p_player_id uuid,
  p_group_id uuid
)
returns integer language plpgsql security definer set search_path=public as $$
declare
  departing public.waitlist_players;
  remaining_count integer;
  has_before boolean;
  has_after boolean;
begin
  select * into departing
  from public.waitlist_players
  where facility_id=p_facility_id and id=p_player_id and group_id=p_group_id
  for update;

  if departing.id is null then raise exception 'Group member is no longer available.'; end if;

  select count(*),
         coalesce(bool_or(queue_position < departing.queue_position),false),
         coalesce(bool_or(queue_position > departing.queue_position),false)
  into remaining_count,has_before,has_after
  from public.waitlist_players
  where facility_id=p_facility_id
    and group_id=p_group_id
    and id<>p_player_id
    and status in ('current','waiting','sitout','rejoin')
    and queue_position is not null;

  update public.waitlist_players
  set group_id=null,updated_at=now()
  where facility_id=p_facility_id and id=p_player_id;

  -- A first/last departure already leaves the surviving group contiguous. A
  -- one-person remainder keeps the established group-dissolution semantics.
  if remaining_count>=2 and has_before and has_after then
    -- Treat all active queue rows as one ordered sequence. Surviving members
    -- are compacted at their earliest original position; the departing member
    -- follows them; all unrelated rows retain their relative order. Temporary
    -- negative values avoid transient duplicate positions before normalization.
    with base as (
      select id,group_id,
             row_number() over(order by queue_position,created_at,id) as old_rank
      from public.waitlist_players
      where facility_id=p_facility_id
        and status in ('current','waiting','sitout','rejoin')
        and queue_position is not null
    ), bounds as (
      select min(old_rank) as first_survivor_rank
      from base where group_id=p_group_id
    ), ranked as (
      select base.id,
             row_number() over(
               order by
                 case when base.group_id=p_group_id or base.id=p_player_id
                      then bounds.first_survivor_rank else base.old_rank end,
                 case when base.group_id=p_group_id then 0
                      when base.id=p_player_id then 1 else 2 end,
                 base.old_rank
             ) as new_rank
      from base cross join bounds
    )
    update public.waitlist_players p
    set queue_position=-1000000-ranked.new_rank,updated_at=now()
    from ranked
    where p.facility_id=p_facility_id and p.id=ranked.id;

    update public.waitlist_players
    set queue_position=-queue_position-1000000,updated_at=now()
    where facility_id=p_facility_id
      and status in ('current','waiting','sitout','rejoin')
      and queue_position<=-1000001;
  end if;

  select count(*) into remaining_count
  from public.waitlist_players
  where facility_id=p_facility_id and group_id=p_group_id;
  if remaining_count<=1 then
    update public.waitlist_players set group_id=null,updated_at=now()
    where facility_id=p_facility_id and group_id=p_group_id;
  end if;
  return remaining_count;
end;
$$;

revoke all on function public.detach_group_member_preserving_queue(uuid,uuid,uuid) from public, anon, authenticated;

create or replace function public.admin_remove_player_from_group(p_target_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare fid uuid:=public.current_facility_id(); target public.waitlist_players; previous_group uuid; remaining_count integer;
begin
  if fid is null or not public.is_waitlist_operator() then raise exception 'Admin or host access required.'; end if;
  perform pg_advisory_xact_lock(7429102);
  select * into target from public.waitlist_players where facility_id=fid and id=p_target_id for update;
  if target.id is null then raise exception 'Player not found.'; end if;
  if target.group_id is null then raise exception 'This player is not in a group.'; end if;
  perform public.save_admin_undo('remove player from group'); previous_group:=target.group_id;
  insert into public.group_notifications(facility_id,user_id,message) select fid,user_id,target.display_name||' was removed from the group by an admin.' from public.waitlist_players where facility_id=fid and group_id=previous_group and user_id is not null;
  remaining_count:=public.detach_group_member_preserving_queue(fid,target.id,previous_group);
  perform public.notify_waitlist_operator_player(target.user_id,'removed you from your group.');
  perform public.log_waitlist_operator_action('admin_group_remove','removed '||target.display_name||' from a group.');
  return jsonb_build_object('message',target.display_name||' left the group.');
end; $$;

create or replace function public.leave_player_group()
returns jsonb language plpgsql security definer set search_path=public as $$
declare fid uuid:=public.current_facility_id(); caller public.waitlist_players; previous_group uuid; remaining_count integer;
begin
  if fid is null then raise exception 'Select a facility first.'; end if;
  perform pg_advisory_xact_lock(7429102);
  select * into caller from public.waitlist_players where facility_id=fid and user_id=auth.uid() and status in('current','waiting','sitout','rejoin') order by updated_at desc limit 1 for update;
  if caller.id is null then raise exception 'Player not found.'; end if;
  if caller.group_id is null then raise exception 'You are not in a group.'; end if;
  previous_group:=caller.group_id;
  insert into public.group_notifications(facility_id,user_id,message) select fid,user_id,caller.display_name||' left your group.' from public.waitlist_players where facility_id=fid and group_id=previous_group and id<>caller.id and user_id is not null;
  remaining_count:=public.detach_group_member_preserving_queue(fid,caller.id,previous_group);
  return jsonb_build_object('message','You left the group.');
end; $$;

create or replace function public.remove_player_from_group(p_target_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare fid uuid:=public.current_facility_id(); caller public.waitlist_players; target public.waitlist_players; previous_group uuid; remaining_count integer;
begin
  if fid is null then raise exception 'Select a facility first.'; end if;
  perform pg_advisory_xact_lock(7429102);
  select * into caller from public.waitlist_players where facility_id=fid and user_id=auth.uid() and status in('current','waiting','sitout','rejoin') order by updated_at desc limit 1 for update;
  select * into target from public.waitlist_players where facility_id=fid and id=p_target_id for update;
  if caller.id is null then raise exception 'Player not found.'; end if;
  if target.id is null then raise exception 'Group member not found.'; end if;
  if caller.id=target.id then raise exception 'Use Leave Group to leave your own group.'; end if;
  if caller.group_id is null or target.group_id is null or caller.group_id<>target.group_id then raise exception 'You can only remove someone from your own group.'; end if;
  previous_group:=caller.group_id;
  insert into public.group_notifications(facility_id,user_id,message) select fid,user_id,caller.display_name||' removed '||target.display_name||' from your group.' from public.waitlist_players where facility_id=fid and group_id=previous_group and user_id is not null;
  remaining_count:=public.detach_group_member_preserving_queue(fid,target.id,previous_group);
  return jsonb_build_object('message',target.display_name||' was removed from your group.');
end; $$;

grant execute on function public.admin_remove_player_from_group(uuid) to authenticated;
grant execute on function public.leave_player_group() to authenticated;
grant execute on function public.remove_player_from_group(uuid) to authenticated;
commit;
