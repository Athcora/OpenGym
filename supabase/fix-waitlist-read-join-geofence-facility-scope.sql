begin;

create or replace function public.admin_list_waitlist_history()
returns table(id bigint,actor_name text,event_type text,message text,created_at timestamptz)
language plpgsql security definer set search_path=public as $$
declare fid uuid:=public.current_facility_id();
begin
  if not public.is_waitlist_operator() then raise exception 'Admin or host access required.'; end if;
  return query select e.id,e.actor_name,e.event_type,e.message,e.created_at
    from public.waitlist_events e where e.facility_id=fid order by e.created_at desc limit 250;
end; $$;

create or replace function public.join_waitlist(p_first_name text,p_last_name text default '')
returns jsonb language plpgsql security definer set search_path=public as $$
declare fid uuid:=public.current_facility_id(); clean_first text:=public.clean_player_name(p_first_name); clean_last text:=public.clean_player_name(p_last_name); player public.waitlist_players; active_count integer; next_position bigint; shown_name text;
begin
  if auth.uid() is null then raise exception 'You must be signed in.'; end if;
  if fid is null then raise exception 'Select a facility first.'; end if;
  if clean_first='' then raise exception 'Enter a name containing letters.'; end if;
  if not public.name_is_allowed(clean_first,clean_last) then raise exception 'This name is not allowed. Choose a different one.'; end if;
  perform pg_advisory_xact_lock(7429101);
  select * into player from public.waitlist_players where facility_id=fid and user_id=auth.uid() for update;
  if player.id is not null and player.status<>'left' then return jsonb_build_object('message','You are already in the waitlist.','player_id',player.id); end if;
  if clean_last='' and exists(select 1 from public.waitlist_players where facility_id=fid and lower(first_name)=lower(clean_first) and status<>'left') then raise exception 'Another player has that first name. Add a last initial or last name.'; end if;
  shown_name:=clean_first||case when clean_last='' then '' else ' '||left(clean_last,1)||'.' end;
  if exists(select 1 from public.waitlist_players where facility_id=fid and lower(display_name)=lower(shown_name) and status<>'left') then shown_name:=clean_first||' '||clean_last; end if;
  select coalesce(max(queue_position),0)+1 into next_position from public.waitlist_players where facility_id=fid and status in('current','waiting','sitout','rejoin');
  insert into public.waitlist_players(facility_id,user_id,first_name,last_name,display_name,status,queue_position,court_number,updated_at)
  values(fid,auth.uid(),clean_first,clean_last,shown_name,'waiting',next_position,null,now())
  on conflict(facility_id,user_id) do update set first_name=excluded.first_name,last_name=excluded.last_name,display_name=excluded.display_name,status='waiting',queue_position=excluded.queue_position,court_number=null,rejoin_expires_at=null,updated_at=now() returning * into player;
  perform public.fill_open_court_slots();
  select * into player from public.waitlist_players where facility_id=fid and id=player.id;
  select count(*) into active_count from public.waitlist_players where facility_id=fid and status<>'left';
  return jsonb_build_object('message',shown_name||case when player.status='current' then ' joined Court '||player.court_number||'.' else ' joined the waitlist.' end,'player_id',player.id,'active_count',active_count);
end; $$;

