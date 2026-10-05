-- Stage 5 identifies only a genuinely unknown, currently-playing KOTC side.
-- It is intentionally stateless until final confirmation: Back/Cancel has no
-- server mutation.  The completed Stage 1B result engine remains canonical.

create or replace function public.create_hybrid_kotc_identified_side(
  p_court integer,p_side smallint,p_game integer,p_player_ids uuid[]
)
returns uuid language plpgsql security definer set search_path=public as $$
declare fid uuid:=public.current_facility_id(); team_id uuid; member record;
  slot_no smallint:=1;
begin
  if coalesce(cardinality(p_player_ids),0) not between 1 and 6 then
    raise exception 'An identified KOTC side must contain one to six current players.';
  end if;
  insert into public.hybrid_kotc_teams(facility_id,court_number,court_side,appearance_game_number,status,consecutive_wins)
    values(fid,p_court,p_side,p_game,'current',0) returning id into team_id;
  for member in
    with selected as (
      select p.id,p.group_id,p.queue_position,p.created_at,
        coalesce(p.group_id,p.id) as unit_id
      from public.waitlist_players p
      where p.facility_id=fid and p.id=any(p_player_ids)
    ), units as (
      select unit_id,min(queue_position) as priority,min(created_at) as created_at
      from selected group by unit_id
    )
    select s.*,dense_rank() over(order by u.priority nulls last,u.created_at,u.unit_id) as unit_order
    from selected s join units u on u.unit_id=s.unit_id
    order by u.priority nulls last,u.created_at,u.unit_id,s.queue_position nulls last,s.created_at,s.id
  loop
    insert into public.hybrid_kotc_slots(
      facility_id,team_id,slot_number,player_id,original_group_id,
      original_unit_order,original_queue_position,is_substitute
    ) values(
      fid,team_id,slot_no,member.id,member.group_id,member.unit_order,
      member.queue_position,false
    );
    slot_no:=slot_no+1;
  end loop;
  while slot_no<=6 loop
    insert into public.hybrid_kotc_slots(facility_id,team_id,slot_number,player_id,is_substitute)
      values(fid,team_id,slot_no,null,false);
    slot_no:=slot_no+1;
  end loop;
  return team_id;
end;
$$;

-- This read-only preflight gives a thin future client the server-derived
-- locked reporter party and candidates. It creates no selection/session row.
create or replace function public.prepare_hybrid_kotc_result(
  p_court_number integer,p_reported_result text,p_facility_id uuid,
  p_expected_game_number integer,p_expected_version bigint
)
returns jsonb language plpgsql security definer set search_path=public as $$
declare fid uuid:=public.current_facility_id(); caller public.waitlist_players;
  cfg public.waitlist_config; state public.hybrid_kotc_court_state; reporter_team uuid; candidate_ids uuid[];
  locked_ids uuid[];
begin
  if p_reported_result not in('win','lose') then raise exception 'Result must be Win or Lose.'; end if;
  perform public.assert_expected_court_game(p_facility_id,p_court_number,p_expected_game_number);
  select * into cfg from public.waitlist_config where facility_id=fid and id;
  if cfg.mode<>'hybrid_waitlist' or cfg.hybrid_rotation_rule<>'kotc' then
    raise exception 'This facility is not using Waitlist King of the Court.';
  end if;
  select * into state from public.hybrid_kotc_court_state
    where facility_id=fid and court_number=p_court_number;
  if state.facility_id is null or state.version is distinct from p_expected_version then
    raise exception 'This Waitlist KOTC court changed. Refresh and try again.';
  end if;
  select * into caller from public.waitlist_players
    where facility_id=fid and user_id=public.current_request_user_id();
  if caller.id is null or caller.restricted or caller.status<>'current' or caller.court_number is distinct from p_court_number then
    raise exception 'Only an active player on this court can report this result.';
  end if;
  select team_id into reporter_team from (
    select s.team_id from public.hybrid_kotc_slots s join public.hybrid_kotc_teams t
      on t.facility_id=s.facility_id and t.id=s.team_id
      where s.facility_id=fid and s.player_id=caller.id and t.status='current' and t.court_number=p_court_number
    union all
    select s.team_id from public.hybrid_kotc_substitutes s join public.hybrid_kotc_teams t
      on t.facility_id=s.facility_id and t.id=s.team_id
      where s.facility_id=fid and s.player_id=caller.id and t.status='current' and t.court_number=p_court_number
  ) reporter limit 1;
  if reporter_team is not null then
    return jsonb_build_object('selection_required',false,'reporter_team_id',reporter_team);
  end if;
  select array_agg(p.id order by p.queue_position nulls last,p.created_at,p.id) into candidate_ids
  from public.waitlist_players p
  where p.facility_id=fid and p.status='current' and p.court_number=p_court_number and not p.restricted
    and not exists(
      select 1 from (
        select s.player_id from public.hybrid_kotc_slots s join public.hybrid_kotc_teams t on t.facility_id=s.facility_id and t.id=s.team_id
          where s.facility_id=fid and t.status='current' and t.court_number=p_court_number
        union all
        select s.player_id from public.hybrid_kotc_substitutes s join public.hybrid_kotc_teams t on t.facility_id=s.facility_id and t.id=s.team_id
          where s.facility_id=fid and t.status='current' and t.court_number=p_court_number
      ) occupied where occupied.player_id=p.id
    );
  if not caller.id=any(coalesce(candidate_ids,'{}'::uuid[])) then
    raise exception 'Only an unassigned active player on this court can identify this side.';
  end if;
  select array_agg(p.id order by p.queue_position nulls last,p.created_at,p.id) into locked_ids
  from public.waitlist_players p
  where p.facility_id=fid and p.id=any(candidate_ids)
    and (p.id=caller.id or (caller.group_id is not null and p.group_id=caller.group_id));
  return jsonb_build_object(
    'selection_required',true,'reporter_player_id',caller.id,
    'locked_player_ids',coalesce(to_jsonb(locked_ids),'[]'::jsonb),
    'candidate_player_ids',coalesce(to_jsonb(candidate_ids),'[]'::jsonb),
    'selected_count',coalesce(cardinality(locked_ids),0),'maximum_selected',6,
    'game_number',p_expected_game_number,'version',p_expected_version
  );
