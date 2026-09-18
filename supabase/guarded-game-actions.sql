-- A browser session can have more than one OpenGym tab.  Facility selection is
-- shared by that authenticated session, so high-risk game actions must carry
-- the facility and court game the user actually saw.  Locking the session row
-- keeps a concurrent select_facility call from changing that context between
-- the validation and the state transition.

create or replace function public.assert_expected_facility(p_facility_id uuid)
returns uuid language plpgsql security definer set search_path=public as $$
declare selected uuid;
begin
  if auth.uid() is null then raise exception 'You must be signed in.'; end if;
  select facility_id into selected from public.user_facility_sessions
    where user_id=auth.uid() for share;
  if selected is distinct from p_facility_id then
    raise exception 'This tab is no longer connected to the facility shown on screen. Refresh and try again.';
  end if;
  return selected;
end;
$$;

create or replace function public.assert_expected_court_game(p_facility_id uuid,p_court_number integer,p_game_number integer)
returns void language plpgsql security definer set search_path=public as $$
declare current_game integer;
begin
  perform public.assert_expected_facility(p_facility_id);
  select game_number into current_game from public.waitlist_courts
    where facility_id=p_facility_id and court_number=p_court_number for update;
  if current_game is null then raise exception 'That court is not active.'; end if;
  if current_game is distinct from p_game_number then
    raise exception 'This game has already changed. Refresh and try again.';
  end if;
end;
$$;

create or replace function public.advance_court_game(p_court_number integer,p_facility_id uuid,p_expected_game_number integer)
returns jsonb language plpgsql security definer set search_path=public as $$
begin
  perform public.assert_expected_court_game(p_facility_id,p_court_number,p_expected_game_number);
  return public.end_court_game(p_court_number);
end;
$$;

create or replace function public.advance_team_rotation(p_court_number integer,p_facility_id uuid,p_expected_game_number integer)
returns jsonb language plpgsql security definer set search_path=public as $$
begin
  perform public.assert_expected_court_game(p_facility_id,p_court_number,p_expected_game_number);
  return public.end_team_rotation(p_court_number);
end;
$$;

create or replace function public.advance_team_king_game(p_court_number integer,p_winning_team_id uuid,p_facility_id uuid,p_expected_game_number integer)
returns jsonb language plpgsql security definer set search_path=public as $$
begin
  perform public.assert_expected_court_game(p_facility_id,p_court_number,p_expected_game_number);
  return public.end_team_king_game(p_court_number,p_winning_team_id);
end;
$$;

create or replace function public.reverse_past_game_guarded(p_game_id uuid,p_facility_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
begin
  perform public.assert_expected_facility(p_facility_id);
  return public.reverse_past_game(p_game_id);
end;
$$;

revoke all on function public.assert_expected_facility(uuid) from public,anon,authenticated;
revoke all on function public.assert_expected_court_game(uuid,integer,integer) from public,anon,authenticated;
revoke execute on function public.end_court_game(integer) from authenticated;
revoke execute on function public.end_team_rotation(integer) from authenticated;
revoke execute on function public.end_team_king_game(integer,uuid) from authenticated;
revoke execute on function public.reverse_past_game(uuid) from authenticated;
grant execute on function public.advance_court_game(integer,uuid,integer) to authenticated;
grant execute on function public.advance_team_rotation(integer,uuid,integer) to authenticated;
grant execute on function public.advance_team_king_game(integer,uuid,uuid,integer) to authenticated;
grant execute on function public.reverse_past_game_guarded(uuid,uuid) to authenticated;
notify pgrst,'reload schema';
