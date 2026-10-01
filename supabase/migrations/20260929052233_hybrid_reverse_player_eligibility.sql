-- A later legitimate Sit Out or Leave wins over a game-owned slot restoration.
-- Reconcile only the authoritative court after its hybrid three-way merge, in
-- the same transaction as legacy Reverse and the court-version CAS.
create or replace function public.reconcile_hybrid_reverse_player_eligibility(p_court integer)
returns void language plpgsql security definer set search_path=public as $$
declare fid uuid:=public.current_facility_id();
begin
  delete from public.hybrid_kotc_substitutes s
    using public.hybrid_kotc_teams t, public.waitlist_players p
    where s.facility_id=fid and s.team_id=t.id and t.facility_id=fid
      and t.court_number=p_court and t.status='current'
      and p.id=s.player_id and p.facility_id=fid and p.status in ('sitout','left');
  update public.hybrid_kotc_slots s set player_id=null,is_substitute=false,updated_at=now()
    from public.hybrid_kotc_teams t, public.waitlist_players p
    where s.facility_id=fid and s.team_id=t.id and t.facility_id=fid
      and t.court_number=p_court and t.status='current'
      and p.id=s.player_id and p.facility_id=fid and p.status in ('sitout','left');
end;
$$;
revoke all on function public.reconcile_hybrid_reverse_player_eligibility(integer) from public, anon, authenticated;
grant execute on function public.reconcile_hybrid_reverse_player_eligibility(integer) to opengym_runtime;

create or replace function public.reverse_past_game(p_game_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare saved public.court_game_reversals; game public.past_games; result jsonb;
begin
  select * into game from public.past_games where id=p_game_id and facility_id=public.current_facility_id() for update;
  select * into saved from public.court_game_reversals where game_id=p_game_id and facility_id=public.current_facility_id();
  result:=public.reverse_past_game_legacy(p_game_id);
  if saved.game_id is not null then
    perform public.apply_hybrid_court_reverse(saved.before_state,saved.after_state,game.court_number);
    perform public.reconcile_hybrid_reverse_player_eligibility(game.court_number);
  end if;
  return result;
end;
$$;
revoke all on function public.reverse_past_game(uuid) from public, anon;
grant execute on function public.reverse_past_game(uuid) to authenticated;
