-- Offline rejoin acceptance must use the same selected-facility allocator as
-- every other path that puts a player back into an active court.
create or replace function public.admin_answer_offline_rejoin(p_player_id uuid,p_stay boolean)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  player public.waitlist_players;
  restored public.waitlist_players;
  fid uuid:=public.current_facility_id();
begin
  if not public.is_waitlist_operator() then raise exception 'Admin or host access required.'; end if;
  perform pg_advisory_xact_lock(7429101);
  select * into player from public.waitlist_players
    where id=p_player_id and facility_id=fid and user_id is null and status='rejoin' for update;
  if player.id is null then raise exception 'This rejoin request is no longer available.'; end if;
  if player.rejoin_expires_at<=now() then
    update public.waitlist_players set status='left',queue_position=null,rejoin_expires_at=null,updated_at=now()
      where id=player.id and facility_id=fid;
    raise exception 'The 15-minute rejoin window has expired.';
  end if;

  perform public.save_admin_undo(case when p_stay then 'rejoin player' else 'remove rejoin player' end);
  update public.waitlist_players
    set status=case when p_stay then 'waiting' else 'left' end,
        court_number=null,
        queue_position=case when p_stay then player.queue_position else null end,
        rejoin_expires_at=null,
        updated_at=now()
    where id=player.id and facility_id=fid;

  if not p_stay then
    return jsonb_build_object('message',player.display_name||' was removed.');
  end if;

  -- The allocator is facility-scoped and preserves waiting/group ordering while
  -- assigning a valid court only when that court has capacity.
  perform public.fill_open_court_slots();
  select * into restored from public.waitlist_players where id=player.id and facility_id=fid;
  perform public.log_waitlist_operator_action(
    'admin_rejoin',
    'returned '||player.display_name||case when restored.status='current' then ' to Court '||restored.court_number||'.' else ' to their saved queue position.' end
  );
  return jsonb_build_object(
    'message',
    case when restored.status='current' then player.display_name||' rejoined Court '||restored.court_number||'.' else player.display_name||' rejoined at their saved position.' end
  );
end; $$;

revoke all on function public.admin_answer_offline_rejoin(uuid,boolean) from public,anon;
grant execute on function public.admin_answer_offline_rejoin(uuid,boolean) to authenticated;