end;
$$;

-- Preserve exact Reverse semantics for a successful unknown-side confirmation:
-- Stage 1B records its own before snapshot after side materialization, so this
-- private helper replaces that before snapshot with the true pre-confirm state.
create or replace function public.replace_hybrid_kotc_reversal_before(p_before jsonb,p_court integer)
returns void language plpgsql security definer set search_path=public as $$
declare fid uuid:=public.current_facility_id(); gid uuid;
begin
  select r.game_id into gid from public.court_game_reversals r
    join public.past_games g on g.id=r.game_id and g.facility_id=r.facility_id
    where r.facility_id=fid and g.court_number=p_court
    order by r.created_at desc,g.game_number desc,g.id desc limit 1 for update;
  if gid is null then raise exception 'Could not preserve this KOTC game for reversal.'; end if;
  update public.court_game_reversals set before_state=p_before || public.filter_hybrid_court_snapshot(p_before,p_court)
    where facility_id=fid and game_id=gid;
end;
$$;

create or replace function public.confirm_hybrid_kotc_unknown_result(
  p_court_number integer,p_reported_result text,p_facility_id uuid,
  p_expected_game_number integer,p_expected_version bigint,p_selected_player_ids uuid[]
)
returns jsonb language plpgsql security definer set search_path=public as $$
declare fid uuid:=public.current_facility_id(); cfg public.waitlist_config;
  court public.waitlist_courts; state public.hybrid_kotc_court_state;
  caller public.waitlist_players; selected_ids uuid[]; candidate_ids uuid[];
  remaining_ids uuid[]; reporter_team uuid; known_team public.hybrid_kotc_teams;
  known_count integer; reporter_side smallint; before_state jsonb; result jsonb;
