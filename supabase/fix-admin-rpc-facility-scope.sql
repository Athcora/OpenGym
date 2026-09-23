-- Browser-executable admin actions run as the runtime role.  Their target
-- rows and every supporting queue/team mutation must therefore be bound to
-- the facility selected in user_facility_sessions, rather than relying on
-- RLS or on globally unique-looking player ids.

create or replace function public.admin_move_player(p_player_id uuid,p_status text,p_index integer,p_court_number integer)
returns jsonb language plpgsql security definer set search_path=public as $$
declare player public.waitlist_players; source_court integer; destination_court integer; moving_count integer;
  v_max_players integer; target_position bigint; open_spots integer; candidate record; fid uuid:=public.current_facility_id();
begin
  if fid is null or not public.is_waitlist_operator() then raise exception 'Admin or host access required.'; end if;
  if p_status not in ('current','waiting') then raise exception 'Invalid destination.'; end if;
  perform pg_advisory_xact_lock(7429101);
  select * into player from public.waitlist_players where facility_id=fid and id=p_player_id for update;
  if player.id is null then raise exception 'Player not found.'; end if;
  source_court:=player.court_number; destination_court:=case when p_status='current' then coalesce(p_court_number,source_court,1) else null end;
  select max_players into v_max_players from public.waitlist_config where facility_id=fid and id;
  select count(*) into moving_count from public.waitlist_players where facility_id=fid and (id=player.id or (player.group_id is not null and group_id=player.group_id));
  if moving_count>v_max_players then raise exception 'This group is larger than a court.'; end if;
  perform public.save_admin_undo('move player');
  update public.waitlist_players set queue_position=queue_position*1000 where facility_id=fid and status in ('current','waiting','sitout') and queue_position is not null;
  if p_status='waiting' then
    select queue_position into target_position from public.waitlist_players where facility_id=fid and status in ('waiting','sitout') and id<>player.id and (player.group_id is null or group_id is distinct from player.group_id) order by queue_position offset greatest(p_index,0) limit 1;
    if target_position is null then select coalesce(max(queue_position),0)+1000 into target_position from public.waitlist_players where facility_id=fid and status in ('current','waiting','sitout'); end if;
    with moving as (select id,row_number() over(order by queue_position,id) rn from public.waitlist_players where facility_id=fid and (id=player.id or (player.group_id is not null and group_id=player.group_id)))
    update public.waitlist_players p set status='waiting',court_number=null,queue_position=target_position-moving_count+moving.rn-1,updated_at=now() from moving where p.facility_id=fid and p.id=moving.id;
  else
    select queue_position into target_position from public.waitlist_players where facility_id=fid and status='current' and court_number=destination_court and id<>player.id and (player.group_id is null or group_id is distinct from player.group_id) order by queue_position offset greatest(p_index,0) limit 1;
    if target_position is null then select coalesce(max(queue_position),0)+1000 into target_position from public.waitlist_players where facility_id=fid and status='current' and court_number=destination_court; end if;
    with moving as (select id,row_number() over(order by queue_position,id) rn from public.waitlist_players where facility_id=fid and (id=player.id or (player.group_id is not null and group_id=player.group_id)))
    update public.waitlist_players p set status='current',court_number=destination_court,sitout_priority=false,queue_position=target_position-moving_count+moving.rn-1,updated_at=now() from moving where p.facility_id=fid and p.id=moving.id;
    with ranked as (select id,row_number() over(order by queue_position,id) rn from public.waitlist_players where facility_id=fid and status='current' and court_number=destination_court), displaced as (select p.id,row_number() over(order by p.queue_position,p.id) rn from public.waitlist_players p join ranked r on r.id=p.id where p.facility_id=fid and r.rn>v_max_players), queue_head as (select coalesce(min(queue_position),1000000) head from public.waitlist_players where facility_id=fid and status in ('waiting','sitout'))
    update public.waitlist_players p set status='waiting',court_number=null,queue_position=queue_head.head-moving_count+displaced.rn-1,updated_at=now() from displaced cross join queue_head where p.facility_id=fid and p.id=displaced.id;
  end if;
  if source_court is not null and source_court is distinct from destination_court then
    select greatest(v_max_players-count(p.id),0) into open_spots from public.waitlist_config cfg left join public.waitlist_players p on p.facility_id=fid and p.status='current' and p.court_number=source_court where cfg.facility_id=fid and cfg.id group by cfg.max_players;
    for candidate in select coalesce(group_id,id) block_id,count(*)::integer block_size from public.waitlist_players where facility_id=fid and status='waiting' and id<>player.id and (player.group_id is null or group_id is distinct from player.group_id) group by coalesce(group_id,id) order by min(queue_position) loop
      if candidate.block_size<=open_spots then update public.waitlist_players set status='current',court_number=source_court,sitout_priority=false,updated_at=now() where facility_id=fid and status='waiting' and coalesce(group_id,id)=candidate.block_id; open_spots:=open_spots-candidate.block_size; end if;
      exit when open_spots=0;
    end loop;
  end if;
  with ranked as (select id,row_number() over(order by case when status='current' then 0 else 1 end,coalesce(court_number,999),queue_position,id) rn from public.waitlist_players where facility_id=fid and status in ('current','waiting','sitout') and queue_position is not null)
  update public.waitlist_players p set queue_position=ranked.rn from ranked where p.facility_id=fid and p.id=ranked.id;
  return jsonb_build_object('message','Player moved.','source_court',source_court,'destination_court',destination_court);
