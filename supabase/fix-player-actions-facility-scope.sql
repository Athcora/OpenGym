-- Browser-executable walk-in, sit-out, leave, and geofence actions execute as
-- the runtime role. Keep their complete helper chain within the facility that
-- the caller selected, including queue normalization and notifications.

begin;

create or replace function public.normalize_active_waitlist()
returns void language plpgsql security definer set search_path=public as $$
declare
  fid uuid:=public.current_facility_id();
  c public.waitlist_config;
  candidate record;
  open_spots integer;
  split_group uuid;
  promoted_group uuid;
  split_members uuid[];
  split_size integer;
  remaining_size integer;
begin
  if fid is null then raise exception 'Select a facility first.'; end if;
  select * into c from public.waitlist_config where facility_id=fid and id;
  if c.facility_id is null then raise exception 'Facility configuration not found.'; end if;

  update public.waitlist_players set status='waiting'
    where facility_id=fid and status in ('current','waiting') and queue_position is not null;
  open_spots:=c.max_players;
  for candidate in
    select p.group_id,case when p.group_id is null then p.id end member_id,
      count(*)::integer member_count,min(p.queue_position) first_position
    from public.waitlist_players p
    where p.facility_id=fid and p.status='waiting' and p.queue_position is not null
    group by p.group_id,case when p.group_id is null then p.id end
    order by min(p.queue_position)
  loop
    if candidate.member_count<=open_spots then
      update public.waitlist_players p set status='current',updated_at=now()
        where p.facility_id=fid and (
          (candidate.group_id is not null and p.group_id=candidate.group_id) or
          (candidate.group_id is null and p.id=candidate.member_id)
        );
      open_spots:=open_spots-candidate.member_count;
    end if;
    exit when open_spots=0;
  end loop;

  if open_spots>0 then
    select p.group_id,count(*)::integer into split_group,remaining_size
      from public.waitlist_players p
      where p.facility_id=fid and p.status='waiting' and p.queue_position is not null and p.group_id is not null
      group by p.group_id having count(*)>open_spots
      order by min(p.queue_position) limit 1;
    if split_group is not null then
      select array_agg(chosen.id order by chosen.queue_position) into split_members
      from (
        select p.id,p.queue_position from public.waitlist_players p
        where p.facility_id=fid and p.status='waiting' and p.group_id=split_group
        order by p.queue_position,p.id limit open_spots
      ) chosen;
      split_size:=coalesce(array_length(split_members,1),0);
      remaining_size:=remaining_size-split_size;
      promoted_group:=case when split_size>1 then gen_random_uuid() else null end;
      insert into public.group_notifications(facility_id,user_id,message)
        select distinct fid,p.user_id,
          'Your group needed to split because there were not enough single players to make a full game. You have been placed into a smaller group so the current game can be filled.'
        from public.waitlist_players p
        where p.facility_id=fid and p.group_id=split_group and p.user_id is not null;
      update public.waitlist_players p set status='current',group_id=promoted_group,updated_at=now()
        where p.facility_id=fid and p.id=any(split_members);
      if remaining_size<2 then
        update public.waitlist_players p set group_id=null,updated_at=now()
          where p.facility_id=fid and p.group_id=split_group;
      end if;
    end if;
  end if;

  with ranked as (
    select id,row_number() over(order by queue_position,id) rn
    from public.waitlist_players
    where facility_id=fid and status in ('current','waiting','sitout') and queue_position is not null
  )
  update public.waitlist_players p set queue_position=ranked.rn
    from ranked where p.facility_id=fid and p.id=ranked.id;
end;
$$;

create or replace function public.log_waitlist_operator_action(p_event_type text,p_action text)
returns void language plpgsql security definer set search_path=public as $$
declare fid uuid:=public.current_facility_id(); actor text;
begin
  if fid is null then raise exception 'Select a facility first.'; end if;
  select display_name into actor from public.waitlist_players
    where facility_id=fid and user_id=auth.uid() and status in ('current','waiting','sitout','rejoin')
    order by updated_at desc limit 1;
  actor:=coalesce(actor,'Admin');
  insert into public.waitlist_events(facility_id,actor_user_id,actor_name,event_type,message)
    values(fid,auth.uid(),actor,p_event_type,actor||' '||p_action);
end;
$$;

