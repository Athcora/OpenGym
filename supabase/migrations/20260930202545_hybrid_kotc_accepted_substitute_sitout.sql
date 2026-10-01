-- An accepted KOTC substitute is intentionally still a waiting player until
-- they fill a concrete slot.  The accepted association is nevertheless an
-- authoritative current-appearance relationship and must be able to Sit Out
-- without invoking legacy normalization.
create or replace function public.sit_out_hybrid_kotc_player(
  p_court_number integer,
  p_player_id uuid,
  p_facility_id uuid,
  p_expected_game_number integer,
  p_expected_version bigint
) returns jsonb language plpgsql security definer set search_path=public as $$
declare
  fid uuid:=public.current_facility_id(); cfg public.waitlist_config;
  court public.waitlist_courts; state public.hybrid_kotc_court_state;
  player public.waitlist_players; active_team uuid; active_slot uuid;
  active_substitute uuid; skip_game integer;
begin
  perform public.assert_expected_facility(p_facility_id);
  select * into cfg from public.waitlist_config where facility_id=fid and id for update;
  select * into court from public.waitlist_courts where facility_id=fid and court_number=p_court_number for update;
  select * into state from public.hybrid_kotc_court_state where facility_id=fid and court_number=p_court_number for update;
  select * into player from public.waitlist_players where facility_id=fid and id=p_player_id for update;
  if cfg.mode<>'hybrid_waitlist' or cfg.hybrid_rotation_rule<>'kotc'
     or court.game_number is distinct from p_expected_game_number
     or state.version is distinct from p_expected_version
     or player.id is null or player.status not in ('current','waiting')
     or (player.user_id is distinct from public.current_request_user_id() and not public.is_waitlist_operator()) then
    raise exception 'This Waitlist KOTC appearance changed. Refresh and try again.';
  end if;

  select t.id into active_team
  from public.hybrid_kotc_teams t
  where t.facility_id=fid and t.court_number=p_court_number and t.status='current'
    and (exists(select 1 from public.hybrid_kotc_slots s where s.facility_id=fid and s.team_id=t.id and s.player_id=p_player_id)
      or exists(select 1 from public.hybrid_kotc_substitutes hs where hs.facility_id=fid and hs.team_id=t.id and hs.player_id=p_player_id))
  for update;
  if active_team is null then
    raise exception 'This player is not active in this Waitlist KOTC appearance.';
  end if;
  select id into active_slot from public.hybrid_kotc_slots
    where facility_id=fid and team_id=active_team and player_id=p_player_id for update;
  select id into active_substitute from public.hybrid_kotc_substitutes
    where facility_id=fid and team_id=active_team and player_id=p_player_id for update;
  if active_slot is null and active_substitute is null then
    raise exception 'This player is not active in this Waitlist KOTC appearance.';
  end if;

  if public.is_waitlist_operator() then
    perform public.save_admin_undo('sit out Waitlist KOTC player');
  end if;
  delete from public.hybrid_kotc_substitutes
    where facility_id=fid and team_id=active_team and player_id=p_player_id;
  update public.hybrid_kotc_slots set player_id=null,is_substitute=false,updated_at=now()
    where facility_id=fid and team_id=active_team and player_id=p_player_id;
  skip_game:=court.game_number;
  update public.waitlist_players
    set status='sitout',sitout_priority=true,sitout_from_game=skip_game,updated_at=now()
    where facility_id=fid and id=p_player_id;
  update public.hybrid_kotc_court_state set version=version+1,updated_at=now()
    where facility_id=fid and court_number=p_court_number and version=p_expected_version;
  if not found then
    raise exception 'This Waitlist KOTC appearance changed. Refresh and try again.';
  end if;
  return jsonb_build_object(
    'message','Player sat out of the Waitlist KOTC appearance.',
    'version',p_expected_version+1,
    'slot_cleared',active_slot is not null,
    'substitute_cleared',active_substitute is not null,
    'skip_game',skip_game
  );
end;
$$;

revoke all on function public.sit_out_hybrid_kotc_player(integer,uuid,uuid,integer,bigint) from public,anon;
grant execute on function public.sit_out_hybrid_kotc_player(integer,uuid,uuid,integer,bigint) to authenticated;
notify pgrst,'reload schema';
