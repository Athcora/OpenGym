create or replace function public.answer_player_group(p_request_id uuid,p_accept boolean)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  request public.group_requests;
  target public.waitlist_players;
  requester public.waitlist_players;
  new_group uuid;
  requester_tail bigint;
  target_tail bigint;
  anchor_tail bigint;
begin
  perform pg_advisory_xact_lock(7429102);

  select r.* into request
  from public.group_requests r
  join public.waitlist_players p on p.id=r.target_id
  where r.id=p_request_id and p.user_id=auth.uid() and r.status='pending'
  for update;

  if request.id is null then raise exception 'Group request not found.'; end if;

  if not p_accept then
    update public.group_requests set status='declined',answered_at=now() where id=request.id;
    return jsonb_build_object('message','Group request declined.');
  end if;

  select * into target from public.waitlist_players where id=request.target_id for update;
  select * into requester from public.waitlist_players where id=request.requester_id for update;

  if target.id is null or requester.id is null then raise exception 'A player is no longer on the waitlist.'; end if;

  if target.group_id is not null and target.group_id=requester.group_id then
    update public.group_requests set status='accepted',answered_at=now() where id=request.id;
    return jsonb_build_object('message','You are already in the same group.');
  end if;

  select max(queue_position) into requester_tail
  from public.waitlist_players
  where id=requester.id or (requester.group_id is not null and group_id=requester.group_id);

  select max(queue_position) into target_tail
  from public.waitlist_players
  where id=target.id or (target.group_id is not null and group_id=target.group_id);

  -- Preserve the farther-back group as the anchor. The earlier group is
  -- appended after its final member, keeping every group member together.
  if requester_tail>target_tail then
    new_group:=coalesce(requester.group_id,target.group_id,gen_random_uuid());
    anchor_tail:=requester_tail;
  else
    new_group:=coalesce(target.group_id,requester.group_id,gen_random_uuid());
    anchor_tail:=target_tail;
  end if;

  update public.waitlist_players
  set queue_position=queue_position*1000
  where status in ('current','waiting');

  if requester_tail>target_tail then
    with moving as (
      select id,row_number() over(order by queue_position,id) rn
      from public.waitlist_players
      where id=target.id or (target.group_id is not null and group_id=target.group_id)
    )
    update public.waitlist_players p
    set queue_position=anchor_tail*1000+moving.rn
    from moving
    where p.id=moving.id;
  else
    with moving as (
      select id,row_number() over(order by queue_position,id) rn
      from public.waitlist_players
      where id=requester.id or (requester.group_id is not null and group_id=requester.group_id)
    )
    update public.waitlist_players p
    set queue_position=anchor_tail*1000+moving.rn
    from moving
    where p.id=moving.id;
  end if;

  update public.waitlist_players
  set group_id=new_group,status='waiting',updated_at=now()
  where id in (request.target_id,request.requester_id)
     or (target.group_id is not null and group_id=target.group_id)
     or (requester.group_id is not null and group_id=requester.group_id);

  with ranked as (
    select id,row_number() over(order by queue_position,id) rn
    from public.waitlist_players
    where status in ('current','waiting')
  )
  update public.waitlist_players p
  set queue_position=ranked.rn
  from ranked
  where p.id=ranked.id;

  -- Grouping can move a current-game player back to the later player's
  -- position. Refill every open game spot from the front of the waitlist,
  -- while keeping existing groups together.
  -- Refill open spots without flattening all active courts into one game.
  perform public.fill_open_court_slots();

  update public.group_requests set status='accepted',answered_at=now() where id=request.id;

  insert into public.group_notifications(user_id,message)
  select requester.user_id,target.display_name||' accepted your group request.'
  where requester.user_id is not null;

  return jsonb_build_object('message','You are now grouped with '||requester.display_name||'.');
end;
$$;

grant execute on function public.answer_player_group(uuid,boolean) to authenticated;
