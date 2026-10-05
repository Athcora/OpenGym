-- The legacy snapshot restore runs first inside exact Reverse.  Preserve later
-- terminal/eligibility choices before that restore so PRE cannot resurrect a
-- player who legitimately left or sat out after the recorded result.
create or replace function public.reverse_past_game(p_game_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  saved public.court_game_reversals;
  game public.past_games;
  result jsonb;
  later_eligibility jsonb;
  item jsonb;
begin
  select * into game from public.past_games where id=p_game_id and facility_id=public.current_facility_id() for update;
  select * into saved from public.court_game_reversals where game_id=p_game_id and facility_id=public.current_facility_id();
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',id,'status',status,'sitout_priority',sitout_priority,'sitout_from_game',sitout_from_game
  )),'[]'::jsonb) into later_eligibility
  from public.waitlist_players
  where facility_id=public.current_facility_id() and status in ('left','sitout');
  result:=public.reverse_past_game_legacy(p_game_id);
  for item in select value from jsonb_array_elements(later_eligibility) loop
    update public.waitlist_players set
      status=item->>'status',
      sitout_priority=coalesce((item->>'sitout_priority')::boolean,false),
      sitout_from_game=nullif(item->>'sitout_from_game','')::integer,
      updated_at=now()
    where facility_id=public.current_facility_id() and id=(item->>'id')::uuid;
  end loop;
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
