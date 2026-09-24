-- Keep this migration byte-for-byte aligned with
-- supabase/guard-rejoin-at-back-facility-context.sql.
begin;

create function public.rejoin_waitlist_at_back_for_facility(p_expected_facility uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  fid uuid:=public.current_facility_id();
  player public.waitlist_players;
  old_team_id uuid;
  cfg public.waitlist_config;
  joined jsonb;
begin
  if auth.uid() is null then raise exception 'You must be signed in.'; end if;
  if fid is null then raise exception 'Select a facility first.'; end if;
  if p_expected_facility is null or p_expected_facility is distinct from fid then
    raise exception 'Facility selection changed. Please retry.';
  end if;
  perform pg_advisory_xact_lock(7429101);
  -- Recheck after acquiring the lock because a separate tab can change the
  -- shared selection while this call waits.
  fid:=public.current_facility_id();
  if p_expected_facility is distinct from fid then
    raise exception 'Facility selection changed. Please retry.';
  end if;
  select * into player from public.waitlist_players
    where facility_id=fid and user_id=auth.uid() for update;
  if player.id is null then
    raise exception 'Your previous player record was not found. Please log out and join normally.';
  end if;
  if player.status in ('current','waiting','sitout') then
    return jsonb_build_object('message','You are already in the waitlist.','player_id',player.id);
  end if;
  old_team_id:=player.team_id;
  update public.waitlist_players
    set status='left',queue_position=null,team_id=null,court_number=null,
        group_id=null,rejoin_expires_at=null,sitout_priority=false,
        sitout_from_game=null,updated_at=now()
    where facility_id=fid and id=player.id;
  update public.rejoin_responses set choice='leave',answered_at=now()
    where facility_id=fid and user_id=auth.uid() and choice is null;
  if old_team_id is not null and not exists(
    select 1 from public.waitlist_players
      where facility_id=fid and team_id=old_team_id and status<>'left'
  ) then
    delete from public.king_teams where facility_id=fid and id=old_team_id;
  end if;
  joined:=public.join_waitlist(player.first_name,player.last_name);
  select * into cfg from public.waitlist_config where facility_id=fid and id;
  if cfg.mode in ('teams','teams_rejoin') then
    perform public.king_prepare_player(player.id);
  end if;
  return joined||jsonb_build_object('message','You rejoined at the back of the waitlist.');
end; $$;

create or replace function public.clear_king_team_rejoin_timer()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  if new.team_id is not null and new.status in('waiting','current','sitout') then
    update public.king_teams set rejoin_expires_at=null,updated_at=now()
      where facility_id=new.facility_id and id=new.team_id and rejoin_expires_at is not null;
  end if;
  return new;
end; $$;

create or replace function public.log_player_action_history()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  if new.user_id is null then return new; end if;
  if old.status is distinct from new.status and new.status='sitout' then
    insert into public.waitlist_events(facility_id,actor_user_id,actor_name,event_type,message)
      values(new.facility_id,new.user_id,new.display_name,'sitout',new.display_name||' sat out for one game.');
  end if;
  if old.group_id is distinct from new.group_id then
    if old.group_id is null and new.group_id is not null then
      insert into public.waitlist_events(facility_id,actor_user_id,actor_name,event_type,message)
        values(new.facility_id,new.user_id,new.display_name,'group_join',new.display_name||' joined a group.');
    elsif old.group_id is not null and new.group_id is null then
      insert into public.waitlist_events(facility_id,actor_user_id,actor_name,event_type,message)
        values(new.facility_id,new.user_id,new.display_name,'group_leave',new.display_name||' left a group.');
    elsif old.group_id is not null and new.group_id is not null then
      insert into public.waitlist_events(facility_id,actor_user_id,actor_name,event_type,message)
        values(new.facility_id,new.user_id,new.display_name,'group_change',new.display_name||' moved into a different group.');
    end if;
  end if;
  return new;
end; $$;

alter function public.rejoin_waitlist_at_back_for_facility(uuid) owner to opengym_runtime;
alter function public.clear_king_team_rejoin_timer() owner to opengym_runtime;
alter function public.log_player_action_history() owner to opengym_runtime;
revoke all on function public.rejoin_waitlist_at_back() from public, anon, authenticated;
revoke all on function public.rejoin_waitlist_at_back_for_facility(uuid) from public, anon, authenticated;
grant execute on function public.rejoin_waitlist_at_back_for_facility(uuid) to authenticated;
notify pgrst, 'reload schema';
commit;