begin
  if p_reported_result not in('win','lose') then raise exception 'Result must be Win or Lose.'; end if;
  perform public.assert_expected_court_game(p_facility_id,p_court_number,p_expected_game_number);
  perform pg_advisory_xact_lock(hashtextextended(fid::text,7429301));
  select * into cfg from public.waitlist_config where facility_id=fid and id for update;
  select * into court from public.waitlist_courts where facility_id=fid and court_number=p_court_number for update;
  select * into state from public.hybrid_kotc_court_state where facility_id=fid and court_number=p_court_number for update;
  if cfg.mode<>'hybrid_waitlist' or cfg.hybrid_rotation_rule<>'kotc' or court.court_number is null
    or state.facility_id is null or state.version is distinct from p_expected_version then
    raise exception 'This Waitlist KOTC court changed. Refresh and try again.';
  end if;
  select * into caller from public.waitlist_players where facility_id=fid and user_id=public.current_request_user_id() for update;
  if caller.id is null or caller.restricted or caller.status<>'current' or caller.court_number is distinct from p_court_number then
    raise exception 'Only an active player on this court can report this result.';
  end if;
  select team_id into reporter_team from (
    select s.team_id from public.hybrid_kotc_slots s join public.hybrid_kotc_teams t on t.facility_id=s.facility_id and t.id=s.team_id
      where s.facility_id=fid and s.player_id=caller.id and t.status='current' and t.court_number=p_court_number
    union all
    select s.team_id from public.hybrid_kotc_substitutes s join public.hybrid_kotc_teams t on t.facility_id=s.facility_id and t.id=s.team_id
      where s.facility_id=fid and s.player_id=caller.id and t.status='current' and t.court_number=p_court_number
  ) reporter limit 1;
  if reporter_team is not null then raise exception 'This player already has an authoritative KOTC side.'; end if;
  perform 1 from public.waitlist_players p
    where p.facility_id=fid and p.status='current' and p.court_number=p_court_number order by p.queue_position,p.created_at,p.id for update;
  select array_agg(p.id order by p.queue_position nulls last,p.created_at,p.id) into candidate_ids
  from public.waitlist_players p
  where p.facility_id=fid and p.status='current' and p.court_number=p_court_number and not p.restricted
    and not exists(select 1 from (
      select s.player_id from public.hybrid_kotc_slots s join public.hybrid_kotc_teams t on t.facility_id=s.facility_id and t.id=s.team_id
        where s.facility_id=fid and t.status='current' and t.court_number=p_court_number
      union all
      select s.player_id from public.hybrid_kotc_substitutes s join public.hybrid_kotc_teams t on t.facility_id=s.facility_id and t.id=s.team_id
        where s.facility_id=fid and t.status='current' and t.court_number=p_court_number
    ) occupied where occupied.player_id=p.id);
  select array_agg(distinct id) into selected_ids from unnest(coalesce(p_selected_player_ids,'{}'::uuid[])) id;
  if coalesce(cardinality(selected_ids),0)<>coalesce(cardinality(p_selected_player_ids),0)
    or coalesce(cardinality(selected_ids),0) not between 1 and 6
    or not caller.id=any(selected_ids)
    or exists(select 1 from unnest(selected_ids) id where not id=any(coalesce(candidate_ids,'{}'::uuid[]))) then
    raise exception 'Selected teammates must be unique current players on this court.';
  end if;
  if exists(
    select 1 from public.waitlist_players p
    where p.facility_id=fid and p.id=any(candidate_ids) and p.group_id is not null
      and exists(select 1 from public.waitlist_players selected where selected.id=any(selected_ids) and selected.group_id=p.group_id)
      and not p.id=any(selected_ids)
  ) then raise exception 'Permanent groups must be selected together.'; end if;
  select count(*) into known_count from public.hybrid_kotc_teams
    where facility_id=fid and court_number=p_court_number and status='current';
  if known_count>1 then raise exception 'This Waitlist KOTC court changed. Refresh and try again.'; end if;
  if known_count=1 then
    select * into known_team from public.hybrid_kotc_teams where facility_id=fid and court_number=p_court_number and status='current' for update;
    if cardinality(selected_ids)<>cardinality(candidate_ids) then
      raise exception 'All unassigned current players on this court must identify the missing side.';
    end if;
    reporter_side:=3-known_team.court_side;
  else
    select array_agg(id order by array_position(candidate_ids,id)) into remaining_ids
      from unnest(candidate_ids) id where not id=any(selected_ids);
    if coalesce(cardinality(remaining_ids),0) not between 1 and 6 then
      raise exception 'The opposing current side must contain one to six players.';
    end if;
    reporter_side:=1;
  end if;
  before_state:=public.capture_court_reversal_state();
  perform public.create_hybrid_kotc_identified_side(p_court_number,reporter_side,p_expected_game_number,selected_ids);
  if known_count=0 then
    perform public.create_hybrid_kotc_identified_side(p_court_number,2::smallint,p_expected_game_number,remaining_ids);
  end if;
  result:=public.end_hybrid_kotc_game(p_court_number,p_reported_result,p_expected_version);
  perform public.replace_hybrid_kotc_reversal_before(before_state,p_court_number);
  return result || jsonb_build_object('identified_unknown_side',true);
end;
$$;

-- Existing callers retain the known-team contract. Unknown reporters receive
-- only a stateless selection requirement; no outcome is recorded until confirm.
create or replace function public.advance_hybrid_kotc_game(
  p_court_number integer,p_reported_result text,p_facility_id uuid,
  p_expected_game_number integer,p_expected_version bigint
)
returns jsonb language plpgsql security definer set search_path=public as $$
declare preflight jsonb;
begin
  preflight:=public.prepare_hybrid_kotc_result(p_court_number,p_reported_result,p_facility_id,p_expected_game_number,p_expected_version);
  if coalesce((preflight->>'selection_required')::boolean,false) then return preflight; end if;
  return public.end_hybrid_kotc_game(p_court_number,p_reported_result,p_expected_version);
end;
$$;

revoke all on function public.create_hybrid_kotc_identified_side(integer,smallint,integer,uuid[]),
  public.replace_hybrid_kotc_reversal_before(jsonb,integer) from public,anon,authenticated;
revoke all on function public.prepare_hybrid_kotc_result(integer,text,uuid,integer,bigint),
  public.confirm_hybrid_kotc_unknown_result(integer,text,uuid,integer,bigint,uuid[]) from public,anon;
grant execute on function public.create_hybrid_kotc_identified_side(integer,smallint,integer,uuid[]),
  public.replace_hybrid_kotc_reversal_before(jsonb,integer) to opengym_runtime;
grant execute on function public.prepare_hybrid_kotc_result(integer,text,uuid,integer,bigint),
  public.confirm_hybrid_kotc_unknown_result(integer,text,uuid,integer,bigint,uuid[]) to authenticated;
notify pgrst,'reload schema';
