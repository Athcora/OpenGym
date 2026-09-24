-- A geofence return is a fresh placement in Teams Mode.  A player whose
-- one-minute saved-position grace period has elapsed must fill the first
-- available team slot, just as a regular join does; keeping their stale
-- team_id silently puts them back into the last waiting team instead.
--
-- This replacement also scopes each SECURITY DEFINER lookup to the selected
-- facility.  The original pre-tenancy implementation used singleton/global
-- queries, which are unsafe now that a user can have records in many gyms.
create or replace function public.return_after_geofence(
  p_prompt_id uuid,
  p_latitude double precision,
  p_longitude double precision
)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  fid uuid:=public.current_facility_id();
  prompt public.geofence_return_prompts;
  player public.waitlist_players;
  config public.waitlist_config;
  old_team_id uuid;
  target_team public.king_teams;
  distance_m double precision;
  target_position bigint;
  back_position bigint;
  member_position bigint;
  next_team_position bigint;
  next_team_number integer;
  saved boolean;
begin
  select * into prompt from public.geofence_return_prompts
    where id=p_prompt_id and user_id=auth.uid() and facility_id=fid
    for update;
  if prompt.id is null or prompt.resolved_at is not null then
    raise exception 'This return window is no longer available.';
  end if;
  if prompt.expires_at<=now() then
    update public.geofence_return_prompts set resolved_at=now(),resolution='expired'
      where id=prompt.id and facility_id=fid;
    raise exception 'Your 10-minute return window has expired.';
  end if;

  select * into config from public.waitlist_config
    where facility_id=fid and id for update;
  if config.id is null then raise exception 'Facility configuration not found.'; end if;
  if config.geofence_enabled and config.facility_latitude is not null and config.facility_longitude is not null then
    distance_m:=6371000*acos(least(1,greatest(-1,
      sin(radians(config.facility_latitude))*sin(radians(p_latitude))+
      cos(radians(config.facility_latitude))*cos(radians(p_latitude))*
      cos(radians(p_longitude-config.facility_longitude))
    )));
    if distance_m>config.geofence_radius_m then
      return jsonb_build_object('inside',false,'distance_m',round(distance_m::numeric,1),'radius_m',config.geofence_radius_m);
    end if;
  end if;

  select * into player from public.waitlist_players
    where id=prompt.player_id and facility_id=fid for update;
  if player.id is null then raise exception 'Player not found.'; end if;

  -- Teams have their own roster ordering.  Do not restore a stale team_id:
  -- choose the same earliest opening used by a normal team-mode join.
  if config.mode in ('teams','teams_rejoin') then
    old_team_id:=player.team_id;
    select t.* into target_team
      from public.king_teams t
      where t.facility_id=fid and t.status in ('current','waiting')
        and (select count(*) from public.waitlist_players p
             where p.facility_id=fid and p.team_id=t.id and p.status<>'left' and p.id<>player.id)<6
      order by case when t.status='current' then 0 else 1 end,
        t.court_number asc nulls last,t.court_side asc nulls last,
        t.queue_position asc,t.created_at asc
      limit 1 for update;
    if target_team.id is null then
      select coalesce(max(queue_position),0)+1 into next_team_position
        from public.king_teams where facility_id=fid and status='waiting';
      select coalesce(max((regexp_match(name,'[0-9]+'))[1]::integer),0)+1 into next_team_number
        from public.king_teams where facility_id=fid;
      insert into public.king_teams(facility_id,name,status,queue_position)
        values(fid,'Team '||next_team_number,'waiting',next_team_position)
        returning * into target_team;
    end if;
    select coalesce(max(queue_position),0)+1 into member_position
      from public.waitlist_players
      where facility_id=fid and team_id=target_team.id and status<>'left' and id<>player.id;
    update public.waitlist_players
      set team_id=target_team.id,status=target_team.status,court_number=target_team.court_number,
          queue_position=member_position,rejoin_expires_at=null,updated_at=now()
      where id=player.id and facility_id=fid;
    if old_team_id is not null and old_team_id<>target_team.id and not exists(
      select 1 from public.waitlist_players
        where facility_id=fid and team_id=old_team_id and status<>'left'
    ) then
      delete from public.king_teams where facility_id=fid and id=old_team_id;
    end if;
    update public.geofence_return_prompts
      set resolved_at=now(),resolution='team_first_available'
      where id=prompt.id and facility_id=fid;
    insert into public.waitlist_events(facility_id,actor_user_id,actor_name,event_type,message)
      values(fid,auth.uid(),player.display_name,'geofence_return',player.display_name||' joined the first available team spot.');
    return jsonb_build_object('inside',true,'saved_position',false,'team_first_available',true,
      'message','You joined the first available team spot.');
  end if;

  saved:=now()<=prompt.saved_position_until;
  select coalesce(max(queue_position),0)+1 into back_position
    from public.waitlist_players where facility_id=fid and status in ('current','waiting','sitout');
  target_position:=case when saved then least(prompt.original_position,back_position) else back_position end;
  update public.waitlist_players set queue_position=queue_position+1
    where facility_id=fid and status in ('current','waiting','sitout') and queue_position>=target_position;
  update public.waitlist_players
    set status='waiting',queue_position=target_position,rejoin_expires_at=null,updated_at=now()
    where id=player.id and facility_id=fid;
  perform public.normalize_active_waitlist();
  update public.geofence_return_prompts
    set resolved_at=now(),resolution=case when saved then 'saved_position' else 'back' end
    where id=prompt.id and facility_id=fid;
  insert into public.waitlist_events(facility_id,actor_user_id,actor_name,event_type,message)
    values(fid,auth.uid(),player.display_name,'geofence_return',player.display_name||case when saved then ' returned to their saved position.' else ' rejoined at the back of the waitlist.' end);
  return jsonb_build_object('inside',true,'saved_position',saved,
    'message',case when saved then 'You are back at your saved position.' else 'You rejoined at the back of the waitlist.' end);
end; $$;

alter function public.return_after_geofence(uuid,double precision,double precision) owner to opengym_runtime;
grant execute on function public.return_after_geofence(uuid,double precision,double precision) to authenticated;
