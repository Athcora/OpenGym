-- Stage 4 read contract. This serializes the already-authoritative temporary
-- KOTC appearance records; it neither creates a team nor changes player/group
-- state. The selected-facility boundary prevents cross-facility board reads.
create or replace function public.read_hybrid_kotc_board()
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  fid uuid:=public.current_facility_id();
  cfg public.waitlist_config;
begin
  if public.current_request_user_id() is null then
    raise exception 'You must be signed in.';
  end if;
  if fid is null then
    raise exception 'Select a facility first.';
  end if;
  select * into cfg from public.waitlist_config where facility_id=fid and id;
  if cfg.id is null then
    raise exception 'Facility configuration not found.';
  end if;

  -- Dormant hybrid and every legacy mode deliberately expose no KOTC board.
  if cfg.mode<>'hybrid_waitlist' or cfg.hybrid_rotation_rule<>'kotc' then
    return jsonb_build_object('mode',cfg.mode,'rotation_rule',cfg.hybrid_rotation_rule,'courts','[]'::jsonb);
  end if;

  return jsonb_build_object(
    'mode',cfg.mode,
    'rotation_rule',cfg.hybrid_rotation_rule,
    'courts',coalesce((
      select jsonb_agg(jsonb_build_object(
        'court_number',c.court_number,
        'game_number',c.game_number,
        'version',state.version,
        'initialized_game_number',state.initialized_game_number,
        'teams',coalesce((
          select jsonb_agg(jsonb_build_object(
            'id',t.id,
            'appearance_game_number',t.appearance_game_number,
            'court_side',t.court_side,
            'consecutive_wins',t.consecutive_wins,
            'slots',coalesce((select jsonb_agg(jsonb_build_object(
              'slot_number',s.slot_number,
              'player_id',s.player_id,
              'player',case when p.id is null then null else jsonb_build_object('id',p.id,'display_name',p.display_name) end,
              'is_substitute',s.is_substitute
            ) order by s.slot_number) from public.hybrid_kotc_slots s left join public.waitlist_players p on p.facility_id=fid and p.id=s.player_id where s.facility_id=fid and s.team_id=t.id),'[]'::jsonb),
            'substitutes',(select coalesce(jsonb_agg(jsonb_build_object('id',hs.id,'player_id',hs.player_id,'player',case when sp.id is null then null else jsonb_build_object('id',sp.id,'display_name',sp.display_name) end) order by hs.created_at,hs.id),'[]'::jsonb) from public.hybrid_kotc_substitutes hs left join public.waitlist_players sp on sp.facility_id=fid and sp.id=hs.player_id where hs.facility_id=fid and hs.team_id=t.id)
          ) order by t.court_side) from public.hybrid_kotc_teams t where t.facility_id=fid and t.court_number=c.court_number and t.status='current'
        ),'[]'::jsonb)
      ) order by c.court_number)
      from public.waitlist_courts c left join public.hybrid_kotc_court_state state on state.facility_id=fid and state.court_number=c.court_number
      where c.facility_id=fid and c.court_number<=cfg.court_count
    ),'[]'::jsonb)
  );
end;
$$;

revoke all on function public.read_hybrid_kotc_board() from public,anon;
grant execute on function public.read_hybrid_kotc_board() to authenticated;
notify pgrst,'reload schema';
