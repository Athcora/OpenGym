-- past_games.game_number is facility-wide, while court game counters are
-- court-local. Allocate the facility-wide identity before writing history.
create or replace function public.end_hybrid_kotc_game(p_court_number integer,p_reported_result text,p_expected_version bigint)
returns jsonb language plpgsql security definer set search_path=public as $$
declare fid uuid:=public.current_facility_id(); cfg public.waitlist_config; court public.waitlist_courts;
  court_state public.hybrid_kotc_court_state; caller public.waitlist_players; reporter_team uuid;
  winner public.hybrid_kotc_teams; loser public.hybrid_kotc_teams; next_game integer; winner_stays boolean;
  incoming_one uuid; incoming_two uuid; reversal_before jsonb;
begin
  perform pg_advisory_xact_lock(hashtextextended(fid::text,7429301));
  if p_reported_result not in('win','lose') then raise exception 'Result must be Win or Lose.'; end if;
  select * into cfg from public.waitlist_config where facility_id=fid and id for update;
  if cfg.mode<>'hybrid_waitlist' or cfg.hybrid_rotation_rule<>'kotc' then raise exception 'This facility is not using Waitlist King of the Court.'; end if;
  select * into court from public.waitlist_courts where facility_id=fid and court_number=p_court_number for update;
  select * into court_state from public.hybrid_kotc_court_state where facility_id=fid and court_number=p_court_number for update;
  if court.court_number is null or court_state.facility_id is null or court_state.version is distinct from p_expected_version then raise exception 'This Waitlist KOTC court changed. Refresh and try again.'; end if;
  select * into caller from public.waitlist_players where facility_id=fid and user_id=auth.uid() for update;
  if caller.id is null or caller.restricted then raise exception 'Only an active player on this court can report this result.'; end if;
  select team_id into reporter_team from (
    select s.team_id from public.hybrid_kotc_slots s join public.hybrid_kotc_teams t on t.id=s.team_id and t.facility_id=s.facility_id where s.facility_id=fid and s.player_id=caller.id and t.status='current' and t.court_number=p_court_number
    union all select s.team_id from public.hybrid_kotc_substitutes s join public.hybrid_kotc_teams t on t.id=s.team_id and t.facility_id=s.facility_id where s.facility_id=fid and s.player_id=caller.id and t.status='current' and t.court_number=p_court_number
  ) reporter limit 1;
  if reporter_team is null then raise exception 'Only a player on this court can report this result.'; end if;
  select * into winner from public.hybrid_kotc_teams where facility_id=fid and court_number=p_court_number and status='current' and id=case when p_reported_result='win' then reporter_team else (select id from public.hybrid_kotc_teams where facility_id=fid and court_number=p_court_number and status='current' and id<>reporter_team order by court_side limit 1) end for update;
  select * into loser from public.hybrid_kotc_teams where facility_id=fid and court_number=p_court_number and status='current' and id<>winner.id for update;
  if winner.id is null or loser.id is null then raise exception 'Two active Waitlist KOTC teams are required on this court.'; end if;
  next_game:=greatest(cfg.game_number,(select coalesce(max(game_number),0) from public.waitlist_courts where facility_id=fid),(select coalesce(max(game_number),0) from public.past_games where facility_id=fid))+1;
  reversal_before:=public.capture_court_reversal_state();
  insert into public.past_games(facility_id,game_number,court_number,player_names)
    select fid,next_game,p_court_number,coalesce(jsonb_agg(p.display_name order by t.court_side,s.slot_number),'[]'::jsonb)
    from public.hybrid_kotc_teams t join public.hybrid_kotc_slots s on s.facility_id=fid and s.team_id=t.id left join public.waitlist_players p on p.facility_id=fid and p.id=s.player_id
    where t.facility_id=fid and t.id in(winner.id,loser.id) and s.player_id is not null;
  winner_stays:=court.team_max_wins is null or winner.consecutive_wins+1<court.team_max_wins;
  perform public.retire_hybrid_kotc_team(loser.id,next_game);
  if winner_stays then update public.hybrid_kotc_teams set consecutive_wins=consecutive_wins+1,updated_at=now() where facility_id=fid and id=winner.id; incoming_one:=public.form_hybrid_kotc_side(p_court_number,loser.court_side,next_game);
  else perform public.retire_hybrid_kotc_team(winner.id,next_game); incoming_one:=public.form_hybrid_kotc_side(p_court_number,1,next_game); incoming_two:=public.form_hybrid_kotc_side(p_court_number,2,next_game); end if;
  update public.waitlist_config set game_number=next_game,updated_at=now() where facility_id=fid and id;
  update public.waitlist_courts set game_number=next_game,started_at=now() where facility_id=fid and court_number=p_court_number;
  update public.hybrid_kotc_court_state set version=version+1,updated_at=now() where facility_id=fid and court_number=p_court_number and version=p_expected_version;
  if not found then raise exception 'This Waitlist KOTC court changed. Refresh and try again.'; end if;
  perform public.record_court_reversal(reversal_before,p_court_number);
  insert into public.waitlist_events(facility_id,actor_user_id,actor_name,event_type,message) values(fid,auth.uid(),caller.display_name,'hybrid_king_game','Waitlist KOTC result recorded on Court '||p_court_number||'.');
  return jsonb_build_object('message','Waitlist KOTC result recorded.','game_number',next_game,'winner_stays',winner_stays,'version',p_expected_version+1,'incoming_team_id',incoming_one,'second_incoming_team_id',incoming_two);
end;
$$;
revoke all on function public.end_hybrid_kotc_game(integer,text,bigint) from public,anon,authenticated;
grant execute on function public.end_hybrid_kotc_game(integer,text,bigint) to opengym_runtime;
notify pgrst,'reload schema';