create or replace function public.notify_waitlist_operator_player(p_user_id uuid,p_action text)
returns void language plpgsql security definer set search_path=public as $$
declare fid uuid:=public.current_facility_id(); actor_label text;
begin
  if fid is null or p_user_id is null then return; end if;
  if not exists(select 1 from public.waitlist_players where facility_id=fid and user_id=p_user_id) then return; end if;
  actor_label:=case when exists(
    select 1 from public.waitlist_players
    where facility_id=fid and user_id=auth.uid() and is_host and status in ('current','waiting','sitout','rejoin')
  ) then 'A host' else 'An admin' end;
  insert into public.group_notifications(facility_id,user_id,message)
    values(fid,p_user_id,'OPERATOR_ACTION|'||actor_label||' '||p_action);
end;
$$;

create or replace function public.admin_add_player(p_first_name text,p_last_name text default '')
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  fid uuid:=public.current_facility_id();
  clean_first text:=public.clean_player_name(p_first_name);
  clean_last text:=public.clean_player_name(p_last_name);
  shown_name text;
  next_position bigint;
  player public.waitlist_players;
begin
  if fid is null or not public.is_waitlist_operator() then raise exception 'Admin or host access required.'; end if;
  if clean_first='' then raise exception 'Enter a name containing letters.'; end if;
  if not public.name_is_allowed(clean_first,clean_last) then raise exception 'This name is not allowed. Choose a different one.'; end if;
  perform pg_advisory_xact_lock(7429101);
  if clean_last='' and exists(
    select 1 from public.waitlist_players
    where facility_id=fid and lower(first_name)=lower(clean_first) and status<>'left'
  ) then raise exception 'Another player has that first name. Add a last initial or last name.'; end if;
  shown_name:=clean_first||case when clean_last='' then '' else ' '||left(clean_last,1)||'.' end;
  if exists(select 1 from public.waitlist_players where facility_id=fid and lower(display_name)=lower(shown_name) and status<>'left') then
    shown_name:=clean_first||' '||clean_last;
  end if;
  perform public.save_admin_undo('add player');
  select coalesce(max(queue_position),0)+1 into next_position
    from public.waitlist_players where facility_id=fid and status in ('current','waiting','sitout','rejoin');
  insert into public.waitlist_players(facility_id,user_id,first_name,last_name,display_name,status,queue_position,court_number,updated_at)
    values(fid,null,clean_first,clean_last,shown_name,'waiting',next_position,null,now()) returning * into player;
  perform public.fill_open_court_slots();
  select * into player from public.waitlist_players where facility_id=fid and id=player.id;
  perform public.log_waitlist_operator_action('add_player','added '||shown_name||case when player.status='current' then ' to Court '||player.court_number||'.' else ' to the waitlist.' end);
  return jsonb_build_object('message',shown_name||case when player.status='current' then ' joined Court '||player.court_number||'.' else ' joined the waitlist.' end,'player_id',player.id);
end;
$$;

