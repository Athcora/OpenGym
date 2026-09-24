-- Scope browser-reachable group and King roster mutations to the selected
-- facility. This replaces the whole wrapper chain in one transaction.
begin;

create or replace function public.admin_group_players(p_player_ids uuid[])
returns jsonb language plpgsql security definer set search_path=public as $$
declare fid uuid:=public.current_facility_id(); selected_count integer; active_count integer; old_group uuid; new_group uuid:=gen_random_uuid(); selected_player_ids uuid[]; anchor_position bigint; first_position bigint; last_position bigint;
begin
  if fid is null or not public.is_waitlist_operator() then raise exception 'Admin or host access required.'; end if;
  perform pg_advisory_xact_lock(7429102);
  select count(distinct player_id) into selected_count from unnest(p_player_ids) as selected(player_id);
  if selected_count<2 or selected_count>6 then raise exception 'Select between two and six players.'; end if;
  select count(*) into active_count from public.waitlist_players where facility_id=fid and id=any(p_player_ids) and status in ('current','waiting','sitout');
  if active_count<>selected_count then raise exception 'One or more selected players are no longer available.'; end if;
  if exists(select 1 from public.waitlist_players selected join public.waitlist_players member on member.facility_id=fid and member.group_id=selected.group_id where selected.facility_id=fid and selected.id=any(p_player_ids) and selected.group_id is not null and not(member.id=any(p_player_ids))) then raise exception 'Select every member of an existing group.'; end if;
  perform public.save_admin_undo('group players');
  select array_agg(id order by queue_position,id),max(queue_position) into selected_player_ids,anchor_position from public.waitlist_players where facility_id=fid and id=any(p_player_ids);
  update public.waitlist_players set queue_position=queue_position*1000 where facility_id=fid and status in ('current','waiting','sitout');
  with selected as(select player_id,ordinality::bigint rn from unnest(selected_player_ids) with ordinality as chosen(player_id,ordinality))
  update public.waitlist_players p set status='waiting',queue_position=anchor_position*1000-selected_count+selected.rn,updated_at=now() from selected where p.facility_id=fid and p.id=selected.player_id;
  update public.waitlist_players set group_id=new_group,status='waiting',updated_at=now() where facility_id=fid and id=any(p_player_ids);
  for old_group in select group_id from public.waitlist_players where facility_id=fid and group_id is not null and group_id<>new_group group by group_id having count(*)=1 loop
    update public.waitlist_players set group_id=null,updated_at=now() where facility_id=fid and group_id=old_group;
  end loop;
  perform public.fill_open_court_slots();
  select min(queue_position),max(queue_position) into first_position,last_position from public.waitlist_players where facility_id=fid and group_id=new_group;
  perform public.log_waitlist_operator_action('admin_group','created a group with '||selected_count||' players.');
  perform public.notify_waitlist_operator_player(p.user_id,'added you to a group.') from public.waitlist_players p where p.facility_id=fid and p.id=any(p_player_ids);
  return jsonb_build_object('message','The group was created.','first_position',first_position,'last_position',last_position);
end; $$;

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
  update public.waitlist_players set group_id=null,updated_at=now() where facility_id=fid and id=target.id;
  perform public.notify_waitlist_operator_player(target.user_id,'removed you from your group.');
  select count(*) into remaining_count from public.waitlist_players where facility_id=fid and group_id=previous_group;
  if remaining_count<=1 then update public.waitlist_players set group_id=null,updated_at=now() where facility_id=fid and group_id=previous_group; end if;
  perform public.log_waitlist_operator_action('admin_group_remove','removed '||target.display_name||' from a group.');
  return jsonb_build_object('message',target.display_name||' left the group.');
end; $$;

create or replace function public.leave_player_group()
returns jsonb language plpgsql security definer set search_path=public as $$
declare fid uuid:=public.current_facility_id(); caller public.waitlist_players; remaining_count integer;
begin
  if fid is null then raise exception 'Select a facility first.'; end if;
  perform pg_advisory_xact_lock(7429102);
  select * into caller from public.waitlist_players where facility_id=fid and user_id=auth.uid() and status in('current','waiting','sitout','rejoin') order by updated_at desc limit 1 for update;
  if caller.id is null then raise exception 'Player not found.'; end if;
  if caller.group_id is null then raise exception 'You are not in a group.'; end if;
  insert into public.group_notifications(facility_id,user_id,message) select fid,user_id,caller.display_name||' left your group.' from public.waitlist_players where facility_id=fid and group_id=caller.group_id and id<>caller.id and user_id is not null;
  update public.waitlist_players set group_id=null,updated_at=now() where facility_id=fid and id=caller.id;
  select count(*) into remaining_count from public.waitlist_players where facility_id=fid and group_id=caller.group_id;
  if remaining_count<=1 then update public.waitlist_players set group_id=null,updated_at=now() where facility_id=fid and group_id=caller.group_id; end if;
  return jsonb_build_object('message','You left the group and kept your queue position.');
