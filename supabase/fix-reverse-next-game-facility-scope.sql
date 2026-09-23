-- Run 4: The legacy regular/rejoin immediate-reverse RPC remains a browser
-- action, but every undo lookup and mutation must stay inside the currently
-- selected facility.  Its snapshot restore is facility-scoped by
-- fix-mode-switch-facility-scope.sql.
create or replace function public.reverse_next_game()
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  entry public.admin_undo;
  snapshot_game integer;
  current_game integer;
  actor text;
  fid uuid:=public.current_facility_id();
begin
  perform pg_advisory_xact_lock(7429101);
  if fid is null then raise exception 'Select a facility first.'; end if;
  if public.is_waitlist_operator() then
    select * into entry from public.admin_undo
      where facility_id=fid and label='start next game'
      order by id desc limit 1 for update;
  else
    select * into entry from public.admin_undo
      where facility_id=fid and label='start next game' and admin_user_id=auth.uid()
      order by id desc limit 1 for update;
  end if;
  if entry.id is null then raise exception 'There is no recent next-game action you can reverse.'; end if;
  snapshot_game:=(entry.snapshot->'config'->>'game_number')::integer;
  select game_number into current_game from public.waitlist_config where facility_id=fid for update;
  if current_game<>snapshot_game+1 then raise exception 'This game can no longer be reversed because the waitlist has already advanced.'; end if;
  perform public.restore_waitlist_state(entry.snapshot);
  delete from public.rejoin_responses where facility_id=fid and game_number>snapshot_game;
  delete from public.admin_undo where facility_id=fid and id=entry.id;
  delete from public.admin_redo where facility_id=fid and admin_user_id=entry.admin_user_id;
  select coalesce(display_name,'Admin') into actor from public.waitlist_players where facility_id=fid and user_id=auth.uid();
  insert into public.waitlist_events(facility_id,actor_user_id,actor_name,event_type,message)
    values(fid,auth.uid(),coalesce(actor,'Admin'),'next_game_reversed',coalesce(actor,'Admin')||' reversed the start of Game '||(snapshot_game+1)||'.');
  return jsonb_build_object('message','Game '||(snapshot_game+1)||' was reversed. Game '||snapshot_game||' and its queue order are restored.');
end;
$$;
notify pgrst,'reload schema';
