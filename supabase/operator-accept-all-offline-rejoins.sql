-- Accept every active offline-player rejoin request for the selected facility.
create or replace function public.admin_accept_all_offline_rejoins()
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  fid uuid:=public.current_facility_id();
  request record;
  accepted_count integer:=0;
begin
  if not public.is_waitlist_operator() then
    raise exception 'Admin or host access required.';
  end if;

  update public.waitlist_players
    set status='left',queue_position=null,rejoin_expires_at=null,updated_at=now()
    where facility_id=fid and user_id is null and status='rejoin' and rejoin_expires_at<=now();

  for request in
    select id
      from public.waitlist_players
      where facility_id=fid and user_id is null and status='rejoin' and rejoin_expires_at>now()
      order by queue_position,id
      for update
  loop
    perform public.admin_answer_offline_rejoin(request.id,true);
    accepted_count:=accepted_count+1;
  end loop;

  return jsonb_build_object(
    'message',case when accepted_count=1 then '1 rejoin request accepted.' else accepted_count||' rejoin requests accepted.' end,
    'accepted_count',accepted_count
  );
end;
$$;

grant execute on function public.admin_accept_all_offline_rejoins() to authenticated;
