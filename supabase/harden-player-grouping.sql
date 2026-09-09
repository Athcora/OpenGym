-- Player grouping is invitation-owned: only the invited player changes groups.
-- All queue work is facility-local and every accepted group is one contiguous block.
create or replace function public.fill_open_court_slots()
returns void language plpgsql security definer set search_path=public as $$
declare c record; open_spots integer; candidate record; group_size integer; fid uuid:=public.current_facility_id();
begin
  for c in select court_number from public.waitlist_courts where facility_id=fid order by court_number loop
    select greatest(cfg.max_players-count(p.id),0) into open_spots from public.waitlist_config cfg
    left join public.waitlist_players p on p.facility_id=fid and p.status='current' and p.court_number=c.court_number
    where cfg.facility_id=fid and cfg.id group by cfg.max_players;
    while open_spots>0 loop
      select p.id,p.group_id into candidate from public.waitlist_players p where p.facility_id=fid and p.status='waiting'
      order by p.sitout_priority desc,p.queue_position,p.id limit 1;
      exit when candidate.id is null;
      if candidate.group_id is null then
        update public.waitlist_players set status='current',court_number=c.court_number,sitout_priority=false,updated_at=now()
        where facility_id=fid and id=candidate.id; open_spots:=open_spots-1;
      else
        select count(*) into group_size from public.waitlist_players where facility_id=fid and status='waiting' and group_id=candidate.group_id;
        exit when group_size>open_spots;
        update public.waitlist_players set status='current',court_number=c.court_number,sitout_priority=false,updated_at=now()
        where facility_id=fid and status='waiting' and group_id=candidate.group_id; open_spots:=open_spots-group_size;
      end if;
    end loop;
  end loop;
  with ranked as (select id,row_number() over(order by case when status='current' then 0 else 1 end,
    coalesce(court_number,999),queue_position,id) rn from public.waitlist_players
    where facility_id=fid and status in('current','waiting') and queue_position is not null)
  update public.waitlist_players p set queue_position=ranked.rn from ranked where p.facility_id=fid and p.id=ranked.id;
end; $$;

