-- Queue packing is internal-only. A group is a queue unit, never a temporary
-- KOTC membership record. Units skipped for one side are left untouched and so
-- are considered first again while forming the next side.
create or replace function public.form_hybrid_kotc_side(p_court integer,p_side smallint,p_game integer)
returns uuid language plpgsql security definer set search_path=public as $$
declare fid uuid:=public.current_facility_id(); team_id uuid; unit record; member record;
  remaining integer:=6; slot_no smallint:=1; unit_no integer:=0;
begin
  perform 1 from public.waitlist_players p
    where p.facility_id=fid and p.status='waiting' order by p.queue_position,p.created_at,p.id for update;
  insert into public.hybrid_kotc_teams(facility_id,court_number,court_side,appearance_game_number,status,consecutive_wins)
    values(fid,p_court,p_side,p_game,'current',0) returning id into team_id;
  for unit in
    with candidate as (
      select p.id,p.group_id,p.queue_position,p.created_at
      from public.waitlist_players p
      where p.facility_id=fid and p.status='waiting' and not p.restricted
        and (p.group_id is null or not exists(
          select 1 from public.waitlist_players related
          where related.facility_id=fid and related.group_id=p.group_id and related.status<>'left'
            and (related.status<>'waiting' or related.restricted)
        ))
    )
    select coalesce(group_id,id) as unit_id,count(*)::integer as unit_size,
      min(queue_position) as priority,min(created_at) as created_at
    from candidate group by coalesce(group_id,id)
    order by min(queue_position) nulls last,min(created_at),coalesce(group_id,id)
  loop
    if unit.unit_size>remaining then continue; end if;
    unit_no:=unit_no+1;
    for member in
      select p.id,p.group_id,p.queue_position
      from public.waitlist_players p
      where p.facility_id=fid and p.status='waiting'
        and coalesce(p.group_id,p.id)=unit.unit_id
      order by p.queue_position nulls last,p.created_at,p.id
    loop
      insert into public.hybrid_kotc_slots(facility_id,team_id,slot_number,player_id,original_group_id,original_unit_order,original_queue_position,is_substitute)
        values(fid,team_id,slot_no,member.id,member.group_id,unit_no,member.queue_position,false);
      update public.waitlist_players set status='current',court_number=p_court,rejoin_expires_at=null,updated_at=now()
        where facility_id=fid and id=member.id and status='waiting';
      slot_no:=slot_no+1; remaining:=remaining-1;
    end loop;
    exit when remaining=0;
  end loop;
  while slot_no<=6 loop
    insert into public.hybrid_kotc_slots(facility_id,team_id,slot_number,player_id,is_substitute)
      values(fid,team_id,slot_no,null,false);
    slot_no:=slot_no+1;
  end loop;
  return team_id;
end;
$$;

create or replace function public.retire_hybrid_kotc_team(p_team_id uuid,p_next_game integer)
returns void language plpgsql security definer set search_path=public as $$
declare fid uuid:=public.current_facility_id(); expiry timestamptz:=now()+interval '5 minutes'; substitute_start bigint;
begin
  if not exists(select 1 from public.hybrid_kotc_teams where id=p_team_id and facility_id=fid and status='current' for update) then
    raise exception 'Waitlist KOTC team is no longer active.';
  end if;
  update public.waitlist_players p set status='rejoin',court_number=null,
    rejoin_expires_at=case when p.user_id is null then now()+interval '15 minutes' else expiry end,updated_at=now()
    where p.facility_id=fid and p.status='current' and exists(
      select 1 from public.hybrid_kotc_slots s
      where s.facility_id=fid and s.team_id=p_team_id and s.player_id=p.id and not s.is_substitute
    );
  insert into public.rejoin_responses(facility_id,user_id,game_number,original_position,expires_at)
    select fid,p.user_id,p_next_game,p.queue_position,p.rejoin_expires_at
    from public.waitlist_players p
    where p.facility_id=fid and p.status='rejoin' and p.rejoin_expires_at>=expiry and p.user_id is not null
      and exists(select 1 from public.hybrid_kotc_slots s where s.facility_id=fid and s.team_id=p_team_id and s.player_id=p.id and not s.is_substitute)
    on conflict do nothing;
  select coalesce(max(queue_position),0) into substitute_start from public.waitlist_players where facility_id=fid;
  with substitutes as (
    select s.player_id,row_number() over(order by s.created_at,s.player_id) as rn
    from public.hybrid_kotc_substitutes s where s.facility_id=fid and s.team_id=p_team_id
  )
  update public.waitlist_players p set status='waiting',court_number=null,rejoin_expires_at=null,
    queue_position=substitute_start+substitutes.rn,updated_at=now()
    from substitutes where p.facility_id=fid and p.id=substitutes.player_id and p.status<>'left';
  delete from public.hybrid_kotc_substitutes where facility_id=fid and team_id=p_team_id;
  update public.hybrid_kotc_teams set status='retired',updated_at=now() where facility_id=fid and id=p_team_id;
end;
$$;

