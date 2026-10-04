-- Final court-scoped definition: preserve the accepted-substitute behavior,
-- replacing only the legacy facility-wide KOTC predicate.
create or replace function public.sit_out_hybrid_kotc_player(
  p_court_number integer,p_player_id uuid,p_facility_id uuid,
  p_expected_game_number integer,p_expected_version bigint
) returns jsonb language plpgsql security definer set search_path=public as $$
declare fid uuid:=public.current_facility_id(); court public.waitlist_courts;
  state public.hybrid_kotc_court_state; player public.waitlist_players;
  active_team uuid; active_slot uuid; active_substitute uuid; skip_game integer;
begin
  perform public.assert_expected_facility(p_facility_id);
  select * into court from public.waitlist_courts where facility_id=fid and court_number=p_court_number for update;
  select * into state from public.hybrid_kotc_court_state where facility_id=fid and court_number=p_court_number for update;
  select * into player from public.waitlist_players where facility_id=fid and id=p_player_id for update;
  if not public.is_hybrid_kotc_court(fid,p_court_number)
     or court.game_number is distinct from p_expected_game_number
     or state.version is distinct from p_expected_version
     or player.id is null or player.status not in ('current','waiting')
     or (player.user_id is distinct from public.current_request_user_id() and not public.is_waitlist_operator()) then
    raise exception 'This Waitlist KOTC appearance changed. Refresh and try again.';
  end if;
  select t.id into active_team from public.hybrid_kotc_teams t
    where t.facility_id=fid and t.court_number=p_court_number and t.status='current'
      and (exists(select 1 from public.hybrid_kotc_slots s where s.facility_id=fid and s.team_id=t.id and s.player_id=p_player_id)
        or exists(select 1 from public.hybrid_kotc_substitutes hs where hs.facility_id=fid and hs.team_id=t.id and hs.player_id=p_player_id)) for update;
  if active_team is null then raise exception 'This player is not active in this Waitlist KOTC appearance.'; end if;
  select id into active_slot from public.hybrid_kotc_slots where facility_id=fid and team_id=active_team and player_id=p_player_id for update;
  select id into active_substitute from public.hybrid_kotc_substitutes where facility_id=fid and team_id=active_team and player_id=p_player_id for update;
  if public.is_waitlist_operator() then perform public.save_admin_undo('sit out Waitlist KOTC player'); end if;
  delete from public.hybrid_kotc_substitutes where facility_id=fid and team_id=active_team and player_id=p_player_id;
  update public.hybrid_kotc_slots set player_id=null,is_substitute=false,updated_at=now() where facility_id=fid and team_id=active_team and player_id=p_player_id;
  skip_game:=court.game_number;
  update public.waitlist_players set status='sitout',sitout_priority=true,sitout_from_game=skip_game,updated_at=now() where facility_id=fid and id=p_player_id;
  update public.hybrid_kotc_court_state set version=version+1,updated_at=now() where facility_id=fid and court_number=p_court_number and version=p_expected_version;
  if not found then raise exception 'This Waitlist KOTC appearance changed. Refresh and try again.'; end if;
  return jsonb_build_object('message','Player sat out of the Waitlist KOTC appearance.','version',p_expected_version+1,'slot_cleared',active_slot is not null,'substitute_cleared',active_substitute is not null,'skip_game',skip_game);
end;
$$;

revoke all on function public.sit_out_hybrid_kotc_player(integer,uuid,uuid,integer,bigint) from public,anon;
grant execute on function public.sit_out_hybrid_kotc_player(integer,uuid,uuid,integer,bigint) to authenticated;
notify pgrst,'reload schema';

