-- Rejoin from the generic Rejoin-only view. An expired or otherwise inactive
-- player may still have a stale team_id, which must not reserve that team or
-- cause join_waitlist() to report that the player is already active.
create or replace function public.rejoin_waitlist_at_back()
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  player public.waitlist_players;
  old_team_id uuid;
  cfg public.waitlist_config;
  joined jsonb;
begin
  if auth.uid() is null then raise exception 'You must be signed in.'; end if;
  perform pg_advisory_xact_lock(7429101);

  select * into player from public.waitlist_players where user_id=auth.uid() for update;
  if player.id is null then raise exception 'Your previous player record was not found. Please log out and join normally.'; end if;
  if player.status in ('current','waiting','sitout') then
    return jsonb_build_object('message','You are already in the waitlist.','player_id',player.id);
  end if;

  old_team_id:=player.team_id;
  update public.waitlist_players
    set status='left',queue_position=null,team_id=null,court_number=null,
      group_id=null,rejoin_expires_at=null,sitout_priority=false,
      sitout_from_game=null,updated_at=now()
    where id=player.id;
  update public.rejoin_responses set choice='leave',answered_at=now()
    where user_id=auth.uid() and choice is null;

  if old_team_id is not null and not exists(
    select 1 from public.waitlist_players where team_id=old_team_id and status<>'left'
  ) then
    delete from public.king_teams where id=old_team_id;
  end if;

  joined:=public.join_waitlist(player.first_name,player.last_name);
  select * into cfg from public.waitlist_config where id;
  if cfg.mode in ('teams','teams_rejoin') then
    perform public.king_prepare_player(player.id);
  end if;
  return joined||jsonb_build_object('message','You rejoined at the back of the waitlist.');
end; $$;

grant execute on function public.rejoin_waitlist_at_back() to authenticated;
