-- `admin_reset_waitlist()` is browser-executable for a facility administrator.
-- Its internal reset helper must therefore never use runtime-owner privileges to
-- affect a different facility.

create or replace function public.clear_waitlist_and_history(p_clear_undo boolean default false)
returns void language plpgsql security definer set search_path=public as $$
declare
  fid uuid:=public.current_facility_id();
  cfg public.waitlist_config;
begin
  if fid is null then raise exception 'Select a facility first.'; end if;

  select * into cfg from public.waitlist_config
  where facility_id=fid and id for update;
  if cfg.facility_id is null then raise exception 'Facility configuration is unavailable.'; end if;

  delete from public.team_fill_ins where facility_id=fid;
  delete from public.team_substitute_requests where facility_id=fid;
  delete from public.team_substitutes where facility_id=fid;
  update public.waitlist_players
    set status='left',queue_position=null,group_id=null,team_id=null,court_number=null,
        rejoin_expires_at=null,sitout_priority=false,sitout_from_game=null,updated_at=now()
    where facility_id=fid;
  delete from public.king_round_history where facility_id=fid;
  delete from public.king_teams where facility_id=fid;
  delete from public.king_mode_state where facility_id=fid;
  delete from public.past_games where facility_id=fid;
  delete from public.group_requests where facility_id=fid;
  delete from public.rejoin_responses where facility_id=fid;
  delete from public.group_notifications where facility_id=fid;
  delete from public.substitute_requests where facility_id=fid;
  delete from public.geofence_return_prompts where facility_id=fid;
  update public.waitlist_config
    set game_number=1,updated_at=now()
    where facility_id=fid and id;
  delete from public.waitlist_courts
    where facility_id=fid and court_number>greatest(1,cfg.court_count);
  insert into public.waitlist_courts(facility_id,court_number,game_number,started_at)
    select fid,n,n,now() from generate_series(1,greatest(1,cfg.court_count)) n
    on conflict(facility_id,court_number)
    do update set game_number=excluded.game_number,started_at=excluded.started_at;
  delete from public.waitlist_events where facility_id=fid;

  if p_clear_undo then
    delete from public.admin_undo where facility_id=fid;
    delete from public.admin_redo where facility_id=fid;
  end if;
end;
$$;

notify pgrst, 'reload schema';