create or replace function public.request_player_group(p_target_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare requester public.waitlist_players; target public.waitlist_players; request_id uuid;
  fid uuid:=public.current_facility_id(); requester_size integer;
begin
  perform pg_advisory_xact_lock(7429102);
  select * into requester from public.waitlist_players where facility_id=fid and user_id=auth.uid() and status in('current','waiting') for update;
  select * into target from public.waitlist_players where facility_id=fid and id=p_target_id and status in('current','waiting') for update;
  if requester.id is null or target.id is null or requester.id=target.id then raise exception 'This group request is not available.'; end if;
  if requester.group_id is not null and requester.group_id=target.group_id then raise exception 'You are already in the same group.'; end if;
  select count(*) into requester_size from public.waitlist_players p where p.facility_id=fid and p.status in('current','waiting')
    and (p.id=requester.id or (requester.group_id is not null and p.group_id=requester.group_id));
  if requester_size>=6 then raise exception 'Your group already has the maximum of 6 players.'; end if;
  if exists(select 1 from public.group_requests r where r.facility_id=fid and r.status='pending'
    and ((r.requester_id=requester.id and r.target_id=target.id) or (r.requester_id=target.id and r.target_id=requester.id))) then
    raise exception 'A group request is already pending between these players.'; end if;
  insert into public.group_requests(facility_id,requester_id,target_id) values(fid,requester.id,target.id) returning id into request_id;
  return jsonb_build_object('message','Group request sent to '||target.display_name||'.','request_id',request_id);
end; $$;

create or replace function public.answer_player_group(p_request_id uuid,p_accept boolean)
returns jsonb language plpgsql security definer set search_path=public as $$
declare request public.group_requests; target public.waitlist_players; requester public.waitlist_players;
  destination_group uuid; old_target_group uuid; requester_tail bigint; target_position bigint; anchor_tail bigint;
  requester_size integer; remaining_count integer; fid uuid:=public.current_facility_id();
begin
  perform pg_advisory_xact_lock(7429102);
  select r.* into request from public.group_requests r join public.waitlist_players p on p.facility_id=fid and p.id=r.target_id
  where r.facility_id=fid and r.id=p_request_id and p.user_id=auth.uid() and r.status='pending' for update;
  if request.id is null then raise exception 'Group request not found.'; end if;
  if not p_accept then update public.group_requests set status='declined',answered_at=now() where facility_id=fid and id=request.id;
    return jsonb_build_object('message','Group request declined.'); end if;
  select * into target from public.waitlist_players where facility_id=fid and id=request.target_id and status in('current','waiting') for update;
  select * into requester from public.waitlist_players where facility_id=fid and id=request.requester_id and status in('current','waiting') for update;
  if target.id is null or requester.id is null then raise exception 'A player is no longer available to group.'; end if;
  if requester.group_id is not null and requester.group_id=target.group_id then
    update public.group_requests set status='accepted',answered_at=now() where facility_id=fid and id=request.id;
    return jsonb_build_object('message','You are already in the same group.'); end if;
  select count(*) into requester_size from public.waitlist_players p where p.facility_id=fid and p.status in('current','waiting')
    and (p.id=requester.id or (requester.group_id is not null and p.group_id=requester.group_id));
  if requester_size>=6 then update public.group_requests set status='declined',answered_at=now() where facility_id=fid and id=request.id;
    raise exception 'That group already has the maximum of 6 players.'; end if;
  destination_group:=coalesce(requester.group_id,gen_random_uuid()); old_target_group:=target.group_id;
  select max(queue_position) into requester_tail from public.waitlist_players where facility_id=fid
    and (id=requester.id or (requester.group_id is not null and group_id=requester.group_id));
  target_position:=target.queue_position; anchor_tail:=greatest(requester_tail,target_position);
  update public.waitlist_players set queue_position=queue_position*1000 where facility_id=fid and status in('current','waiting');
  -- Preserve the players' existing relative order. In particular, adjacent
  -- players must not swap places merely because the later player sent the
  -- invitation to the earlier player.
  with moving as (select id,row_number() over(order by queue_position,id) rn
    from public.waitlist_players where facility_id=fid and
      (id in(requester.id,target.id) or (requester.group_id is not null and group_id=requester.group_id)))
  update public.waitlist_players p set queue_position=anchor_tail*1000+moving.rn from moving where p.facility_id=fid and p.id=moving.id;
  update public.waitlist_players set group_id=destination_group,status='waiting',court_number=null,updated_at=now()
  where facility_id=fid and (id in(requester.id,target.id) or (requester.group_id is not null and group_id=requester.group_id));
  if old_target_group is not null then
    select count(*) into remaining_count from public.waitlist_players where facility_id=fid and group_id=old_target_group;
    if remaining_count<=1 then update public.waitlist_players set group_id=null,updated_at=now()
      where facility_id=fid and group_id=old_target_group; end if;
  end if;
  perform public.fill_open_court_slots();
  update public.group_requests set status='accepted',answered_at=now() where facility_id=fid and id=request.id;
  update public.group_requests set status='declined',answered_at=now() where facility_id=fid and status='pending' and id<>request.id
    and (requester_id in(requester.id,target.id) or target_id in(requester.id,target.id));
  insert into public.group_notifications(facility_id,user_id,message)
  select fid,requester.user_id,target.display_name||' accepted your group request.' where requester.user_id is not null;
  return jsonb_build_object('message','You joined '||requester.display_name||'''s group.');
end; $$;

grant execute on function public.fill_open_court_slots() to authenticated;
grant execute on function public.request_player_group(uuid) to authenticated;
grant execute on function public.answer_player_group(uuid,boolean) to authenticated;
