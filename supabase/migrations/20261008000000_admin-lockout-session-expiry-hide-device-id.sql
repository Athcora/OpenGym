-- Applied to production 2026-10-07.
--  * Admin sign-in: 5 failed attempts for a facility within 15 minutes lock that
--    facility's admin sign-in for 15 minutes (audit S7). Failures are returned as
--    {ok:false} instead of raised, so the attempt counter is not rolled back.
--  * Admin sessions expire 12 hours after sign-in (audit S7).
--  * waitlist_players.device_id is no longer readable by browsers or sent over
--    realtime, so it cannot be copied to impersonate another player (audit S1).
begin;

create table if not exists public.admin_sign_in_attempts(
  facility_id uuid primary key references public.facilities(id) on delete cascade,
  failed_count integer not null default 0,
  first_failed_at timestamptz,
  locked_until timestamptz
);
alter table public.admin_sign_in_attempts enable row level security;
revoke all on public.admin_sign_in_attempts from public, anon, authenticated;

create or replace function public.sign_in_waitlist_admin(p_username text, p_password text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public', 'extensions'
as $function$
declare
  credential public.facility_admin_credentials;
  attempt public.admin_sign_in_attempts;
  fid uuid := public.current_facility_id();
  max_attempts constant integer := 5;
  window_length constant interval := interval '15 minutes';
  lock_length constant interval := interval '15 minutes';
begin
  if auth.uid() is null then raise exception 'You must be signed in.'; end if;
  if fid is null then raise exception 'Select a facility first.'; end if;

  select * into attempt from public.admin_sign_in_attempts where facility_id=fid for update;
  if attempt.locked_until is not null and attempt.locked_until>now() then
    return jsonb_build_object('ok',false,'locked',true,'message',
      'Too many failed sign-in attempts. Admin sign-in for this facility is locked for '
      ||greatest(1,ceil(extract(epoch from attempt.locked_until-now())/60))::integer||' more minute(s).');
  end if;

  select * into credential from public.facility_admin_credentials
    where facility_id=fid and username=lower(trim(p_username));
  if credential.username is null or credential.password_hash<>crypt(p_password,credential.password_hash) then
    insert into public.admin_sign_in_attempts as a(facility_id,failed_count,first_failed_at,locked_until)
      values(fid,1,now(),null)
      on conflict(facility_id) do update set
        failed_count=case when a.first_failed_at is null or a.first_failed_at<now()-window_length or a.locked_until is not null
          then 1 else a.failed_count+1 end,
        first_failed_at=case when a.first_failed_at is null or a.first_failed_at<now()-window_length or a.locked_until is not null
          then now() else a.first_failed_at end,
        locked_until=null
      returning * into attempt;
    if attempt.failed_count>=max_attempts then
      update public.admin_sign_in_attempts set locked_until=now()+lock_length where facility_id=fid;
      return jsonb_build_object('ok',false,'locked',true,'message',
        'Too many failed sign-in attempts. Admin sign-in for this facility is locked for 15 minutes.');
    end if;
    return jsonb_build_object('ok',false,'locked',false,'message',
      'Incorrect username or password. '||(max_attempts-attempt.failed_count)||' attempt(s) left before a 15-minute lockout.');
  end if;

  delete from public.admin_sign_in_attempts where facility_id=fid;
  delete from public.admin_sessions where facility_id=fid and created_at<now()-interval '12 hours';
  insert into public.admin_sessions(user_id,username,facility_id) values(auth.uid(),credential.username,fid)
    on conflict(user_id) do update set username=excluded.username,facility_id=excluded.facility_id,created_at=now();
  return jsonb_build_object('ok',true,'message','Signed in.');
end
$function$;

create or replace function public.is_waitlist_admin()
 returns boolean
 language sql
 stable security definer
 set search_path to 'public'
as $function$
  select coalesce((public.current_request_claims()->'app_metadata'->>'role')='admin',false)
    or exists(select 1 from public.admin_sessions
      where user_id=public.current_request_user_id()
        and facility_id=public.current_facility_id()
        and created_at>now()-interval '12 hours')
$function$;

-- Browsers may read every waitlist_players column except device_id.
revoke select on public.waitlist_players from anon, authenticated;
grant select (id,user_id,first_name,last_name,display_name,status,queue_position,restricted,
  rejoin_expires_at,created_at,updated_at,group_id,is_host,sitout_priority,sitout_from_game,
  court_number,team_id,facility_id) on public.waitlist_players to anon, authenticated;

-- Realtime publishes the same columns (device_id excluded).
alter publication supabase_realtime drop table public.waitlist_players;
alter publication supabase_realtime add table public.waitlist_players (id,user_id,first_name,last_name,
  display_name,status,queue_position,restricted,rejoin_expires_at,created_at,updated_at,group_id,is_host,
  sitout_priority,sitout_from_game,court_number,team_id,facility_id);

notify pgrst,'reload schema';
commit;