end $$;

create or replace function public.admin_move_king_player(p_player_id uuid,p_target_team_id uuid,p_target_index integer)
returns jsonb language plpgsql security definer set search_path=public as $$
declare moving public.waitlist_players; target public.king_teams; old_team_id uuid; target_count integer; member_id uuid; ordered_ids uuid[]; position_base bigint; item_index integer; fid uuid:=public.current_facility_id();
begin
  if fid is null or not public.is_waitlist_operator() then raise exception 'Admin or host access required.'; end if;
  perform pg_advisory_xact_lock(7429201);
  select * into moving from public.waitlist_players where facility_id=fid and id=p_player_id for update;
  select * into target from public.king_teams where facility_id=fid and id=p_target_team_id for update;
  if moving.id is null then raise exception 'That player is unavailable.'; end if; if target.id is null then raise exception 'That team is unavailable.'; end if;
  old_team_id:=moving.team_id;
  select count(*) into target_count from public.waitlist_players where facility_id=fid and team_id=target.id and status<>'left' and id<>moving.id;
  if target_count>=6 then raise exception 'That team is full.'; end if;
  select coalesce(array_agg(id order by queue_position,id),'{}'::uuid[]) into ordered_ids from public.waitlist_players where facility_id=fid and team_id=target.id and status<>'left' and id<>moving.id;
  p_target_index:=greatest(0,least(coalesce(p_target_index,target_count),target_count)); ordered_ids:=coalesce(ordered_ids[1:p_target_index],'{}'::uuid[])||array[moving.id]||coalesce(ordered_ids[p_target_index+1:coalesce(array_length(ordered_ids,1),0)],'{}'::uuid[]); position_base:=coalesce(target.queue_position,0)*100; item_index:=0;
  foreach member_id in array ordered_ids loop update public.waitlist_players set team_id=target.id,status=target.status,court_number=target.court_number,queue_position=position_base+item_index,updated_at=now() where facility_id=fid and id=member_id; item_index:=item_index+1; end loop;
  if old_team_id is not null and old_team_id<>target.id and not exists(select 1 from public.waitlist_players where facility_id=fid and team_id=old_team_id and status<>'left') then delete from public.king_teams where facility_id=fid and id=old_team_id; end if;
  perform public.king_fill_courts(); return jsonb_build_object('message','Player moved.','team_id',target.id);
end $$;