create or replace function public.rejoin_waitlist_at_back()
returns jsonb language plpgsql security definer set search_path=public as $$
declare fid uuid:=public.current_facility_id(); player public.waitlist_players; old_team_id uuid; cfg public.waitlist_config; joined jsonb;
begin
  if auth.uid() is null then raise exception 'You must be signed in.'; end if;
  if fid is null then raise exception 'Select a facility first.'; end if;
  perform pg_advisory_xact_lock(7429101);
  select * into player from public.waitlist_players where facility_id=fid and user_id=auth.uid() for update;
  if player.id is null then raise exception 'Your previous player record was not found. Please log out and join normally.'; end if;
  if player.status in ('current','waiting','sitout') then return jsonb_build_object('message','You are already in the waitlist.','player_id',player.id); end if;
  old_team_id:=player.team_id;
  update public.waitlist_players set status='left',queue_position=null,team_id=null,court_number=null,group_id=null,rejoin_expires_at=null,sitout_priority=false,sitout_from_game=null,updated_at=now() where facility_id=fid and id=player.id;
  update public.rejoin_responses set choice='leave',answered_at=now() where facility_id=fid and user_id=auth.uid() and choice is null;
  if old_team_id is not null and not exists(select 1 from public.waitlist_players where facility_id=fid and team_id=old_team_id and status<>'left') then delete from public.king_teams where facility_id=fid and id=old_team_id; end if;
  joined:=public.join_waitlist(player.first_name,player.last_name);
  select * into cfg from public.waitlist_config where facility_id=fid and id;
  if cfg.mode in ('teams','teams_rejoin') then perform public.king_prepare_player(player.id); end if;
  return joined||jsonb_build_object('message','You rejoined at the back of the waitlist.');
end; $$;

create or replace function public.rename_waitlist_player(p_player_id uuid,p_first_name text,p_last_name text default '')
returns jsonb language plpgsql security definer set search_path=public as $$
declare fid uuid:=public.current_facility_id(); player public.waitlist_players; clean_first text:=initcap(public.clean_player_name(p_first_name)); clean_last text:=initcap(public.clean_player_name(p_last_name)); shown_name text; same_first boolean;
begin
  if fid is null then raise exception 'Select a facility first.'; end if;
  select * into player from public.waitlist_players where facility_id=fid and id=p_player_id for update;
  if player.id is null then raise exception 'This player could not be found.'; end if;
  if player.user_id is distinct from auth.uid() and not public.is_waitlist_admin() then raise exception 'You can only edit your own name.'; end if;
  if clean_first='' then raise exception 'Enter a first name using letters.'; end if;
  if public.is_inappropriate_player_name(clean_first||' '||clean_last) then raise exception 'This name is not allowed. Choose a different name.'; end if;
  select exists(select 1 from public.waitlist_players p where p.facility_id=fid and p.id<>player.id and p.status<>'left' and lower(p.first_name)=lower(clean_first)) into same_first;
  if same_first and clean_last='' then raise exception 'That first name is already being used. Add a last initial or last name.'; end if;
  shown_name:=clean_first||case when clean_last='' then '' else ' '||left(clean_last,1) end;
  if exists(select 1 from public.waitlist_players p where p.facility_id=fid and p.id<>player.id and p.status<>'left' and lower(p.display_name)=lower(shown_name)) then
    if length(clean_last)>1 then shown_name:=clean_first||' '||clean_last; else raise exception 'That name is already being used. Add a full last name.'; end if;
  end if;
  if exists(select 1 from public.waitlist_players p where p.facility_id=fid and p.id<>player.id and p.status<>'left' and lower(p.display_name)=lower(shown_name)) then raise exception 'That name is already being used. Choose a different last name.'; end if;
  update public.waitlist_players set first_name=clean_first,last_name=clean_last,display_name=shown_name,updated_at=now() where facility_id=fid and id=player.id;
  return jsonb_build_object('message','Your name was updated.');
end; $$;

create or replace function public.log_waitlist_player_change()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  if tg_op='INSERT' and new.user_id is not null and new.status<>'left' then
    insert into public.waitlist_events(facility_id,actor_user_id,actor_name,event_type,message) values(new.facility_id,new.user_id,new.display_name,'join',new.display_name||' joined the waitlist.');
  elsif tg_op='UPDATE' and old.status='left' and new.status<>'left' and new.user_id is not null then
    insert into public.waitlist_events(facility_id,actor_user_id,actor_name,event_type,message) values(new.facility_id,new.user_id,new.display_name,'join',new.display_name||' joined the waitlist.');
  elsif tg_op='UPDATE' and old.status<>'left' and new.status='left' then
    insert into public.waitlist_events(facility_id,actor_user_id,actor_name,event_type,message) values(new.facility_id,new.user_id,new.display_name,'leave',new.display_name||' left the waitlist.');
  end if;
  return new;
