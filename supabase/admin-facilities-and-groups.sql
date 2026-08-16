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
  selected_player_ids uuid[];
  anchor_position bigint;
  first_position bigint;
  last_position bigint;
begin
  if not public.is_waitlist_operator() then raise exception 'Admin or host access required.'; end if;
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
  select array_agg(id order by queue_position,id),max(queue_position)
    into selected_player_ids,anchor_position
    from public.waitlist_players
    where id=any(p_player_ids);

  update public.waitlist_players set queue_position=queue_position*1000 where status in ('current','waiting','sitout');

  -- Remove the selected players from their old places and reinsert them as one
  -- block ending at the furthest selected player's original position. For
  -- example, grouping positions 1 and 3 produces: old 2, old 1, old 3.
  with selected as (
    select player_id,ordinality::bigint rn
    from unnest(selected_player_ids) with ordinality as chosen(player_id,ordinality)
  )
  update public.waitlist_players p set
    status='waiting',
    queue_position=anchor_position*1000-selected_count+selected.rn,
    updated_at=now()
  from selected where p.id=selected.player_id;

  update public.waitlist_players set
    group_id=new_group,
    status='waiting',
    updated_at=now()
  where id=any(p_player_ids);

  for old_group in
    select distinct group_id from public.waitlist_players
    where group_id is not null and group_id<>new_group
    group by group_id having count(*)=1
  loop
    update public.waitlist_players set group_id=null,updated_at=now() where group_id=old_group;
  end loop;

  -- Preserve every unaffected court. The legacy normalizer treated all
  -- current players as one game and could empty later courts while grouping.
  -- Do not rank before refilling: doing so pushes the temporarily-waiting
  -- selected group behind every current player and loses its chosen anchor.
  perform public.fill_open_court_slots();

  select min(queue_position),max(queue_position) into first_position,last_position
  from public.waitlist_players where group_id=new_group;

  perform public.log_waitlist_operator_action('admin_group','created a group with '||selected_count||' players.');
  perform public.notify_waitlist_operator_player(p.user_id,'added you to a group.')
  from public.waitlist_players p where p.id=any(p_player_ids);

  return jsonb_build_object('message','The group was created.','first_position',first_position,'last_position',last_position);
end;
$$;

grant execute on function public.admin_group_players(uuid[]) to authenticated;

create or replace function public.admin_remove_player_from_group(p_target_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  target public.waitlist_players;
  previous_group uuid;
  remaining_count integer;
begin
  if not public.is_waitlist_operator() then raise exception 'Admin or host access required.'; end if;
  perform pg_advisory_xact_lock(7429102);

  select * into target from public.waitlist_players where id=p_target_id for update;
  if target.id is null then raise exception 'Player not found.'; end if;
  if target.group_id is null then raise exception 'This player is not in a group.'; end if;

  perform public.save_admin_undo('remove player from group');
  previous_group:=target.group_id;

  insert into public.group_notifications(user_id,message)
  select user_id,target.display_name||' was removed from the group by an admin.'
  from public.waitlist_players
  where group_id=previous_group and user_id is not null;

  update public.waitlist_players set group_id=null,updated_at=now() where id=target.id;
  perform public.notify_waitlist_operator_player(target.user_id,'removed you from your group.');
  select count(*) into remaining_count from public.waitlist_players where group_id=previous_group;
  if remaining_count<=1 then
    update public.waitlist_players set group_id=null,updated_at=now() where group_id=previous_group;
  end if;

  perform public.log_waitlist_operator_action('admin_group_remove','removed '||target.display_name||' from a group.');

  return jsonb_build_object('message',target.display_name||' left the group.');
end;
$$;

grant execute on function public.admin_remove_player_from_group(uuid) to authenticated;
