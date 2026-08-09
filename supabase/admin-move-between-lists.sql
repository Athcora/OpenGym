create or replace function public.admin_move_player(
  p_player_id uuid,
  p_status text,
  p_index integer
)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  player public.waitlist_players;
  target_position bigint;
  max_players integer;
  destination_index integer;
  moving_count integer;
  current_count integer;
  open_spots integer;
  candidate record;
begin
  if not public.is_waitlist_operator() then raise exception 'Admin or host access required.'; end if;
  if p_status not in ('current','waiting') then raise exception 'Invalid destination.'; end if;

  select c.max_players into max_players
  from public.waitlist_config c
  where c.id;

  perform public.save_admin_undo('move player');
  select * into player from public.waitlist_players where id=p_player_id for update;
  if player.id is null then raise exception 'Player not found.'; end if;

  select count(*) into moving_count
  from public.waitlist_players
  where id=player.id or (player.group_id is not null and group_id=player.group_id);

  if p_status='current' and moving_count>max_players then
    raise exception 'This group is larger than the current game capacity.';
  end if;

  destination_index:=greatest(p_index,0);
  if p_status='current' then
    destination_index:=least(destination_index,greatest(max_players-moving_count,0));
  end if;

  select queue_position into target_position
  from public.waitlist_players
  where status=p_status
    and id<>player.id
    and (player.group_id is null or group_id is distinct from player.group_id)
  order by queue_position
  offset destination_index
  limit 1;

  if target_position is null then
    select coalesce(max(queue_position),0)+1000 into target_position
    from public.waitlist_players
    where status=p_status
      and id<>player.id
      and (player.group_id is null or group_id is distinct from player.group_id);
  end if;

  -- Give every existing position room, then insert all moving group members
  -- immediately before the selected destination while preserving their order.
  update public.waitlist_players
  set queue_position=queue_position*1000
  where status in ('current','waiting');

  with moving as (
    select id,row_number() over(order by queue_position,id) rn
    from public.waitlist_players
    where id=player.id or (player.group_id is not null and group_id=player.group_id)
  )
  update public.waitlist_players p
  set status=p_status,
      queue_position=target_position*1000-moving_count+moving.rn-1,
      updated_at=now()
  from moving
  where p.id=moving.id;

  with ranked as (
    select id,row_number() over(order by case status when 'current' then 0 else 1 end,queue_position,id) rn
    from public.waitlist_players
    where status in ('current','waiting')
  )
  update public.waitlist_players p
  set queue_position=ranked.rn
  from ranked
  where p.id=ranked.id;

  -- Keep the game at its configured maximum. A player pushed below the
  -- final game spot naturally becomes the first person on the waitlist.
  with current_ranked as (
    select id,row_number() over(order by queue_position,id) rn
    from public.waitlist_players
    where status='current'
  )
  update public.waitlist_players p
  set status='waiting',updated_at=now()
  from current_ranked
  where p.id=current_ranked.id and current_ranked.rn>max_players;

  -- Moving someone out of the current game must not leave an empty game spot.
  -- Fill vacancies from the front of the existing waitlist, excluding the
  -- player/group that was deliberately moved out. Groups are promoted only
  -- when the whole group fits, so an admin move can never split a group.
  select count(*) into current_count
  from public.waitlist_players
  where status='current';

  open_spots:=greatest(max_players-current_count,0);
  if open_spots>0 and p_status='waiting' then
    for candidate in
      select
        p.group_id,
        case when p.group_id is null then p.id end as member_id,
        count(*)::integer as member_count,
        min(p.queue_position) as first_position
      from public.waitlist_players p
      where p.status='waiting'
        and p.id<>player.id
        and (player.group_id is null or p.group_id is distinct from player.group_id)
      group by p.group_id,case when p.group_id is null then p.id end
      order by min(p.queue_position)
    loop
      if candidate.member_count<=open_spots then
        update public.waitlist_players p
        set status='current',updated_at=now()
        where p.status='waiting'
          and (
            (candidate.group_id is not null and p.group_id=candidate.group_id)
            or (candidate.group_id is null and p.id=candidate.member_id)
          );
        open_spots:=open_spots-candidate.member_count;
        exit when open_spots=0;
      end if;
    end loop;
  end if;

  with ranked as (
    select id,row_number() over(order by case status when 'current' then 0 else 1 end,queue_position,id) rn
    from public.waitlist_players
    where status in ('current','waiting')
  )
  update public.waitlist_players p
  set queue_position=ranked.rn
  from ranked
  where p.id=ranked.id;

  perform public.log_waitlist_operator_action(
    'admin_move',
    case when moving_count>1 then 'moved a group of '||moving_count||' players.' else 'moved '||player.display_name||'.' end
  );
  perform public.notify_waitlist_operator_player(
    moved.user_id,
    'moved your position in the waitlist.'
  )
  from public.waitlist_players moved
  where moved.id=player.id or (player.group_id is not null and moved.group_id=player.group_id);

  return jsonb_build_object(
    'message',
    case when moving_count>1
      then 'The entire group was moved.'
      else player.display_name||' was moved.'
    end
  );
end;
$$;

grant execute on function public.admin_move_player(uuid,text,integer) to authenticated;