create or replace function public.admin_move_king_player_to_empty(p_player_id uuid,p_target_status text,p_court_number integer default null,p_court_side integer default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare target_id uuid; old_team_id uuid; next_team_number integer; next_queue_position bigint; fid uuid:=public.current_facility_id();
begin
  if fid is null or not public.is_waitlist_operator() then raise exception 'Admin or host access required.'; end if;
  if p_target_status not in ('current','waiting') then raise exception 'Invalid team destination.'; end if; if p_target_status='current' and (p_court_number is null or p_court_side not in(1,2)) then raise exception 'Invalid court destination.'; end if;
  perform pg_advisory_xact_lock(7429201);
  if p_target_status='current' then select id into target_id from public.king_teams where facility_id=fid and status='current' and court_number=p_court_number and court_side=p_court_side order by created_at limit 1 for update; end if;
  if target_id is null then
    select coalesce(max((regexp_match(name,'[0-9]+'))[1]::integer),0)+1 into next_team_number from public.king_teams where facility_id=fid;
    select coalesce(max(queue_position),0)+1 into next_queue_position from public.king_teams where facility_id=fid and status='waiting';
    insert into public.king_teams(facility_id,name,status,queue_position,court_number,court_side,consecutive_wins) values(fid,'Team '||next_team_number,p_target_status,case when p_target_status='waiting' then next_queue_position else 0 end,case when p_target_status='current' then p_court_number else null end,case when p_target_status='current' then p_court_side else null end,0) returning id into target_id;
  end if;
  select team_id into old_team_id from public.waitlist_players where facility_id=fid and id=p_player_id for update; if old_team_id is null then raise exception 'That player is unavailable.'; end if;
  update public.waitlist_players set team_id=target_id,status=p_target_status,court_number=case when p_target_status='current' then p_court_number else null end,queue_position=case when p_target_status='waiting' then next_queue_position*100 else 0 end,updated_at=now() where facility_id=fid and id=p_player_id;
  if old_team_id<>target_id and not exists(select 1 from public.waitlist_players where facility_id=fid and team_id=old_team_id and status<>'left') then delete from public.king_teams where facility_id=fid and id=old_team_id; end if;
  return jsonb_build_object('message','Player moved.','team_id',target_id);
end $$;

create or replace function public.swap_waitlist_players(p_first_id uuid,p_second_id uuid)
returns void language plpgsql security definer set search_path=public as $$
declare first_player public.waitlist_players; second_player public.waitlist_players; first_group uuid; second_group uuid; member_count integer; status_count integer; court_count integer; position_span bigint; fid uuid:=public.current_facility_id();
begin
  if fid is null then raise exception 'Select a facility first.'; end if;
  select * into first_player from public.waitlist_players where facility_id=fid and id=p_first_id and status in ('current','waiting','sitout') for update;
  select * into second_player from public.waitlist_players where facility_id=fid and id=p_second_id and status in ('current','waiting','sitout') for update;
  if first_player.id is null or second_player.id is null then raise exception 'Both players must still be in the current game or waitlist.'; end if; if first_player.id=second_player.id then raise exception 'Choose two different players.'; end if;
  first_group:=first_player.group_id; second_group:=second_player.group_id;
  update public.waitlist_players set status=case when id=first_player.id then second_player.status else first_player.status end,queue_position=case when id=first_player.id then second_player.queue_position else first_player.queue_position end,court_number=case when id=first_player.id then second_player.court_number else first_player.court_number end,team_id=case when id=first_player.id then second_player.team_id else first_player.team_id end,sitout_priority=case when id=first_player.id then second_player.sitout_priority else first_player.sitout_priority end,sitout_from_game=case when id=first_player.id then second_player.sitout_from_game else first_player.sitout_from_game end,updated_at=now() where facility_id=fid and id in(first_player.id,second_player.id);
  if first_group is not null and first_group is distinct from second_group then select count(*),count(distinct status),count(distinct coalesce(court_number,0)),max(queue_position)-min(queue_position)+1 into member_count,status_count,court_count,position_span from public.waitlist_players where facility_id=fid and group_id=first_group; if member_count<2 or status_count<>1 or court_count<>1 or position_span<>member_count then update public.waitlist_players set group_id=null,updated_at=now() where facility_id=fid and id=first_player.id; end if; end if;
  if second_group is not null and second_group is distinct from first_group then select count(*),count(distinct status),count(distinct coalesce(court_number,0)),max(queue_position)-min(queue_position)+1 into member_count,status_count,court_count,position_span from public.waitlist_players where facility_id=fid and group_id=second_group; if member_count<2 or status_count<>1 or court_count<>1 or position_span<>member_count then update public.waitlist_players set group_id=null,updated_at=now() where facility_id=fid and id=second_player.id; end if; end if;
  if first_group is not null and (select count(*) from public.waitlist_players where facility_id=fid and group_id=first_group)<=1 then update public.waitlist_players set group_id=null,updated_at=now() where facility_id=fid and group_id=first_group; end if;
  if second_group is not null and second_group is distinct from first_group and (select count(*) from public.waitlist_players where facility_id=fid and group_id=second_group)<=1 then update public.waitlist_players set group_id=null,updated_at=now() where facility_id=fid and group_id=second_group; end if;
  insert into public.waitlist_events(facility_id,actor_user_id,actor_name,event_type,message) select fid,p.user_id,p.display_name,'substitute',p.display_name||' swapped positions with '||case when p.id=first_player.id then second_player.display_name else first_player.display_name end||'.' from public.waitlist_players p where p.facility_id=fid and p.id in(first_player.id,second_player.id) and p.user_id is not null;
end $$;

create or replace function public.admin_substitute_players(p_first_id uuid,p_second_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare first_name text; second_name text; fid uuid:=public.current_facility_id();
begin
  if fid is null or not public.is_waitlist_operator() then raise exception 'Admin or host access required.'; end if;
  select display_name into first_name from public.waitlist_players where facility_id=fid and id=p_first_id; select display_name into second_name from public.waitlist_players where facility_id=fid and id=p_second_id;
  if first_name is null or second_name is null then raise exception 'Both players must belong to this facility.'; end if;
  perform pg_advisory_xact_lock(7429102); perform public.save_admin_undo('substitute players'); perform public.swap_waitlist_players(p_first_id,p_second_id);
  perform public.notify_waitlist_operator_player(p.user_id,'substituted your position with another player.') from public.waitlist_players p where p.facility_id=fid and p.id in(p_first_id,p_second_id);
  perform public.log_waitlist_operator_action('admin_substitute','substituted '||first_name||' with '||second_name||'.'); return jsonb_build_object('message','The players successfully swapped positions.');
end $$;

create or replace function public.save_operator_undo(p_label text)
returns jsonb language plpgsql security definer set search_path=public as $$
begin
  if public.current_facility_id() is null or not public.is_waitlist_operator() then raise exception 'Admin or host access required.'; end if;
  perform public.save_admin_undo(p_label); return jsonb_build_object('saved',true);
end $$;

create or replace function public.admin_set_court_count(p_court_count integer)
returns jsonb language plpgsql security definer set search_path=public as $$
declare cfg public.waitlist_config; old_count integer; court record; team_row record; next_game integer; existing_count integer; moved_team_count integer:=0; priority_offset integer:=0; fid uuid:=public.current_facility_id();
begin
  if fid is null or not public.is_waitlist_operator() then raise exception 'Admin or host access required.'; end if;
  if p_court_count<1 or p_court_count>12 then raise exception 'Choose between 1 and 12 courts.'; end if;
  perform pg_advisory_xact_lock(7429101);
  select * into cfg from public.waitlist_config where facility_id=fid and id for update;
  if cfg.id is null then raise exception 'Facility configuration not found.'; end if;
  select count(*) into existing_count from public.waitlist_courts where facility_id=fid; old_count:=existing_count;
  if old_count=p_court_count and not exists(select 1 from generate_series(1,p_court_count) expected(court_number) left join public.waitlist_courts actual on actual.facility_id=fid and actual.court_number=expected.court_number where actual.court_number is null) then
    update public.waitlist_config set court_count=p_court_count,updated_at=now() where facility_id=fid and id;
    return jsonb_build_object('message',p_court_count||' court(s) are active.');
  end if;
  perform public.save_admin_undo('change number of courts');
  if p_court_count<old_count and cfg.mode in('teams','teams_rejoin') then
    select count(*) into moved_team_count from public.king_teams t where t.facility_id=fid and t.status='current' and t.court_number in(select c.court_number from public.waitlist_courts c where c.facility_id=fid order by c.started_at desc,c.game_number desc limit(old_count-p_court_count));
    update public.king_teams set queue_position=queue_position+moved_team_count where facility_id=fid and status='waiting';
    for court in select * from public.waitlist_courts where facility_id=fid order by started_at desc,game_number desc limit(old_count-p_court_count) loop
      for team_row in select * from public.king_teams where facility_id=fid and status='current' and court_number=court.court_number order by court_side,created_at,id loop
        priority_offset:=priority_offset+1;
        update public.king_teams set status='waiting',queue_position=priority_offset,court_number=null,court_side=null,consecutive_wins=0,updated_at=now() where facility_id=fid and id=team_row.id;
        update public.waitlist_players set status=case when status='current' then 'waiting' else status end,court_number=null,updated_at=now() where facility_id=fid and team_id=team_row.id and status<>'left';
      end loop;
      delete from public.waitlist_courts where facility_id=fid and court_number=court.court_number;
    end loop;
    perform public.king_compact_queue();
  elsif p_court_count<old_count then
    for court in select * from public.waitlist_courts where facility_id=fid order by started_at desc,game_number desc limit(old_count-p_court_count) loop
      update public.waitlist_players set queue_position=queue_position*1000 where facility_id=fid and status in('waiting','sitout');
      with moved as(select id,row_number()over(order by queue_position,id) rn from public.waitlist_players where facility_id=fid and status='current' and court_number=court.court_number)
      update public.waitlist_players p set status='waiting',court_number=null,queue_position=moved.rn,updated_at=now() from moved where p.facility_id=fid and p.id=moved.id;
      delete from public.waitlist_courts where facility_id=fid and court_number=court.court_number;
    end loop;
    with ranked as(select id,row_number()over(order by queue_position,id) rn from public.waitlist_players where facility_id=fid and status in('current','waiting','sitout') and queue_position is not null) update public.waitlist_players p set queue_position=ranked.rn from ranked where p.facility_id=fid and p.id=ranked.id;
  else
    next_game:=greatest((select coalesce(max(game_number),0) from public.waitlist_courts where facility_id=fid),(select coalesce(max(game_number),0) from public.past_games where facility_id=fid));
    for court in select expected.court_number from generate_series(1,p_court_count) expected(court_number) left join public.waitlist_courts actual on actual.facility_id=fid and actual.court_number=expected.court_number where actual.court_number is null order by expected.court_number loop
      next_game:=next_game+1;
      insert into public.waitlist_courts(facility_id,court_number,game_number,started_at) values(fid,court.court_number,next_game,now()) on conflict(facility_id,court_number) do update set game_number=excluded.game_number,started_at=excluded.started_at;
    end loop;
    update public.waitlist_config set game_number=next_game where facility_id=fid and id;
  end if;
  update public.waitlist_config set court_count=p_court_count,updated_at=now() where facility_id=fid and id;
  if cfg.mode in('teams','teams_rejoin') then perform public.king_fill_courts(); else perform public.fill_open_court_slots(); end if;
  perform public.log_waitlist_operator_action('court_count','changed the number of courts to '||p_court_count||'.');
  return jsonb_build_object('message',p_court_count||' court(s) are now active.');
end $$;

notify pgrst, 'reload schema';