end; $$;

create or replace function public.remove_player_from_group(p_target_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare fid uuid:=public.current_facility_id(); caller public.waitlist_players; target public.waitlist_players; remaining_count integer;
begin
  if fid is null then raise exception 'Select a facility first.'; end if;
  perform pg_advisory_xact_lock(7429102);
  select * into caller from public.waitlist_players where facility_id=fid and user_id=auth.uid() and status in('current','waiting','sitout','rejoin') order by updated_at desc limit 1 for update;
  select * into target from public.waitlist_players where facility_id=fid and id=p_target_id for update;
  if caller.id is null then raise exception 'Player not found.'; end if;
  if target.id is null then raise exception 'Group member not found.'; end if;
  if caller.id=target.id then raise exception 'Use Leave Group to leave your own group.'; end if;
  if caller.group_id is null or target.group_id is null or caller.group_id<>target.group_id then raise exception 'You can only remove someone from your own group.'; end if;
  insert into public.group_notifications(facility_id,user_id,message) select fid,user_id,caller.display_name||' removed '||target.display_name||' from your group.' from public.waitlist_players where facility_id=fid and group_id=caller.group_id and user_id is not null;
  update public.waitlist_players set group_id=null,updated_at=now() where facility_id=fid and id=target.id;
  select count(*) into remaining_count from public.waitlist_players where facility_id=fid and group_id=caller.group_id;
  if remaining_count<=1 then update public.waitlist_players set group_id=null,updated_at=now() where facility_id=fid and group_id=caller.group_id; end if;
  return jsonb_build_object('message',target.display_name||' was removed from your group.');
end; $$;

create or replace function public.join_king_team(p_player_id uuid,p_team_id uuid default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare fid uuid:=public.current_facility_id(); player public.waitlist_players; target public.king_teams; old_team uuid; target_id uuid; member_count integer; next_pos bigint; next_no integer;
begin
  if fid is null then raise exception 'Select a facility first.'; end if;
  perform pg_advisory_xact_lock(7429201);
  select * into player from public.waitlist_players where facility_id=fid and id=p_player_id for update;
  if player.id is null or (player.user_id<>auth.uid() and not public.is_waitlist_operator()) then raise exception 'You cannot move that player.'; end if;
  old_team:=player.team_id;
  if p_team_id is null then
    select t.id into target_id from public.king_teams t where t.facility_id=fid and (select count(*) from public.waitlist_players p where p.facility_id=fid and p.team_id=t.id and p.status<>'left') between 1 and 5 order by case when t.status='current' then 0 else 1 end,coalesce(t.court_number,2147483647),coalesce(t.court_side,2147483647),t.queue_position,t.created_at limit 1;
    if target_id is not null then select * into target from public.king_teams where facility_id=fid and id=target_id for update;
    else
      select coalesce(max(queue_position),0)+1 into next_pos from public.king_teams where facility_id=fid and status='waiting';
      select coalesce(max((regexp_match(name,'[0-9]+'))[1]::integer),0)+1 into next_no from public.king_teams where facility_id=fid;
      insert into public.king_teams(facility_id,name,queue_position) values(fid,'Team '||next_no,next_pos) returning * into target;
    end if;
  else
    select * into target from public.king_teams where facility_id=fid and id=p_team_id for update;
    if target.id is null then raise exception 'That team is unavailable.'; end if;
    select count(*) into member_count from public.waitlist_players where facility_id=fid and team_id=target.id and status<>'left';
    if member_count>=6 then raise exception 'That team is full.'; end if;
  end if;
  update public.waitlist_players set team_id=target.id,status=target.status,court_number=target.court_number,updated_at=now() where facility_id=fid and id=player.id;
  if old_team is not null and old_team<>target.id and not exists(select 1 from public.waitlist_players where facility_id=fid and team_id=old_team and status<>'left') then delete from public.king_teams where facility_id=fid and id=old_team; end if;
  perform public.king_fill_courts();
  return jsonb_build_object('message','You joined '||public.king_team_label(target.id)||'.','team_id',target.id);
end; $$;

create or replace function public.join_new_king_team(p_player_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare fid uuid:=public.current_facility_id(); player public.waitlist_players; target public.king_teams; old_team uuid; next_pos bigint; next_no integer;
begin
  if fid is null then raise exception 'Select a facility first.'; end if;
  perform pg_advisory_xact_lock(7429201);
  select * into player from public.waitlist_players where facility_id=fid and id=p_player_id for update;
  if player.id is null or (player.user_id<>auth.uid() and not public.is_waitlist_operator()) then raise exception 'You cannot move that player.'; end if;
  old_team:=player.team_id;
  select coalesce(max(queue_position),0)+1 into next_pos from public.king_teams where facility_id=fid and status='waiting';
  select coalesce(max((regexp_match(name,'[0-9]+'))[1]::integer),0)+1 into next_no from public.king_teams where facility_id=fid;
  insert into public.king_teams(facility_id,name,status,queue_position,court_number,court_side,consecutive_wins) values(fid,'Team '||next_no,'waiting',next_pos,null,null,0) returning * into target;
  update public.waitlist_players set team_id=target.id,status='waiting',court_number=null,updated_at=now() where facility_id=fid and id=player.id;
  if old_team is not null and old_team<>target.id and not exists(select 1 from public.waitlist_players where facility_id=fid and team_id=old_team and status<>'left') then delete from public.king_teams where facility_id=fid and id=old_team; end if;
  perform public.king_fill_courts();
  return jsonb_build_object('message','You joined a new team.','team_id',target.id);
end; $$;

create or replace function public.king_prepare_player(p_player_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare fid uuid:=public.current_facility_id(); player public.waitlist_players; target public.king_teams; old_team uuid; member_count integer; next_member_position bigint; next_team_position bigint; next_team_number integer;
begin
  if fid is null then raise exception 'Select a facility first.'; end if;
  perform pg_advisory_xact_lock(7429201);
  select * into player from public.waitlist_players where facility_id=fid and id=p_player_id for update;
  if player.id is null or (player.user_id<>auth.uid() and not public.is_waitlist_operator()) then raise exception 'You cannot add that player.'; end if;
  old_team:=player.team_id;
  if old_team is not null and exists(select 1 from public.king_teams where facility_id=fid and id=old_team) then return jsonb_build_object('message','Player is already assigned.','team_id',old_team); end if;
  select t.* into target from public.king_teams t where t.facility_id=fid and t.status in ('current','waiting') and (select count(*) from public.waitlist_players p where p.facility_id=fid and p.team_id=t.id and p.status<>'left' and p.id<>player.id)<6 order by case when t.status='current' then 0 else 1 end,t.court_number asc nulls last,t.court_side asc nulls last,t.queue_position asc,t.created_at asc limit 1 for update;
  if target.id is null then
    select coalesce(max(queue_position),0)+1 into next_team_position from public.king_teams where facility_id=fid and status='waiting';
    select coalesce(max((regexp_match(name,'[0-9]+'))[1]::integer),0)+1 into next_team_number from public.king_teams where facility_id=fid;
    insert into public.king_teams(facility_id,name,queue_position) values(fid,'Team '||next_team_number,next_team_position) returning * into target;
  end if;
  select count(*) into member_count from public.waitlist_players where facility_id=fid and team_id=target.id and status<>'left' and id<>player.id;
  select coalesce(max(queue_position),0)+1 into next_member_position from public.waitlist_players where facility_id=fid and team_id=target.id and status<>'left' and id<>player.id;
  update public.waitlist_players set team_id=target.id,status=target.status,court_number=target.court_number,queue_position=next_member_position,updated_at=now() where facility_id=fid and id=player.id;
  if old_team is not null and old_team<>target.id and not exists(select 1 from public.waitlist_players where facility_id=fid and team_id=old_team and status<>'left') then delete from public.king_teams where facility_id=fid and id=old_team; end if;
  perform public.king_fill_courts();
  return jsonb_build_object('message','You joined '||public.king_team_label(target.id)||'.','team_id',target.id,'position',member_count+1);
end; $$;

grant execute on function public.admin_group_players(uuid[]) to authenticated;
grant execute on function public.admin_remove_player_from_group(uuid) to authenticated;
grant execute on function public.leave_player_group() to authenticated;
grant execute on function public.remove_player_from_group(uuid) to authenticated;
grant execute on function public.join_king_team(uuid,uuid) to authenticated;
grant execute on function public.join_new_king_team(uuid) to authenticated;
grant execute on function public.king_prepare_player(uuid) to authenticated;
commit;
