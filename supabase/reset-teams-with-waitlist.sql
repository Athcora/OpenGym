-- Reset every Teams Mode record whenever the main waitlist is reset.
-- Both the admin reset and the Pacific-midnight job call this shared function.
create or replace function public.clear_waitlist_and_history(p_clear_undo boolean default false)
returns void language plpgsql security definer set search_path=public as $$
begin
  update public.waitlist_players
    set status='left',queue_position=null,group_id=null,team_id=null,court_number=null,
      rejoin_expires_at=null,sitout_priority=false,sitout_from_game=null,updated_at=now()
    where true;

  delete from public.king_round_history where true;
  delete from public.king_teams where true;
  delete from public.king_mode_state where true;
  delete from public.past_games where true;
  delete from public.group_requests where true;
  delete from public.rejoin_responses where true;
  delete from public.group_notifications where true;
  delete from public.substitute_requests where true;

  update public.waitlist_config set game_number=1,updated_at=now() where id;
  update public.waitlist_courts
    set game_number=court_number,started_at=now()
    where true;
  delete from public.waitlist_events where true;

  if p_clear_undo then
    delete from public.admin_undo where true;
    delete from public.admin_redo where true;
  end if;
end;
$$;
