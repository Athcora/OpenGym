-- Keep player-created groups facility-local, bounded, and race-safe.
create or replace function public.request_player_group(p_target_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  requester public.waitlist_players;
  target public.waitlist_players;
  request_id uuid;
  fid uuid:=public.current_facility_id();
  combined_size integer;
begin
  perform pg_advisory_xact_lock(7429102);

  select * into requester from public.waitlist_players
  where facility_id=fid and user_id=auth.uid() and status in('current','waiting') for update;
  select * into target from public.waitlist_players
  where facility_id=fid and id=p_target_id and status in('current','waiting') for update;

  if requester.id is null or target.id is null or requester.id=target.id then
    raise exception 'This group request is not available.';
  end if;
  if requester.group_id is not null and requester.group_id=target.group_id then
    raise exception 'You are already in the same group.';
  end if;

  select count(*) into combined_size from public.waitlist_players p
  where p.facility_id=fid and p.status in('current','waiting') and
    (p.id in(requester.id,target.id)
      or (requester.group_id is not null and p.group_id=requester.group_id)
      or (target.group_id is not null and p.group_id=target.group_id));
  if combined_size>6 then raise exception 'A group can have no more than 6 players.'; end if;

  if exists(select 1 from public.group_requests r
    where r.facility_id=fid and r.status='pending'
      and ((r.requester_id=requester.id and r.target_id=target.id)
        or (r.requester_id=target.id and r.target_id=requester.id))) then
    raise exception 'A group request is already pending between these players.';
  end if;

  insert into public.group_requests(facility_id,requester_id,target_id)
  values(fid,requester.id,target.id) returning id into request_id;
  return jsonb_build_object('message','Group request sent to '||target.display_name||'.','request_id',request_id);
end;
$$;

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
  combined_size integer;
  fid uuid:=public.current_facility_id();
begin
  perform pg_advisory_xact_lock(7429102);

  select r.* into request from public.group_requests r
  join public.waitlist_players p on p.facility_id=fid and p.id=r.target_id
  where r.facility_id=fid and r.id=p_request_id and p.user_id=auth.uid() and r.status='pending'
  for update;
  if request.id is null then raise exception 'Group request not found.'; end if;

  if not p_accept then
    update public.group_requests set status='declined',answered_at=now()
    where facility_id=fid and id=request.id;
    return jsonb_build_object('message','Group request declined.');
  end if;

  select * into target from public.waitlist_players
  where facility_id=fid and id=request.target_id and status in('current','waiting') for update;
  select * into requester from public.waitlist_players
  where facility_id=fid and id=request.requester_id and status in('current','waiting') for update;
  if target.id is null or requester.id is null then raise exception 'A player is no longer available to group.'; end if;

  if target.group_id is not null and target.group_id=requester.group_id then
    update public.group_requests set status='accepted',answered_at=now()
    where facility_id=fid and id=request.id;
    return jsonb_build_object('message','You are already in the same group.');
  end if;

  select count(*) into combined_size from public.waitlist_players p
  where p.facility_id=fid and p.status in('current','waiting') and
    (p.id in(requester.id,target.id)
      or (requester.group_id is not null and p.group_id=requester.group_id)
      or (target.group_id is not null and p.group_id=target.group_id));
  if combined_size>6 then
    update public.group_requests set status='declined',answered_at=now()
    where facility_id=fid and id=request.id;
    raise exception 'A group can have no more than 6 players.';
  end if;

  select max(queue_position) into requester_tail from public.waitlist_players
  where facility_id=fid and (id=requester.id or (requester.group_id is not null and group_id=requester.group_id));
  select max(queue_position) into target_tail from public.waitlist_players
  where facility_id=fid and (id=target.id or (target.group_id is not null and group_id=target.group_id));

  if requester_tail>target_tail then
    new_group:=coalesce(requester.group_id,target.group_id,gen_random_uuid()); anchor_tail:=requester_tail;
  else
    new_group:=coalesce(target.group_id,requester.group_id,gen_random_uuid()); anchor_tail:=target_tail;
  end if;

  update public.waitlist_players set queue_position=queue_position*1000
  where facility_id=fid and status in('current','waiting');

  if requester_tail>target_tail then
    with moving as (select id,row_number() over(order by queue_position,id) rn from public.waitlist_players
      where facility_id=fid and (id=target.id or (target.group_id is not null and group_id=target.group_id)))
    update public.waitlist_players p set queue_position=anchor_tail*1000+moving.rn
    from moving where p.facility_id=fid and p.id=moving.id;
  else
    with moving as (select id,row_number() over(order by queue_position,id) rn from public.waitlist_players
      where facility_id=fid and (id=requester.id or (requester.group_id is not null and group_id=requester.group_id)))
    update public.waitlist_players p set queue_position=anchor_tail*1000+moving.rn
    from moving where p.facility_id=fid and p.id=moving.id;
  end if;

  update public.waitlist_players set group_id=new_group,status='waiting',court_number=null,updated_at=now()
  where facility_id=fid and (id in(request.target_id,request.requester_id)
    or (target.group_id is not null and group_id=target.group_id)
    or (requester.group_id is not null and group_id=requester.group_id));

  perform public.fill_open_court_slots();
  update public.group_requests set status='accepted',answered_at=now()
  where facility_id=fid and id=request.id;
  update public.group_requests set status='declined',answered_at=now()
  where facility_id=fid and status='pending' and id<>request.id
    and (requester_id in(requester.id,target.id) or target_id in(requester.id,target.id));

  insert into public.group_notifications(facility_id,user_id,message)
  select fid,requester.user_id,target.display_name||' accepted your group request.'
  where requester.user_id is not null;
  return jsonb_build_object('message','You are now grouped with '||requester.display_name||'.');
end;
$$;

grant execute on function public.request_player_group(uuid) to authenticated;
grant execute on function public.answer_player_group(uuid,boolean) to authenticated;