-- The unknown-side preflight remains read-only.  Its only scope change is the
-- selected-court KOTC predicate; candidate/group selection stays court-local.
create or replace function public.prepare_hybrid_kotc_result(
  p_court_number integer,p_reported_result text,p_facility_id uuid,p_expected_game_number integer,p_expected_version bigint
) returns jsonb language plpgsql security definer set search_path=public as $$
declare fid uuid:=public.current_facility_id(); caller public.waitlist_players; state public.hybrid_kotc_court_state; reporter_team uuid; candidate_ids uuid[]; locked_ids uuid[];
begin
  if p_reported_result not in('win','lose') then raise exception 'Result must be Win or Lose.'; end if;
  perform public.assert_expected_court_game(p_facility_id,p_court_number,p_expected_game_number);
  if not public.is_hybrid_kotc_court(fid,p_court_number) then raise exception 'This court is not using Waitlist King of the Court.'; end if;
  select * into state from public.hybrid_kotc_court_state where facility_id=fid and court_number=p_court_number;
  if state.facility_id is null or state.version is distinct from p_expected_version then raise exception 'This Waitlist KOTC court changed. Refresh and try again.'; end if;
  select * into caller from public.waitlist_players where facility_id=fid and user_id=public.current_request_user_id();
  if caller.id is null or caller.restricted or caller.status<>'current' or caller.court_number is distinct from p_court_number then raise exception 'Only an active player on this court can report this result.'; end if;
  select team_id into reporter_team from (select s.team_id from public.hybrid_kotc_slots s join public.hybrid_kotc_teams t on t.facility_id=s.facility_id and t.id=s.team_id where s.facility_id=fid and s.player_id=caller.id and t.status='current' and t.court_number=p_court_number union all select s.team_id from public.hybrid_kotc_substitutes s join public.hybrid_kotc_teams t on t.facility_id=s.facility_id and t.id=s.team_id where s.facility_id=fid and s.player_id=caller.id and t.status='current' and t.court_number=p_court_number) reporter limit 1;
  if reporter_team is not null then return jsonb_build_object('selection_required',false,'reporter_team_id',reporter_team); end if;
  select array_agg(p.id order by p.queue_position nulls last,p.created_at,p.id) into candidate_ids from public.waitlist_players p where p.facility_id=fid and p.status='current' and p.court_number=p_court_number and not p.restricted and not exists(select 1 from (select s.player_id from public.hybrid_kotc_slots s join public.hybrid_kotc_teams t on t.facility_id=s.facility_id and t.id=s.team_id where s.facility_id=fid and t.status='current' and t.court_number=p_court_number union all select s.player_id from public.hybrid_kotc_substitutes s join public.hybrid_kotc_teams t on t.facility_id=s.facility_id and t.id=s.team_id where s.facility_id=fid and t.status='current' and t.court_number=p_court_number) occupied where occupied.player_id=p.id);
  if not caller.id=any(coalesce(candidate_ids,'{}'::uuid[])) then raise exception 'Only an unassigned active player on this court can identify this side.'; end if;
  select array_agg(p.id order by p.queue_position nulls last,p.created_at,p.id) into locked_ids from public.waitlist_players p where p.facility_id=fid and p.id=any(candidate_ids) and (p.id=caller.id or (caller.group_id is not null and p.group_id=caller.group_id));
  return jsonb_build_object('selection_required',true,'reporter_player_id',caller.id,'locked_player_ids',coalesce(to_jsonb(locked_ids),'[]'::jsonb),'candidate_player_ids',coalesce(to_jsonb(candidate_ids),'[]'::jsonb),'selected_count',coalesce(cardinality(locked_ids),0),'maximum_selected',6,'game_number',p_expected_game_number,'version',p_expected_version);
end $$;
revoke all on function public.prepare_hybrid_kotc_result(integer,text,uuid,integer,bigint) from public,anon;
grant execute on function public.prepare_hybrid_kotc_result(integer,text,uuid,integer,bigint) to authenticated;
notify pgrst,'reload schema';

