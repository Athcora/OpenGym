alter table public.waitlist_config
  add column if not exists facility_code text;

create or replace function public.admin_select_facility(p_facility_code text)
returns jsonb language plpgsql security definer set search_path=public as $$
begin
  if not public.is_waitlist_admin() then raise exception 'Admin access required.'; end if;
  if upper(p_facility_code)='PHR' then
    update public.waitlist_config set
      facility_code='PHR',
      facility_latitude=32.95996,
      facility_longitude=-117.18682,
      geofence_radius_m=150,
      geofence_enabled=true,
      updated_at=now()
    where id;
    return jsonb_build_object('message','Pacific Highlands Ranch selected.');
  elsif upper(p_facility_code) in ('NA','N/A') then
    update public.waitlist_config set
      facility_code=null,
      facility_latitude=null,
      facility_longitude=null,
      geofence_enabled=false,
      updated_at=now()
    where id;
    return jsonb_build_object('message','Facility location disabled.');
  end if;
  raise exception 'Unknown facility.';
end;
$$;

grant execute on function public.admin_select_facility(text) to authenticated;

create or replace function public.admin_group_players(p_player_ids uuid[])
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  selected_count integer;
  active_count integer;
  old_group uuid;
  new_group uuid:=gen_random_uuid();
  anchor_position bigint;
  first_position bigint;
  last_position bigint;
  max_players integer;
  current_count integer;
  open_spots integer;
  candidate record;
begin
  if not public.is_waitlist_admin() then raise exception 'Admin access required.'; end if;
  perform pg_advisory_xact_lock(7429102);

  select count(distinct player_id)
    into selected_count
    from unnest(p_player_ids) as selected(player_id);
  if selected_count<2 or selected_count>6 then raise exception 'Select between two and six players.'; end if;

  select count(*) into active_count
  from public.waitlist_players
  where id=any(p_player_ids) and status in ('current','waiting','sitout');
  if active_count<>selected_count then raise exception 'One or more selected players are no longer available.'; end if;

  if exists(
    select 1 from public.waitlist_players selected
    join public.waitlist_players member on member.group_id=selected.group_id
    where selected.id=any(p_player_ids) and selected.group_id is not null and not(member.id=any(p_player_ids))
  ) then raise exception 'Select every member of an existing group.'; end if;

  perform public.save_admin_undo('group players');
  select max(queue_position) into anchor_position from public.waitlist_players where id=any(p_player_ids);
  select max_players into max_players from public.waitlist_config where id;

  update public.waitlist_players set queue_position=queue_position*1000 where status in ('current','waiting','sitout');

  with selected as (
    select id,row_number() over(order by queue_position,id) rn
    from public.waitlist_players where id=any(p_player_ids)
  )
  update public.waitlist_players p set
    group_id=new_group,
    status='waiting',
    queue_position=anchor_position*1000+selected.rn,
    updated_at=now()
  from selected where p.id=selected.id;

  for old_group in
    select distinct group_id from public.waitlist_players
    where group_id is not null and group_id<>new_group
    group by group_id having count(*)=1
  loop
    update public.waitlist_players set group_id=null,updated_at=now() where group_id=old_group;
  end loop;

  with ranked as (
    select id,row_number() over(order by case status when 'current' then 0 else 1 end,queue_position,id) rn
    from public.waitlist_players where status in ('current','waiting','sitout')
  )
  update public.waitlist_players p set queue_position=ranked.rn from ranked where p.id=ranked.id;

  select count(*) into current_count from public.waitlist_players where status='current';
  open_spots:=greatest(max_players-current_count,0);
  if open_spots>0 then
    for candidate in
      select group_id,case when group_id is null then id end member_id,count(*)::integer member_count,min(queue_position) first_queue
      from public.waitlist_players
      where status='waiting' and group_id is distinct from new_group
      group by group_id,case when group_id is null then id end
      order by min(queue_position)
    loop
      if candidate.member_count<=open_spots then
        update public.waitlist_players set status='current',updated_at=now()
        where status='waiting' and ((candidate.group_id is not null and group_id=candidate.group_id) or (candidate.group_id is null and id=candidate.member_id));
        open_spots:=open_spots-candidate.member_count;
        exit when open_spots=0;
      end if;
    end loop;
  end if;

  with ranked as (
    select id,row_number() over(order by case status when 'current' then 0 else 1 end,queue_position,id) rn
    from public.waitlist_players where status in ('current','waiting','sitout')
  )
  update public.waitlist_players p set queue_position=ranked.rn from ranked where p.id=ranked.id;

  select min(queue_position),max(queue_position) into first_position,last_position
  from public.waitlist_players where group_id=new_group;

  return jsonb_build_object('message','The group was created.','first_position',first_position,'last_position',last_position);
end;
$$;

grant execute on function public.admin_group_players(uuid[]) to authenticated;
