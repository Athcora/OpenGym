-- Exact Reverse can merge later slot/substitute/group edits on the authoritative
-- POST successor, but it must not rewind across a later game that established
-- an unrelated current appearance on the same court side.
create or replace function public.assert_hybrid_reverse_current_ownership(
  p_after jsonb,
  p_court integer
) returns void language plpgsql security definer set search_path=public as $$
declare
  fid uuid:=public.current_facility_id();
  expected_team jsonb;
  current_team public.hybrid_kotc_teams;
begin
  for expected_team in
    select value
    from jsonb_array_elements(coalesce(p_after->'hybrid_kotc_teams','[]'::jsonb))
    where value->>'status'='current'
      and (value->>'court_number')::integer=p_court
  loop
    select * into current_team
    from public.hybrid_kotc_teams
    where facility_id=fid
      and court_number=p_court
      and court_side=(expected_team->>'court_side')::smallint
      and status='current'
    for update;
    if current_team.id is not null and current_team.id<>(expected_team->>'id')::uuid then
      raise exception 'This Waitlist KOTC appearance changed. Refresh and try again.';
    end if;
  end loop;
end;
$$;

revoke all on function public.assert_hybrid_reverse_current_ownership(jsonb,integer) from public, anon, authenticated;
grant execute on function public.assert_hybrid_reverse_current_ownership(jsonb,integer) to opengym_runtime;

create or replace function public.reverse_past_game(p_game_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare saved public.court_game_reversals; game public.past_games; result jsonb;
begin
  select * into game from public.past_games where id=p_game_id and facility_id=public.current_facility_id() for update;
  select * into saved from public.court_game_reversals where game_id=p_game_id and facility_id=public.current_facility_id();
  result:=public.reverse_past_game_legacy(p_game_id);
  if saved.game_id is not null then
    perform public.assert_hybrid_reverse_current_ownership(saved.after_state,game.court_number);
    perform public.apply_hybrid_court_reverse(saved.before_state,saved.after_state,game.court_number);
    perform public.reconcile_hybrid_reverse_player_eligibility(game.court_number);
  end if;
  return result;
end;
$$;

revoke all on function public.reverse_past_game(uuid) from public, anon;
grant execute on function public.reverse_past_game(uuid) to authenticated;