end; $$;

create or replace function public.admin_set_facility_location(p_latitude double precision,p_longitude double precision,p_radius_m integer default 150)
returns jsonb language plpgsql security definer set search_path=public as $$
declare fid uuid:=public.current_facility_id();
begin
  if not public.is_waitlist_admin() then raise exception 'Admin access required.'; end if;
  if fid is null then raise exception 'Select a facility first.'; end if;
  if p_latitude not between -90 and 90 or p_longitude not between -180 and 180 then raise exception 'Invalid facility location.'; end if;
  if p_radius_m not between 50 and 1000 then raise exception 'Radius must be between 50 and 1000 meters.'; end if;
  update public.waitlist_config set facility_latitude=p_latitude,facility_longitude=p_longitude,geofence_radius_m=p_radius_m,geofence_enabled=true,updated_at=now() where facility_id=fid and id;
  if not found then raise exception 'Facility configuration not found.'; end if;
  return jsonb_build_object('message','Facility location saved.','radius_m',p_radius_m);
end; $$;

create or replace function public.admin_select_facility(p_facility_code text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare fid uuid:=public.current_facility_id();
begin
  if not public.is_waitlist_admin() then raise exception 'Admin access required.'; end if;
  if fid is null then raise exception 'Select a facility first.'; end if;
  if upper(p_facility_code)='PHR' then update public.waitlist_config set facility_code='PHR',facility_latitude=32.95996,facility_longitude=-117.18682,geofence_radius_m=150,geofence_enabled=true,updated_at=now() where facility_id=fid and id; return jsonb_build_object('message','Pacific Highlands Ranch selected.');
  elsif upper(p_facility_code) in ('NA','N/A') then update public.waitlist_config set facility_code=null,facility_latitude=null,facility_longitude=null,geofence_enabled=false,updated_at=now() where facility_id=fid and id; return jsonb_build_object('message','Facility location disabled.'); end if;
  raise exception 'Unknown facility.';
end; $$;

create or replace function public.verify_facility_location(p_latitude double precision,p_longitude double precision)
returns jsonb language plpgsql security definer set search_path=public as $$
declare fid uuid:=public.current_facility_id(); c public.waitlist_config; distance_m double precision;
begin
  if fid is null then raise exception 'Select a facility first.'; end if;
  if p_latitude not between -90 and 90 or p_longitude not between -180 and 180 then raise exception 'Invalid device location.'; end if;
  select * into c from public.waitlist_config where facility_id=fid and id;
  if c.id is null then raise exception 'Facility configuration not found.'; end if;
  if not c.geofence_enabled or c.facility_latitude is null or c.facility_longitude is null then return jsonb_build_object('configured',false,'inside',true,'distance_m',0,'radius_m',c.geofence_radius_m); end if;
  distance_m:=6371000*acos(least(1,greatest(-1,sin(radians(c.facility_latitude))*sin(radians(p_latitude))+cos(radians(c.facility_latitude))*cos(radians(p_latitude))*cos(radians(p_longitude-c.facility_longitude)))));
  return jsonb_build_object('configured',true,'inside',distance_m<=c.geofence_radius_m,'distance_m',round(distance_m::numeric,1),'radius_m',c.geofence_radius_m);
end; $$;

grant execute on function public.admin_list_waitlist_history() to authenticated;
grant execute on function public.rejoin_waitlist_at_back() to authenticated;
grant execute on function public.rename_waitlist_player(uuid,text,text) to authenticated;
grant execute on function public.admin_set_facility_location(double precision,double precision,integer) to authenticated;
grant execute on function public.admin_select_facility(text) to authenticated;
grant execute on function public.verify_facility_location(double precision,double precision) to authenticated;

commit;