create or replace function public.answer_hybrid_kotc_substitute(p_request_id uuid,p_accept boolean)
returns jsonb language plpgsql security definer set search_path=public as $$
declare fid uuid:=public.current_facility_id(); request public.team_substitute_requests; target public.waitlist_players; team public.hybrid_kotc_teams; state public.hybrid_kotc_court_state; court public.waitlist_courts;
begin
  perform pg_advisory_xact_lock(hashtextextended(fid::text,7429302));
  select * into request from public.team_substitute_requests where facility_id=fid and id=p_request_id and hybrid_team_id is not null and status='pending' and created_at>now()-interval '5 minutes' for update;
  if request.id is null then raise exception 'This substitute invitation is no longer available.'; end if;
  select * into target from public.waitlist_players where facility_id=fid and id=request.target_id and user_id=public.current_request_user_id() and status in('waiting','current') for update;
  if target.id is null then raise exception 'Only the invited eligible player can answer this request.'; end if;
  if not p_accept then update public.team_substitute_requests set status='declined',answered_at=now() where facility_id=fid and id=request.id; return jsonb_build_object('message','Substitute invitation declined.'); end if;
  select * into team from public.hybrid_kotc_teams where facility_id=fid and id=request.hybrid_team_id and status='current' for update;
  if team.id is null or not public.is_hybrid_kotc_court(fid,team.court_number) then raise exception 'This KOTC appearance is no longer active.'; end if;
  select * into court from public.waitlist_courts where facility_id=fid and court_number=team.court_number for update;
  select * into state from public.hybrid_kotc_court_state where facility_id=fid and court_number=team.court_number for update;
  if court.game_number is distinct from request.expected_game_number or state.version is distinct from request.expected_version then raise exception 'This KOTC appearance changed. Refresh and try again.'; end if;
  if exists(select 1 from public.hybrid_kotc_slots s join public.hybrid_kotc_teams t on t.id=s.team_id and t.facility_id=s.facility_id where s.facility_id=fid and s.player_id=target.id and t.status='current') or exists(select 1 from public.hybrid_kotc_substitutes s join public.hybrid_kotc_teams t on t.id=s.team_id and t.facility_id=s.facility_id where s.facility_id=fid and s.player_id=target.id and t.status='current') then raise exception 'This player is already assigned to a current KOTC team.'; end if;
  insert into public.hybrid_kotc_substitutes(facility_id,team_id,player_id) values(fid,team.id,target.id);
  update public.team_substitute_requests set status='accepted',answered_at=now() where facility_id=fid and id=request.id;
  update public.team_substitute_requests set status='expired',answered_at=now() where facility_id=fid and target_id=target.id and status='pending' and id<>request.id;
  update public.hybrid_kotc_court_state set version=version+1,updated_at=now() where facility_id=fid and court_number=team.court_number and version=request.expected_version;
  return jsonb_build_object('message','You are now a temporary substitute.','court_number',team.court_number,'version',request.expected_version+1);
end $$;
revoke all on function public.answer_hybrid_kotc_substitute(uuid,boolean) from public,anon;
grant execute on function public.answer_hybrid_kotc_substitute(uuid,boolean) to authenticated;
notify pgrst,'reload schema';

