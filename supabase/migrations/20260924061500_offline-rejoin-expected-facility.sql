-- Bind the batch action to the facility the initiating admin tab displays.
-- Facility selection is shared per user across tabs, so the current context
-- can change between the browser's select_facility and the RPC request.
begin;

do $$
begin
  if to_regprocedure('public.admin_accept_all_offline_rejoins()') is null then
    raise exception 'Expected legacy offline-rejoin batch RPC is missing';
  end if;
  if to_regprocedure('public.admin_accept_all_offline_rejoins_for_facility(uuid)') is not null then
    raise exception 'Guarded offline-rejoin batch RPC already exists';
  end if;
end $$;

create function public.admin_accept_all_offline_rejoins_for_facility(p_expected_facility uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  fid uuid:=public.current_facility_id();
  request record;
  accepted_count integer:=0;
begin
  if p_expected_facility is null or fid is distinct from p_expected_facility then
    raise exception 'Facility selection changed. Refresh and try again.';
  end if;
  if not public.is_waitlist_operator() then raise exception 'Admin or host access required.'; end if;
  update public.waitlist_players
    set status='left',queue_position=null,rejoin_expires_at=null,updated_at=now()
    where facility_id=fid and user_id is null and status='rejoin' and rejoin_expires_at<=now();
  for request in
    select id from public.waitlist_players
      where facility_id=fid and user_id is null and status='rejoin' and rejoin_expires_at>now()
      order by queue_position,id for update
  loop
    perform public.admin_answer_offline_rejoin(request.id,true);
    accepted_count:=accepted_count+1;
  end loop;
  return jsonb_build_object(
    'message',case when accepted_count=1 then '1 rejoin request accepted.' else accepted_count||' rejoin requests accepted.' end,
    'accepted_count',accepted_count
  );
end; $$;

alter function public.admin_accept_all_offline_rejoins_for_facility(uuid) owner to postgres;
revoke all on function public.admin_accept_all_offline_rejoins() from public,anon,authenticated;
revoke all on function public.admin_accept_all_offline_rejoins_for_facility(uuid) from public,anon,authenticated;
grant execute on function public.admin_accept_all_offline_rejoins_for_facility(uuid) to authenticated;

do $$
begin
  if has_function_privilege('authenticated','public.admin_accept_all_offline_rejoins()','execute') then
    raise exception 'The unguarded offline-rejoin batch RPC must not remain browser-executable';
  end if;
  if not has_function_privilege('authenticated','public.admin_accept_all_offline_rejoins_for_facility(uuid)','execute')
    or has_function_privilege('anon','public.admin_accept_all_offline_rejoins_for_facility(uuid)','execute')
    or has_function_privilege('public','public.admin_accept_all_offline_rejoins_for_facility(uuid)','execute') then
    raise exception 'The expected-facility offline-rejoin RPC has an incorrect execute boundary';
  end if;
end $$;

notify pgrst,'reload schema';
commit;