create or replace function public.admin_set_player_sitout(p_player_id uuid,p_skip_game integer default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare fid uuid:=public.current_facility_id(); player public.waitlist_players; current_game integer; skipped_game integer;
begin
  if fid is null or not public.is_waitlist_operator() then raise exception 'Admin or host access required.'; end if;
  select * into player from public.waitlist_players
    where facility_id=fid and id=p_player_id and status in ('current','waiting') for update;
  if player.id is null then raise exception 'This player is no longer active.'; end if;
  perform public.save_admin_undo('sit out player');
  if player.status='current' and player.court_number is not null then
    select game_number into current_game from public.waitlist_courts where facility_id=fid and court_number=player.court_number;
  end if;
  if current_game is null then select game_number into current_game from public.waitlist_config where facility_id=fid and id; end if;
  skipped_game:=case when player.status='current' then current_game else greatest(coalesce(p_skip_game,current_game+1),current_game+1) end;
  update public.waitlist_players set status='sitout',sitout_priority=true,sitout_from_game=skipped_game,updated_at=now()
    where facility_id=fid and id=player.id;
  perform public.normalize_active_waitlist();
  perform public.notify_waitlist_operator_player(player.user_id,'made you sit out for one game.');
  perform public.log_waitlist_operator_action('admin_sitout','sat out '||player.display_name||' for one game.');
  return jsonb_build_object('message',case when player.status='current'
    then player.display_name||' left the current game and has priority for the next game.'
    else player.display_name||' will skip Game '||skipped_game||' and have priority for Game '||(skipped_game+1)||'.' end);
end;
$$;

create or replace function public.admin_unsit_player(p_player_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare fid uuid:=public.current_facility_id(); player public.waitlist_players;
begin
  perform pg_advisory_xact_lock(7429102);
  if fid is null or not public.is_waitlist_operator() then raise exception 'Admin or host access required.'; end if;
  select * into player from public.waitlist_players
    where facility_id=fid and id=p_player_id and status='sitout' for update;
  if player.id is null then raise exception 'This player is not currently sitting out.'; end if;
  perform public.save_admin_undo('unsit player');
  update public.waitlist_players set status='waiting',sitout_priority=false,sitout_from_game=null,updated_at=now()
    where facility_id=fid and id=player.id;
  perform public.normalize_active_waitlist();
  perform public.notify_waitlist_operator_player(player.user_id,'reversed your sit-out.');
  perform public.log_waitlist_operator_action('admin_unsit','reversed the sit-out for '||player.display_name||'.');
  return jsonb_build_object('message',player.display_name||'''s sit-out was reversed.');
end;
$$;

create or replace function public.admin_leave_player(p_player_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare fid uuid:=public.current_facility_id(); player public.waitlist_players; remaining_group_members integer;
begin
  if fid is null or not public.is_waitlist_operator() then raise exception 'Admin or host access required.'; end if;
  select * into player from public.waitlist_players where facility_id=fid and id=p_player_id and status<>'left' for update;
  if player.id is null then raise exception 'This player has already left.'; end if;
  perform public.save_admin_undo('remove player');
  update public.waitlist_players set status='left',queue_position=null,group_id=null,rejoin_expires_at=null,updated_at=now()
    where facility_id=fid and id=player.id;
  perform public.notify_waitlist_operator_player(player.user_id,'removed you from the waitlist.');
  if player.group_id is not null then
    select count(*) into remaining_group_members from public.waitlist_players
      where facility_id=fid and group_id=player.group_id and status in ('current','waiting','sitout');
    if remaining_group_members<2 then
      update public.waitlist_players set group_id=null,updated_at=now() where facility_id=fid and group_id=player.group_id;
    end if;
  end if;
  perform public.normalize_active_waitlist();
  perform public.log_waitlist_operator_action('admin_leave','removed '||player.display_name||' from the waitlist.');
  return jsonb_build_object('message',player.display_name||' left the waitlist.');
end;
$$;

create or replace function public.sit_out_one_game(p_skip_game integer default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare fid uuid:=public.current_facility_id(); player public.waitlist_players; current_game integer; skipped_game integer;
begin
  perform pg_advisory_xact_lock(7429102);
  if fid is null then raise exception 'Select a facility first.'; end if;
  select * into player from public.waitlist_players
    where facility_id=fid and user_id=auth.uid() and status in ('current','waiting') for update;
  if player.id is null then raise exception 'You are no longer active in the waitlist.'; end if;
  if player.status='current' and player.court_number is not null then
    select game_number into current_game from public.waitlist_courts where facility_id=fid and court_number=player.court_number;
  end if;
  if current_game is null then select game_number into current_game from public.waitlist_config where facility_id=fid and id; end if;
  skipped_game:=case when player.status='current' then current_game else greatest(coalesce(p_skip_game,current_game+1),current_game+1) end;
  update public.waitlist_players set status='sitout',sitout_priority=true,sitout_from_game=skipped_game,updated_at=now()
    where facility_id=fid and id=player.id;
  perform public.normalize_active_waitlist();
  return jsonb_build_object('message',case when player.status='current'
    then 'Leaving the current game counts as your sit-out. You have priority for the next game.'
    else 'You will skip Game '||skipped_game||' and have priority for Game '||(skipped_game+1)||'.' end,
    'skipped_game',skipped_game,'priority_game',skipped_game+1);
end;
$$;

create or replace function public.sit_out_and_leave_group(p_skip_game integer default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare fid uuid:=public.current_facility_id(); caller public.waitlist_players; previous_group uuid; remaining_count integer; current_game integer; skipped_game integer;
begin
  perform pg_advisory_xact_lock(7429102);
  if fid is null then raise exception 'Select a facility first.'; end if;
  select * into caller from public.waitlist_players
    where facility_id=fid and user_id=auth.uid() and status in ('current','waiting') for update;
  if caller.id is null then raise exception 'You are no longer active in the waitlist.'; end if;
  if caller.group_id is null then raise exception 'You are not currently in a group.'; end if;
  previous_group:=caller.group_id;
  if caller.status='current' and caller.court_number is not null then
    select game_number into current_game from public.waitlist_courts where facility_id=fid and court_number=caller.court_number;
  end if;
  if current_game is null then select game_number into current_game from public.waitlist_config where facility_id=fid and id; end if;
  skipped_game:=case when caller.status='current' then current_game else greatest(coalesce(p_skip_game,current_game+1),current_game+1) end;
  insert into public.group_notifications(facility_id,user_id,message)
    select fid,user_id,caller.display_name||' left your group to sit out one game.'
    from public.waitlist_players where facility_id=fid and group_id=previous_group and id<>caller.id and user_id is not null;
  update public.waitlist_players set group_id=null,status='sitout',sitout_priority=true,sitout_from_game=skipped_game,updated_at=now()
    where facility_id=fid and id=caller.id;
  select count(*) into remaining_count from public.waitlist_players where facility_id=fid and group_id=previous_group;
  if remaining_count<=1 then update public.waitlist_players set group_id=null,updated_at=now() where facility_id=fid and group_id=previous_group; end if;
  perform public.normalize_active_waitlist();
  return jsonb_build_object('message',case when caller.status='current'
    then 'You left the group and current game. This counts as your sit-out, and you have priority for the next game.'
    else 'You left the group, will skip Game '||skipped_game||', and have priority for Game '||(skipped_game+1)||'.' end);
end;
$$;

create or replace function public.remove_self_for_geofence()
returns jsonb language plpgsql security definer set search_path=public as $$
declare fid uuid:=public.current_facility_id(); p public.waitlist_players; c public.waitlist_config; prompt public.geofence_return_prompts; remaining integer;
begin
  if fid is null then raise exception 'Select a facility first.'; end if;
  if public.is_waitlist_admin() then raise exception 'This return window is only for players.'; end if;
  select * into c from public.waitlist_config where facility_id=fid and id;
  if not c.geofence_enabled then raise exception 'The facility location check is not active for this waitlist.'; end if;
  select * into p from public.waitlist_players where facility_id=fid and user_id=auth.uid() for update;
  if p.id is null then raise exception 'Player not found.'; end if;
  select * into prompt from public.geofence_return_prompts
    where facility_id=fid and player_id=p.id and resolved_at is null and expires_at>now()
    order by removed_at desc limit 1;
  if prompt.id is not null then return jsonb_build_object('id',prompt.id,'removed_at',prompt.removed_at,'saved_position_until',prompt.saved_position_until,'expires_at',prompt.expires_at); end if;
  if p.status not in ('current','waiting','sitout') or p.queue_position is null then raise exception 'You are not currently in the waitlist.'; end if;
  insert into public.geofence_return_prompts(facility_id,player_id,user_id,original_status,original_position)
    values(fid,p.id,auth.uid(),p.status,p.queue_position) returning * into prompt;
  update public.waitlist_players set status='left',queue_position=null,group_id=null,rejoin_expires_at=null,updated_at=now()
    where facility_id=fid and id=p.id;
  if p.group_id is not null then
    select count(*) into remaining from public.waitlist_players
      where facility_id=fid and group_id=p.group_id and status in ('current','waiting','sitout');
    if remaining<2 then update public.waitlist_players set group_id=null,updated_at=now() where facility_id=fid and group_id=p.group_id; end if;
  end if;
  if c.mode not in ('teams','teams_rejoin') then perform public.normalize_active_waitlist(); end if;
  insert into public.waitlist_events(facility_id,actor_user_id,actor_name,event_type,message)
    values(fid,auth.uid(),p.display_name,'geofence_leave',p.display_name||' was removed after leaving the facility area.');
  return jsonb_build_object('id',prompt.id,'removed_at',prompt.removed_at,'saved_position_until',prompt.saved_position_until,'expires_at',prompt.expires_at);
end;
$$;

notify pgrst, 'reload schema';
commit;