create or replace function public.request_hybrid_kotc_substitute(
  p_court_number integer,p_team_id uuid,p_target_id uuid,p_facility_id uuid,p_expected_game_number integer,p_expected_version bigint
) returns jsonb language plpgsql security definer set search_path=public as $$
declare fid uuid:=public.current_facility_id(); state public.hybrid_kotc_court_state; team public.hybrid_kotc_teams; requester public.waitlist_players; target public.waitlist_players; request_id uuid;
begin
  perform public.assert_expected_court_game(p_facility_id,p_court_number,p_expected_game_number);
  perform pg_advisory_xact_lock(hashtextextended(fid::text,7429302));
  select * into state from public.hybrid_kotc_court_state where facility_id=fid and court_number=p_court_number for update;
  select * into team from public.hybrid_kotc_teams where facility_id=fid and id=p_team_id and court_number=p_court_number and status='current' for update;
  select * into requester from public.waitlist_players where facility_id=fid and user_id=public.current_request_user_id() order by updated_at desc limit 1 for update;
  select * into target from public.waitlist_players where facility_id=fid and id=p_target_id and status in('waiting','current') for update;
  if not public.is_hybrid_kotc_court(fid,p_court_number) or state.version is distinct from p_expected_version or team.id is null then raise exception 'This Waitlist KOTC appearance changed. Refresh and try again.'; end if;
  if requester.id is null or (not public.is_waitlist_operator() and not exists(select 1 from public.hybrid_kotc_slots s where s.facility_id=fid and s.team_id=team.id and s.player_id=requester.id union all select 1 from public.hybrid_kotc_substitutes s where s.facility_id=fid and s.team_id=team.id and s.player_id=requester.id)) then raise exception 'Only this KOTC team or an admin or host can invite a substitute.'; end if;
  if target.id is null or target.id=requester.id or exists(select 1 from public.hybrid_kotc_slots s join public.hybrid_kotc_teams t on t.id=s.team_id and t.facility_id=s.facility_id where s.facility_id=fid and s.player_id=target.id and t.status='current') or exists(select 1 from public.hybrid_kotc_substitutes s join public.hybrid_kotc_teams t on t.id=s.team_id and t.facility_id=s.facility_id where s.facility_id=fid and s.player_id=target.id and t.status='current') then raise exception 'Select an eligible player who is not already assigned to a current KOTC team.'; end if;
  update public.team_substitute_requests set status='expired',answered_at=now() where facility_id=fid and status='pending' and created_at<=now()-interval '5 minutes';
  if exists(select 1 from public.team_substitute_requests where facility_id=fid and target_id=target.id and status='pending') then raise exception 'That player already has a pending substitute invitation.'; end if;
  insert into public.team_substitute_requests(facility_id,hybrid_team_id,requester_id,target_id,expected_game_number,expected_version) values(fid,team.id,requester.id,target.id,p_expected_game_number,p_expected_version) returning id into request_id;
  return jsonb_build_object('request_id',request_id,'message','Substitute invitation sent.','game_number',p_expected_game_number,'version',p_expected_version);
end $$;
revoke all on function public.request_hybrid_kotc_substitute(integer,uuid,uuid,uuid,integer,bigint) from public,anon;
grant execute on function public.request_hybrid_kotc_substitute(integer,uuid,uuid,uuid,integer,bigint) to authenticated;
notify pgrst,'reload schema';

create or replace function public.swap_hybrid_kotc_slot(
  p_court_number integer,p_team_id uuid,p_slot_number smallint,p_replacement_id uuid,p_facility_id uuid,p_expected_game_number integer,p_expected_version bigint
) returns jsonb language plpgsql security definer set search_path=public as $$
declare fid uuid:=public.current_facility_id(); state public.hybrid_kotc_court_state; team public.hybrid_kotc_teams;
  slot_row public.hybrid_kotc_slots; outgoing public.waitlist_players; replacement public.waitlist_players; queue_tail bigint;
begin
  if not public.is_waitlist_operator() then raise exception 'Admin or host access required.'; end if;
  perform public.assert_expected_court_game(p_facility_id,p_court_number,p_expected_game_number);
  perform pg_advisory_xact_lock(hashtextextended(fid::text,7429302));
  select * into state from public.hybrid_kotc_court_state where facility_id=fid and court_number=p_court_number for update;
  select * into team from public.hybrid_kotc_teams where facility_id=fid and id=p_team_id and court_number=p_court_number and status='current' for update;
  select * into slot_row from public.hybrid_kotc_slots where facility_id=fid and team_id=p_team_id and slot_number=p_slot_number and player_id is not null and not is_substitute for update;
  select * into outgoing from public.waitlist_players where facility_id=fid and id=slot_row.player_id for update;
  select * into replacement from public.waitlist_players where facility_id=fid and id=p_replacement_id and status='waiting' for update;
  if not public.is_hybrid_kotc_court(fid,p_court_number) or state.version is distinct from p_expected_version or team.id is null or slot_row.id is null or replacement.id is null then raise exception 'This Waitlist KOTC appearance changed. Refresh and try again.'; end if;
  perform public.save_admin_undo('replace Waitlist KOTC player');
  select coalesce(max(queue_position),0)+1 into queue_tail from public.waitlist_players where facility_id=fid;
  update public.waitlist_players set status='waiting',court_number=null,group_id=null,queue_position=queue_tail,updated_at=now() where facility_id=fid and id=outgoing.id;
  update public.waitlist_players set status='current',court_number=p_court_number,group_id=outgoing.group_id,updated_at=now() where facility_id=fid and id=replacement.id;
  update public.hybrid_kotc_slots set player_id=replacement.id,original_group_id=outgoing.group_id,original_unit_order=slot_row.original_unit_order,original_queue_position=slot_row.original_queue_position,is_substitute=false where facility_id=fid and id=slot_row.id;
  delete from public.hybrid_kotc_substitutes where facility_id=fid and player_id=replacement.id;
  update public.hybrid_kotc_court_state set version=version+1,updated_at=now() where facility_id=fid and court_number=p_court_number and version=p_expected_version;
  return jsonb_build_object('message','KOTC slot replacement completed.','version',p_expected_version+1);
