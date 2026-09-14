-- Reset every active facility independently at midnight Pacific time.
-- This job is mode-agnostic: it clears Regular, Rejoin, Teams, and Teams Rejoin state.
create or replace function public.run_midnight_pacific_waitlist_reset()
returns void
language plpgsql
security definer
set search_path=public,cron
as $$
declare
  local_now timestamp := now() at time zone 'America/Los_Angeles';
  local_date date := local_now::date;
  facility record;
begin
  -- pg_cron runs this once per minute. The date guard makes the operation
  -- idempotent and the hour guard confines it to the midnight hour.
  if extract(hour from local_now) <> 0 then return; end if;

  perform pg_advisory_xact_lock(7429103);

  for facility in
    select f.id
    from public.facilities f
    where f.active
    order by f.id
  loop
    insert into public.daily_waitlist_reset_state(facility_id,id,last_reset_date)
    values(facility.id,true,null)
    on conflict(facility_id,id) do nothing;

    if (select s.last_reset_date
        from public.daily_waitlist_reset_state s
        where s.facility_id=facility.id and s.id) is not distinct from local_date then
      continue;
    end if;

    -- Remove dependent one-game and substitute assignments before teams.
    delete from public.team_fill_ins where facility_id=facility.id;
    delete from public.team_substitute_requests where facility_id=facility.id;
    delete from public.team_substitutes where facility_id=facility.id;

    update public.waitlist_players
      set status='left',queue_position=null,group_id=null,team_id=null,court_number=null,
          rejoin_expires_at=null,sitout_priority=false,sitout_from_game=null,updated_at=now()
      where facility_id=facility.id;

    delete from public.king_round_history where facility_id=facility.id;
    delete from public.king_teams where facility_id=facility.id;
    delete from public.king_mode_state where facility_id=facility.id;
    delete from public.past_games where facility_id=facility.id;
    delete from public.group_requests where facility_id=facility.id;
    delete from public.rejoin_responses where facility_id=facility.id;
    delete from public.group_notifications where facility_id=facility.id;
    delete from public.substitute_requests where facility_id=facility.id;
    delete from public.geofence_return_prompts where facility_id=facility.id;
    delete from public.waitlist_events where facility_id=facility.id;
    delete from public.admin_undo where facility_id=facility.id;
    delete from public.admin_redo where facility_id=facility.id;

    update public.waitlist_config
      set game_number=1,updated_at=now()
      where facility_id=facility.id;
    update public.waitlist_courts
      set game_number=court_number,started_at=now()
      where facility_id=facility.id;

    update public.daily_waitlist_reset_state
      set last_reset_date=local_date
      where facility_id=facility.id and id;
  end loop;
end;
$$;

-- The scheduler is the only caller. Owning this maintenance function as
-- postgres lets it reset every facility without inheriting a user's RLS scope.
alter function public.run_midnight_pacific_waitlist_reset() owner to postgres;
revoke all on function public.run_midnight_pacific_waitlist_reset() from public,anon,authenticated;

do $$
declare existing_job bigint;
begin
  for existing_job in
    select jobid from cron.job where jobname='opengym-midnight-pacific-reset'
  loop
    perform cron.unschedule(existing_job);
  end loop;
end $$;

select cron.schedule(
  'opengym-midnight-pacific-reset',
  '* * * * *',
  'select public.run_midnight_pacific_waitlist_reset();'
);