-- Replace the provisional identifier-based public contract. A caller now sends
-- only Win/Lose for their own active side; the server resolves both teams.
create or replace function public.end_hybrid_kotc_game(p_court_number integer,p_reported_result text,p_expected_version bigint)
returns jsonb language plpgsql security definer set search_path=public as $$
declare fid uuid:=public.current_facility_id(); cfg public.waitlist_config; court public.waitlist_courts;
  court_state public.hybrid_kotc_court_state; caller public.waitlist_players;
  reporter_team uuid; winner public.hybrid_kotc_teams; loser public.hybrid_kotc_teams;
  next_game integer; winner_stays boolean; incoming_one uuid; incoming_two uuid; reversal_before jsonb;
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
    select s.team_id from public.hybrid_kotc_slots s join public.hybrid_kotc_teams t on t.id=s.team_id and t.facility_id=s.facility_id
      where s.facility_id=fid and s.player_id=caller.id and t.status='current' and t.court_number=p_court_number
    union all
    select s.team_id from public.hybrid_kotc_substitutes s join public.hybrid_kotc_teams t on t.id=s.team_id and t.facility_id=s.facility_id
      where s.facility_id=fid and s.player_id=caller.id and t.status='current' and t.court_number=p_court_number
  ) reporter limit 1;
  if reporter_team is null then raise exception 'Only a player on this court can report this result.'; end if;
  select * into winner from public.hybrid_kotc_teams where facility_id=fid and court_number=p_court_number and status='current' and id=case when p_reported_result='win' then reporter_team else (select id from public.hybrid_kotc_teams where facility_id=fid and court_number=p_court_number and status='current' and id<>reporter_team order by court_side limit 1) end for update;
  select * into loser from public.hybrid_kotc_teams where facility_id=fid and court_number=p_court_number and status='current' and id<>winner.id for update;
  if winner.id is null or loser.id is null then raise exception 'Two active Waitlist KOTC teams are required on this court.'; end if;
  reversal_before:=public.capture_court_reversal_state();
  insert into public.past_games(facility_id,game_number,court_number,player_names)
    select fid,court.game_number,p_court_number,coalesce(jsonb_agg(p.display_name order by t.court_side,s.slot_number),'[]'::jsonb)
    from public.hybrid_kotc_teams t join public.hybrid_kotc_slots s on s.facility_id=fid and s.team_id=t.id
      left join public.waitlist_players p on p.facility_id=fid and p.id=s.player_id
    where t.facility_id=fid and t.id in(winner.id,loser.id) and s.player_id is not null;
  next_game:=greatest(cfg.game_number,(select coalesce(max(game_number),0) from public.waitlist_courts where facility_id=fid),(select coalesce(max(game_number),0) from public.past_games where facility_id=fid))+1;
  winner_stays:=court.team_max_wins is null or winner.consecutive_wins+1<court.team_max_wins;
  perform public.retire_hybrid_kotc_team(loser.id,next_game);
  if winner_stays then
    update public.hybrid_kotc_teams set consecutive_wins=consecutive_wins+1,updated_at=now() where facility_id=fid and id=winner.id;
    incoming_one:=public.form_hybrid_kotc_side(p_court_number,loser.court_side,next_game);
  else
    perform public.retire_hybrid_kotc_team(winner.id,next_game);
    incoming_one:=public.form_hybrid_kotc_side(p_court_number,1,next_game);
    incoming_two:=public.form_hybrid_kotc_side(p_court_number,2,next_game);
  end if;
  update public.waitlist_config set game_number=next_game,updated_at=now() where facility_id=fid and id;
  update public.waitlist_courts set game_number=next_game,started_at=now() where facility_id=fid and court_number=p_court_number;
  update public.hybrid_kotc_court_state set version=version+1,updated_at=now() where facility_id=fid and court_number=p_court_number and version=p_expected_version;
  if not found then raise exception 'This Waitlist KOTC court changed. Refresh and try again.'; end if;
  perform public.record_court_reversal(reversal_before,p_court_number);
  insert into public.waitlist_events(facility_id,actor_user_id,actor_name,event_type,message) values(fid,auth.uid(),caller.display_name,'hybrid_king_game','Waitlist KOTC result recorded on Court '||p_court_number||'.');
  return jsonb_build_object('message','Waitlist KOTC result recorded.','game_number',next_game,'winner_stays',winner_stays,'version',p_expected_version+1,'incoming_team_id',incoming_one,'second_incoming_team_id',incoming_two);
end;
$$;

create or replace function public.advance_hybrid_kotc_game(p_court_number integer,p_reported_result text,p_facility_id uuid,p_expected_game_number integer,p_expected_version bigint)
returns jsonb language plpgsql security definer set search_path=public as $$
begin
  perform public.assert_expected_court_game(p_facility_id,p_court_number,p_expected_game_number);
  return public.end_hybrid_kotc_game(p_court_number,p_reported_result,p_expected_version);
end;
$$;

revoke all on function public.form_hybrid_kotc_side(integer,smallint,integer),public.retire_hybrid_kotc_team(uuid,integer),public.end_hybrid_kotc_game(integer,text,bigint) from public,anon,authenticated;
revoke all on function public.advance_hybrid_kotc_game(integer,uuid,uuid,integer,bigint) from public,anon,authenticated;
revoke all on function public.advance_hybrid_kotc_game(integer,text,uuid,integer,bigint) from public,anon;
grant execute on function public.form_hybrid_kotc_side(integer,smallint,integer),public.retire_hybrid_kotc_team(uuid,integer),public.end_hybrid_kotc_game(integer,text,bigint) to opengym_runtime;
grant execute on function public.advance_hybrid_kotc_game(integer,text,uuid,integer,bigint) to authenticated;
notify pgrst,'reload schema';
