-- Fix: "Accept all rejoin requests" skipped some players.
--
-- The function looped over a FOR UPDATE cursor while each acceptance ran the
-- allocator, which renumbers the line (including the held spots still in the
-- cursor). PostgreSQL silently skips cursor rows that the same transaction
-- already updated, so players further back stayed "deciding" (3 of 13 in a
-- live test). Now it accepts one player at a time, in line order, re-reading
-- the next held spot each time.
begin;

create or replace function public.admin_accept_all_offline_rejoins_for_facility(p_expected_facility uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  fid uuid:=public.current_facility_id();
  next_id uuid;
  accepted_count integer:=0;
begin
  perform public.lock_facility(); /* per-facility lock (audit L2/L3) */

  if p_expected_facility is null or fid is distinct from p_expected_facility then
    raise exception 'Facility selection changed. Refresh and try again.';
  end if;
  if not public.is_waitlist_operator() then raise exception 'Admin or host access required.'; end if;
  update public.waitlist_players
    set status='left',queue_position=null,rejoin_expires_at=null,updated_at=now()
    where facility_id=fid and user_id is null and status='rejoin' and rejoin_expires_at<=now();
  loop
    select id into next_id from public.waitlist_players
     where facility_id=fid and user_id is null and status='rejoin' and rejoin_expires_at>now()
     order by line_key nulls last,queue_position nulls last,id
     limit 1;
    exit when next_id is null;
    perform public.admin_answer_offline_rejoin(next_id,true);
    accepted_count:=accepted_count+1;
    exit when accepted_count>500;
  end loop;
  return jsonb_build_object(
    'message',case when accepted_count=1 then '1 rejoin request accepted.' else accepted_count||' rejoin requests accepted.' end,
    'accepted_count',accepted_count
  );
end;
$function$;

-- The older entry point (no facility argument) gets the same behaviour.
create or replace function public.admin_accept_all_offline_rejoins()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  return public.admin_accept_all_offline_rejoins_for_facility(public.current_facility_id());
end;
$function$;

notify pgrst, 'reload schema';
commit;
