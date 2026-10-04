-- The final schema has no waitlist_courts.updated_at.  Court configuration
-- versions are the authoritative concurrency signal, so retain their updates
-- while removing only the obsolete timestamp touches.
create or replace function public.evaluate_hybrid_auto_kotc_transition(p_facility_id uuid)
returns boolean language plpgsql security definer set search_path=public as $$
declare eligible_count integer; changed boolean:=false; court public.waitlist_courts;
begin
  perform pg_advisory_xact_lock(hashtextextended(p_facility_id::text,7429401));
  if not exists(select 1 from public.waitlist_config where facility_id=p_facility_id and mode='hybrid_waitlist') then return false; end if;
  eligible_count:=public.hybrid_eligible_player_count(p_facility_id);
  for court in select * from public.waitlist_courts where facility_id=p_facility_id and hybrid_rotation_rule='two_on_two_off' and hybrid_auto_kotc_threshold_teams is not null for update loop
    if eligible_count < court.hybrid_auto_kotc_threshold_teams*6 then
      if not court.hybrid_auto_kotc_armed then update public.waitlist_courts set hybrid_auto_kotc_armed=true,hybrid_config_version=hybrid_config_version+1 where facility_id=p_facility_id and court_number=court.court_number; end if;
    elsif court.hybrid_auto_kotc_armed then
      update public.waitlist_courts set hybrid_rotation_rule='kotc',hybrid_auto_kotc_armed=false,hybrid_config_version=hybrid_config_version+1 where facility_id=p_facility_id and court_number=court.court_number;
      changed:=true;
    end if;
  end loop;
  return changed;
end;
$$;

create or replace function public.configure_hybrid_waitlist(
  p_facility_id uuid,p_court_number integer,p_expected_config_version bigint,
  p_rotation_rule text,p_threshold_teams integer,p_king_max_wins integer
) returns jsonb language plpgsql security definer set search_path=public as $$
declare fid uuid:=public.current_facility_id(); court public.waitlist_courts; eligible_count integer; next_armed boolean;
begin
  if fid is null then raise exception 'Select a facility first.'; end if;
  perform public.assert_expected_facility(p_facility_id);
  if not public.is_waitlist_admin() then raise exception 'Admin access required.'; end if;
  if p_rotation_rule not in ('two_on_two_off','kotc') then raise exception 'Unknown Waitlist court format.'; end if;
  if p_threshold_teams is not null and p_threshold_teams not in (3,4,5,6) then raise exception 'Threshold must be 3, 4, 5, 6, or null.'; end if;
  if p_king_max_wins is not null and p_king_max_wins not in (2,3) then raise exception 'Win cap must be 2, 3, or null.'; end if;
  perform pg_advisory_xact_lock(hashtextextended(fid::text,7429401));
  if not exists(select 1 from public.waitlist_config where facility_id=fid and mode='hybrid_waitlist') then raise exception 'This facility is not using Waitlist.'; end if;
  select * into court from public.waitlist_courts where facility_id=fid and court_number=p_court_number for update;
  if court.court_number is null then raise exception 'That court is not active.'; end if;
  if court.hybrid_config_version is distinct from p_expected_config_version then raise exception 'This court configuration changed. Refresh and try again.'; end if;
  eligible_count:=public.hybrid_eligible_player_count(fid);
  next_armed:=p_rotation_rule='two_on_two_off' and p_threshold_teams is not null and eligible_count<p_threshold_teams*6;
  if court.hybrid_rotation_rule is not distinct from p_rotation_rule and court.hybrid_auto_kotc_threshold_teams is not distinct from p_threshold_teams and court.team_max_wins is not distinct from p_king_max_wins and court.hybrid_auto_kotc_armed is not distinct from next_armed then
    return jsonb_build_object('message','Court configuration unchanged.','config_version',court.hybrid_config_version,'eligible_player_count',eligible_count);
  end if;
  perform public.save_admin_undo('change Waitlist court configuration');
  if court.hybrid_rotation_rule='kotc' and p_rotation_rule='two_on_two_off' then perform public.clear_hybrid_kotc_court_lifecycle(fid,p_court_number); end if;
  update public.waitlist_courts set hybrid_rotation_rule=p_rotation_rule,hybrid_auto_kotc_threshold_teams=case when p_rotation_rule='two_on_two_off' then p_threshold_teams else null end,hybrid_auto_kotc_armed=next_armed,team_max_wins=p_king_max_wins,hybrid_config_version=hybrid_config_version+1 where facility_id=fid and court_number=p_court_number;
  select * into court from public.waitlist_courts where facility_id=fid and court_number=p_court_number;
  perform public.log_waitlist_operator_action('hybrid_configuration','changed Waitlist configuration for Court '||p_court_number||'.');
  return jsonb_build_object('message','Waitlist court configuration updated.','court_number',p_court_number,'rotation_rule',court.hybrid_rotation_rule,'threshold_teams',court.hybrid_auto_kotc_threshold_teams,'armed',court.hybrid_auto_kotc_armed,'king_max_wins',court.team_max_wins,'config_version',court.hybrid_config_version,'eligible_player_count',eligible_count);
