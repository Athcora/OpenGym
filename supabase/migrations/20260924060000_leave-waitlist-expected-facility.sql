-- Facility context is stored per auth.uid(), so another tab can switch it
-- between the client-side select_facility() call and this mutation. Bind the
-- leave action to the facility the initiating UI showed.
begin;

create or replace function public.leave_waitlist_for_facility(p_expected_facility uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare player public.waitlist_players; fid uuid:=public.current_facility_id();
begin
  if p_expected_facility is null or fid is distinct from p_expected_facility then
    raise exception 'Facility selection changed. Refresh and try again.';
  end if;
  perform pg_advisory_xact_lock(7429101);
  select * into player from public.waitlist_players
    where facility_id=fid and user_id=auth.uid() for update;
  if player.id is null or player.status='left' then
    return jsonb_build_object('message','You are not currently in this facility waitlist.');
  end if;
  update public.waitlist_players
    set status='left',queue_position=null,rejoin_expires_at=null,updated_at=now()
    where id=player.id and facility_id=fid;
  update public.rejoin_responses
    set choice='leave',answered_at=now()
    where facility_id=fid and user_id=auth.uid() and choice is null;
  if player.status='current' then
    update public.waitlist_players set status='current',updated_at=now()
      where facility_id=fid and id=(
        select id from public.waitlist_players
          where facility_id=fid and status='waiting'
          order by queue_position limit 1
      );
  end if;
  return jsonb_build_object('message','You left the waitlist.');
end; $$;

alter function public.leave_waitlist_for_facility(uuid) owner to opengym_runtime;
revoke all on function public.leave_waitlist() from public,anon,authenticated;
revoke all on function public.leave_waitlist_for_facility(uuid) from public,anon,authenticated;
grant execute on function public.leave_waitlist_for_facility(uuid) to authenticated;

do $$
begin
  if has_function_privilege('authenticated','public.leave_waitlist()','execute') then
    raise exception 'The unguarded leave_waitlist() RPC must not remain browser-executable';
  end if;
  if not has_function_privilege('authenticated','public.leave_waitlist_for_facility(uuid)','execute')
    or has_function_privilege('anon','public.leave_waitlist_for_facility(uuid)','execute')
    or has_function_privilege('public','public.leave_waitlist_for_facility(uuid)','execute') then
    raise exception 'The expected-facility leave RPC has an incorrect execute boundary';
  end if;
end $$;

notify pgrst,'reload schema';
commit;