end $$;
revoke all on function public.swap_hybrid_kotc_slot(integer,uuid,smallint,uuid,uuid,integer,bigint) from public,anon;
grant execute on function public.swap_hybrid_kotc_slot(integer,uuid,smallint,uuid,uuid,integer,bigint) to authenticated;
notify pgrst,'reload schema';

create or replace function public.fill_hybrid_kotc_empty_slot(
  p_court_number integer,p_team_id uuid,p_facility_id uuid,p_expected_game_number integer,p_expected_version bigint
) returns jsonb language plpgsql security definer set search_path=public as $$
declare fid uuid:=public.current_facility_id(); state public.hybrid_kotc_court_state;
  team public.hybrid_kotc_teams; filler public.waitlist_players; target_slot public.hybrid_kotc_slots;
begin
  perform public.assert_expected_court_game(p_facility_id,p_court_number,p_expected_game_number);
  perform pg_advisory_xact_lock(hashtextextended(fid::text,7429302));
  select * into state from public.hybrid_kotc_court_state where facility_id=fid and court_number=p_court_number for update;
  select * into team from public.hybrid_kotc_teams where facility_id=fid and id=p_team_id and court_number=p_court_number and status='current' for update;
  select * into filler from public.waitlist_players where facility_id=fid and user_id=public.current_request_user_id() and status='waiting' for update;
  if not public.is_hybrid_kotc_court(fid,p_court_number) or state.version is distinct from p_expected_version or team.id is null then raise exception 'This Waitlist KOTC appearance changed. Refresh and try again.'; end if;
  if filler.id is null then raise exception 'Only an eligible waiting player can fill this KOTC slot.'; end if;
  select * into target_slot from public.hybrid_kotc_slots where facility_id=fid and team_id=team.id and player_id is null order by slot_number for update limit 1;
  if target_slot.id is null then raise exception 'This KOTC team has no open slot.'; end if;
  update public.hybrid_kotc_slots set player_id=filler.id,is_substitute=true,original_group_id=null,original_unit_order=null,original_queue_position=filler.queue_position where id=target_slot.id and facility_id=fid and player_id is null;
  if not found then raise exception 'This KOTC slot changed. Refresh and try again.'; end if;
  insert into public.hybrid_kotc_substitutes(facility_id,team_id,player_id) values(fid,team.id,filler.id);
  update public.waitlist_players set status='current',court_number=p_court_number,updated_at=now() where facility_id=fid and id=filler.id and status='waiting';
  update public.hybrid_kotc_court_state set version=version+1,updated_at=now() where facility_id=fid and court_number=p_court_number and version=p_expected_version;
  return jsonb_build_object('message','You are filling the open KOTC slot.','team_id',team.id,'slot_number',target_slot.slot_number,'version',p_expected_version+1);
end;
$$;

revoke all on function public.fill_hybrid_kotc_empty_slot(integer,uuid,uuid,integer,bigint) from public,anon;
grant execute on function public.fill_hybrid_kotc_empty_slot(integer,uuid,uuid,integer,bigint) to authenticated;
notify pgrst,'reload schema';