end;
$$;

-- This retired runtime-only compatibility entrypoint must still be valid if
-- invoked internally.  king_teams has a primary key on id, not (facility_id,id).
create or replace function public.reverse_king_game()
returns jsonb language plpgsql security definer set search_path=public as $$
declare round public.king_round_history; item jsonb;
begin
  select * into round from public.king_round_history
    where facility_id=public.current_facility_id() and reversed_at is null
      and (public.is_waitlist_operator() or actor_user_id=public.current_request_user_id())
    order by id desc limit 1 for update;
  if round.id is null then raise exception 'There is no King of the Court advancement available to reverse.'; end if;
  for item in select * from jsonb_array_elements(round.snapshot->'teams') loop
    insert into public.king_teams(facility_id,id,name,status,queue_position,court_number,court_side,consecutive_wins,created_at,updated_at)
    values(round.facility_id,(item->>'id')::uuid,item->>'name',item->>'status',(item->>'queue_position')::bigint,
      nullif(item->>'court_number','')::integer,nullif(item->>'court_side','')::integer,
      (item->>'consecutive_wins')::integer,(item->>'created_at')::timestamptz,now())
    on conflict(id) do update set name=excluded.name,status=excluded.status,queue_position=excluded.queue_position,
      court_number=excluded.court_number,court_side=excluded.court_side,consecutive_wins=excluded.consecutive_wins,
      updated_at=now();
  end loop;
  for item in select * from jsonb_array_elements(round.snapshot->'players') loop
    update public.waitlist_players set status=item->>'status',court_number=nullif(item->>'court_number','')::integer,
      team_id=nullif(item->>'team_id','')::uuid,updated_at=now()
      where facility_id=round.facility_id and id=(item->>'id')::uuid;
  end loop;
  update public.waitlist_courts set game_number=(round.snapshot->'court'->>'game_number')::integer,
    started_at=(round.snapshot->'court'->>'started_at')::timestamptz
    where facility_id=round.facility_id and court_number=round.court_number;
  update public.waitlist_config set game_number=(round.snapshot->>'config_game_number')::integer,updated_at=now()
    where facility_id=round.facility_id and id;
  delete from public.past_games where facility_id=round.facility_id and game_number=round.game_number and court_number=round.court_number;
  update public.king_round_history set reversed_at=now() where facility_id=round.facility_id and id=round.id;
  return jsonb_build_object('message','The previous King of the Court game and team order were restored.');
end;
$$;

revoke all on function public.evaluate_hybrid_auto_kotc_transition(uuid) from public,anon,authenticated;
grant execute on function public.evaluate_hybrid_auto_kotc_transition(uuid) to opengym_runtime;
revoke all on function public.configure_hybrid_waitlist(uuid,integer,bigint,text,integer,integer) from public,anon;
grant execute on function public.configure_hybrid_waitlist(uuid,integer,bigint,text,integer,integer) to authenticated;
revoke all on function public.reverse_king_game() from public,anon,authenticated;
grant execute on function public.reverse_king_game() to opengym_runtime;
notify pgrst,'reload schema';
