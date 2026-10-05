-- Stage 1B: the authoritative, guarded KOTC result core.  Formation/packing
-- is deliberately separate; this transition never uses player.team_id and
-- never turns temporary appearances into permanent groups.
create or replace function public.end_hybrid_kotc_game(
  p_court_number integer,
  p_winning_team_id uuid,
  p_expected_version bigint
)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  fid uuid:=public.current_facility_id(); cfg public.waitlist_config;
  court public.waitlist_courts; court_state public.hybrid_kotc_court_state;
  winner public.hybrid_kotc_teams; loser public.hybrid_kotc_teams;
  caller public.waitlist_players; reversal_before jsonb; next_game integer;
  winner_stays boolean;
begin
  perform pg_advisory_xact_lock(7429301);
  select * into cfg from public.waitlist_config where facility_id=fid and id for update;
  if cfg.mode<>'hybrid_waitlist' or cfg.hybrid_rotation_rule<>'kotc' then
    raise exception 'This facility is not using Waitlist King of the Court.';
  end if;
  select * into court from public.waitlist_courts
    where facility_id=fid and court_number=p_court_number for update;
  if court.court_number is null then raise exception 'That court is not active.'; end if;
  select * into court_state from public.hybrid_kotc_court_state
    where facility_id=fid and court_number=p_court_number for update;
  if court_state.facility_id is null or court_state.version is distinct from p_expected_version then
    raise exception 'This Waitlist KOTC court changed. Refresh and try again.';
  end if;
  select * into winner from public.hybrid_kotc_teams
    where id=p_winning_team_id and facility_id=fid and court_number=p_court_number and status='current' for update;
  select * into loser from public.hybrid_kotc_teams
    where facility_id=fid and court_number=p_court_number and status='current' and id<>p_winning_team_id
    order by court_side for update;
  if winner.id is null or loser.id is null then raise exception 'Two active Waitlist KOTC teams are required on this court.'; end if;
  select * into caller from public.waitlist_players where facility_id=fid and user_id=auth.uid();
  if not public.is_waitlist_operator() and (caller.id is null or caller.restricted or not exists(
    select 1 from public.hybrid_kotc_slots s where s.facility_id=fid and s.player_id=caller.id and s.team_id in(winner.id,loser.id)
    union all
    select 1 from public.hybrid_kotc_substitutes s where s.facility_id=fid and s.player_id=caller.id and s.team_id in(winner.id,loser.id)
  )) then
    raise exception 'Only a player on this court or an admin/host can record the winner.';
  end if;
  reversal_before:=public.capture_court_reversal_state();
  insert into public.past_games(facility_id,game_number,court_number,player_names)
    select fid,court.game_number,p_court_number,
      coalesce(jsonb_agg(p.display_name order by t.court_side,s.slot_number),'[]'::jsonb)
    from public.hybrid_kotc_teams t
    join public.hybrid_kotc_slots s on s.facility_id=fid and s.team_id=t.id
    left join public.waitlist_players p on p.facility_id=fid and p.id=s.player_id
    where t.facility_id=fid and t.id in(winner.id,loser.id) and s.player_id is not null;
  winner_stays:=court.team_max_wins is null or winner.consecutive_wins+1<court.team_max_wins;
  -- Retiring only changes temporary appearance state. Player group_id is never
  -- read or written here; the later packing transition owns queue placement.
  update public.hybrid_kotc_teams set status='retired',updated_at=now()
    where facility_id=fid and id=loser.id;
  update public.waitlist_players p set status='waiting',court_number=null,updated_at=now()
    where p.facility_id=fid and p.status='current' and exists(
      select 1 from public.hybrid_kotc_slots s where s.facility_id=fid and s.team_id=loser.id and s.player_id=p.id
    );
  if winner_stays then
    update public.hybrid_kotc_teams set consecutive_wins=consecutive_wins+1,updated_at=now()
      where facility_id=fid and id=winner.id;
  else
    update public.hybrid_kotc_teams set status='retired',consecutive_wins=0,updated_at=now()
      where facility_id=fid and id=winner.id;
    update public.waitlist_players p set status='waiting',court_number=null,updated_at=now()
      where p.facility_id=fid and p.status='current' and exists(
        select 1 from public.hybrid_kotc_slots s where s.facility_id=fid and s.team_id=winner.id and s.player_id=p.id
      );
  end if;
  next_game:=greatest(cfg.game_number,(select coalesce(max(game_number),0) from public.waitlist_courts where facility_id=fid),(select coalesce(max(game_number),0) from public.past_games where facility_id=fid))+1;
  update public.waitlist_config set game_number=next_game,updated_at=now() where facility_id=fid and id;
  update public.waitlist_courts set game_number=next_game,started_at=now() where facility_id=fid and court_number=p_court_number;
  update public.hybrid_kotc_court_state set version=version+1,updated_at=now()
    where facility_id=fid and court_number=p_court_number and version=p_expected_version;
  if not found then raise exception 'This Waitlist KOTC court changed. Refresh and try again.'; end if;
  perform public.record_court_reversal(reversal_before,p_court_number);
  insert into public.waitlist_events(facility_id,actor_user_id,actor_name,event_type,message)
    values(fid,auth.uid(),coalesce(caller.display_name,'Admin'),'hybrid_king_game','Waitlist KOTC result recorded on Court '||p_court_number||'.');
  return jsonb_build_object('message','Waitlist KOTC result recorded.','game_number',next_game,'winner_stays',winner_stays,'version',p_expected_version+1);
end;
$$;

create or replace function public.advance_hybrid_kotc_game(
  p_court_number integer,
  p_winning_team_id uuid,
  p_facility_id uuid,
  p_expected_game_number integer,
  p_expected_version bigint
)
returns jsonb language plpgsql security definer set search_path=public as $$
begin
  perform public.assert_expected_court_game(p_facility_id,p_court_number,p_expected_game_number);
  return public.end_hybrid_kotc_game(p_court_number,p_winning_team_id,p_expected_version);
end;
$$;

revoke all on function public.end_hybrid_kotc_game(integer,uuid,bigint) from public,anon,authenticated;
revoke all on function public.advance_hybrid_kotc_game(integer,uuid,uuid,integer,bigint) from public,anon;
grant execute on function public.advance_hybrid_kotc_game(integer,uuid,uuid,integer,bigint) to authenticated;
grant execute on function public.end_hybrid_kotc_game(integer,uuid,bigint) to opengym_runtime;
notify pgrst,'reload schema';
