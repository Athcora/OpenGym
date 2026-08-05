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
begin
  if not public.is_waitlist_admin() then raise exception 'Admin access required.'; end if;
  if p_status not in ('current','waiting') then raise exception 'Invalid destination.'; end if;

  select c.max_players into max_players
  from public.waitlist_config c
  where c.id;

  perform public.save_admin_undo('move player');
  select * into player from public.waitlist_players where id=p_player_id for update;
  if player.id is null then raise exception 'Player not found.'; end if;

  destination_index:=greatest(p_index,0);
  if p_status='current' then
    destination_index:=least(destination_index,greatest(max_players-1,0));
  end if;

  select queue_position into target_position
  from public.waitlist_players
  where status=p_status and id<>p_player_id
  order by queue_position
  offset destination_index
  limit 1;

  if target_position is null then
    select coalesce(max(queue_position),0)+1000 into target_position
    from public.waitlist_players
    where status=p_status;
  end if;

  update public.waitlist_players
  set status=p_status,queue_position=target_position-1,updated_at=now()
  where id=p_player_id;

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

  with ranked as (
    select id,row_number() over(order by case status when 'current' then 0 else 1 end,queue_position,id) rn
    from public.waitlist_players
    where status in ('current','waiting')
  )
  update public.waitlist_players p
  set queue_position=ranked.rn
  from ranked
  where p.id=ranked.id;

  return jsonb_build_object('message',player.display_name||' was moved.');
end;
$$;

grant execute on function public.admin_move_player(uuid,text,integer) to authenticated;
