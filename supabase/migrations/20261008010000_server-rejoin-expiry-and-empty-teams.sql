-- Applied to production 2026-10-07.
--  #4 Expired rejoin spots are cleared by the database every minute for every
--     facility, instead of only when some phone has the app open (audit L8).
--  #6 When the last active member of a Teams-mode team leaves, the empty team is
--     removed at the end of that transaction so its court side or queue spot is
--     freed and the next team is seated (audit L6).
begin;

-- Background jobs have no signed-in user, so they name the facility they work on
-- with a transaction-local setting. Browser requests always carry a user id, so
-- the override is ignored for them.
create or replace function public.current_facility_id()
 returns uuid
 language sql
 stable security definer
 set search_path to 'public'
as $function$
  select coalesce(
    case when public.current_request_user_id() is null
      then nullif(current_setting('opengym.facility_override',true),'')::uuid end,
    (select facility_id from public.user_facility_sessions where user_id=public.current_request_user_id())
  )
$function$;

create or replace function public.run_rejoin_expirations()
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare f record;
begin
  for f in
    select fac.id, c.mode
    from public.facilities fac
    left join public.waitlist_config c on c.facility_id=fac.id and c.id
    where fac.active and (
      exists(select 1 from public.waitlist_players p where p.facility_id=fac.id and p.status='rejoin' and p.rejoin_expires_at<=now())
      or exists(select 1 from public.rejoin_responses r where r.facility_id=fac.id and r.choice is null and r.expires_at<=now())
      or exists(select 1 from public.king_teams t where t.facility_id=fac.id and t.rejoin_expires_at<=now()))
  loop
    perform set_config('opengym.facility_override', f.id::text, true);
    begin
      perform public.cleanup_king_rejoin_expirations();
      if f.mode in ('regular','rejoin') then perform public.fill_open_court_slots(); end if;
    exception when others then
      raise warning 'OpenGym rejoin expiry failed for facility %: %', f.id, sqlerrm;
    end;
  end loop;
end;
$function$;
revoke all on function public.run_rejoin_expirations() from public, anon, authenticated;

select cron.schedule('opengym-rejoin-expirations', '* * * * *', 'select public.run_rejoin_expirations();');

-- Release a Teams-mode team once nobody is left on it. Deferred to the end of the
-- transaction so multi-step actions (moves, next game, resets) finish first.
create or replace function public.release_empty_king_team()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare team public.king_teams;
begin
  if old.team_id is null then return null; end if;
  -- Background jobs have no user; name the facility (ignored for browser requests).
  perform set_config('opengym.facility_override', old.facility_id::text, true);
  select * into team from public.king_teams where id=old.team_id and facility_id=old.facility_id;
  if team.id is null then return null; end if;
  if exists(select 1 from public.waitlist_players p
              where p.facility_id=old.facility_id and p.team_id=team.id
                and p.status in ('current','waiting','sitout','rejoin'))
     or exists(select 1 from public.team_substitutes s join public.waitlist_players p on p.id=s.player_id
              where s.team_id=team.id and p.status in ('current','waiting','sitout')) then
    return null;
  end if;
  delete from public.king_teams where id=team.id and facility_id=old.facility_id;
  perform public.king_compact_queue();
  perform public.king_fill_courts();
  return null;
end;
$function$;
alter function public.release_empty_king_team() owner to opengym_runtime;

drop trigger if exists release_empty_king_team on public.waitlist_players;
create constraint trigger release_empty_king_team
  after update of status, team_id on public.waitlist_players
  deferrable initially deferred
  for each row
  when (old.team_id is not null and (new.team_id is distinct from old.team_id or new.status in ('left')))
  execute function public.release_empty_king_team();

commit;
