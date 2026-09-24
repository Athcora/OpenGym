-- Run 4: selected-facility boundary for the remaining direct admin mutations.
-- Keep this replacement atomic: both functions are browser-executable and
-- `admin_restrict_player` records an undo snapshot before mutating state.
begin;

create or replace function public.set_team_court_rules(
  p_court_number integer,
  p_team_mode text,
  p_max_wins integer default 2
)
returns jsonb language plpgsql security definer set search_path=public as $$
declare fid uuid:=public.current_facility_id();
begin
  if fid is null or not public.is_waitlist_operator() then
    raise exception 'Admin or host access required.';
  end if;
  if p_team_mode not in('rotation','king') then
    raise exception 'Choose 2 on, 2 off or King of the Court.';
  end if;
  if p_team_mode='king' and p_max_wins is not null and p_max_wins not in(2,3) then
    raise exception 'Choose 2, 3, or Unlimited consecutive games.';
  end if;
  update public.waitlist_courts
  set team_mode=p_team_mode,
      team_max_wins=case when p_team_mode='rotation' then 2 else p_max_wins end
  where facility_id=fid and court_number=p_court_number;
  if not found then raise exception 'That court is not active.'; end if;
  return jsonb_build_object('message','Court rules updated.');
end;
$$;

create or replace function public.admin_restrict_player(p_player_id uuid,p_restricted boolean)
returns jsonb language plpgsql security definer set search_path=public as $$
declare fid uuid:=public.current_facility_id(); player public.waitlist_players;
begin
  if fid is null or not public.is_waitlist_admin() then
    raise exception 'Admin access required.';
  end if;
  select * into player
  from public.waitlist_players
  where facility_id=fid and id=p_player_id
  for update;
  if player.id is null then raise exception 'Player not found.'; end if;
  perform public.save_admin_undo(case when p_restricted then 'restrict player' else 'unrestrict player' end);
  update public.waitlist_players
  set restricted=p_restricted,updated_at=now()
  where facility_id=fid and id=player.id;
  return jsonb_build_object('message',player.display_name||case when p_restricted
    then ' is restricted from Next Game.' else ' can use Next Game again.' end);
end;
$$;

notify pgrst, 'reload schema';
commit;
