-- Stage 6 reuses the existing invitation ledger and the existing temporary
-- hybrid substitute association.  `king_teams` remains exclusively legacy.
alter table public.team_substitute_requests
  add column if not exists hybrid_team_id uuid,
  add column if not exists expected_game_number integer,
  add column if not exists expected_version bigint;
alter table public.team_substitute_requests alter column team_id drop not null;
alter table public.team_substitute_requests
  add constraint team_substitute_requests_hybrid_team_fkey
    foreign key (facility_id,hybrid_team_id) references public.hybrid_kotc_teams(facility_id,id) on delete cascade;
alter table public.team_substitute_requests
  add constraint team_substitute_requests_exactly_one_team
    check (num_nonnulls(team_id,hybrid_team_id)=1);
create unique index if not exists team_substitute_requests_pending_hybrid_target_idx
  on public.team_substitute_requests(facility_id,hybrid_team_id,target_id) where status='pending';

-- A temporary substitute may be a roster association or may occupy a slot in
-- that same appearance, but cannot be active on any other appearance.
create or replace function public.assert_hybrid_kotc_substitute_integrity()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  if exists(select 1 from public.hybrid_kotc_substitutes s join public.hybrid_kotc_teams t
      on t.facility_id=s.facility_id and t.id=s.team_id
      where s.facility_id=new.facility_id and s.player_id=new.player_id and s.id<>new.id
        and t.status='current' and s.team_id<>new.team_id) then
    raise exception 'A player cannot substitute for two active Waitlist KOTC teams.';
  end if;
  if exists(select 1 from public.hybrid_kotc_slots s join public.hybrid_kotc_teams t
      on t.facility_id=s.facility_id and t.id=s.team_id
      where s.facility_id=new.facility_id and s.player_id=new.player_id
        and t.status='current' and s.team_id<>new.team_id) then
    raise exception 'A player already occupies another active Waitlist KOTC team.';
  end if;
  return new;
end $$;
drop trigger if exists hybrid_kotc_substitute_integrity on public.hybrid_kotc_substitutes;
create trigger hybrid_kotc_substitute_integrity before insert or update of facility_id,team_id,player_id
  on public.hybrid_kotc_substitutes for each row execute function public.assert_hybrid_kotc_substitute_integrity();

create or replace function public.assert_hybrid_kotc_slot_integrity()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  if new.player_id is null then return new; end if;
  if exists(select 1 from public.hybrid_kotc_slots existing join public.hybrid_kotc_teams team
      on team.id=existing.team_id and team.facility_id=existing.facility_id
      where existing.facility_id=new.facility_id and existing.player_id=new.player_id
        and existing.id<>new.id and team.status='current') then
    raise exception 'A player cannot occupy two active Waitlist KOTC slots.';
  end if;
  if exists(select 1 from public.hybrid_kotc_substitutes s join public.hybrid_kotc_teams t
      on t.id=s.team_id and t.facility_id=s.facility_id
      where s.facility_id=new.facility_id and s.player_id=new.player_id and t.status='current'
        and s.team_id<>new.team_id) then
    raise exception 'A player already substitutes for another active Waitlist KOTC team.';
  end if;
  return new;
end $$;

create or replace function public.request_hybrid_kotc_substitute(
  p_court_number integer,p_team_id uuid,p_target_id uuid,p_facility_id uuid,
  p_expected_game_number integer,p_expected_version bigint
) returns jsonb language plpgsql security definer set search_path=public as $$
declare fid uuid:=public.current_facility_id(); cfg public.waitlist_config; state public.hybrid_kotc_court_state;
  team public.hybrid_kotc_teams; requester public.waitlist_players; target public.waitlist_players; request_id uuid;
begin
  perform public.assert_expected_court_game(p_facility_id,p_court_number,p_expected_game_number);
  perform pg_advisory_xact_lock(hashtextextended(fid::text,7429302));
  select * into cfg from public.waitlist_config where facility_id=fid and id for update;
  select * into state from public.hybrid_kotc_court_state where facility_id=fid and court_number=p_court_number for update;
  select * into team from public.hybrid_kotc_teams where facility_id=fid and id=p_team_id and court_number=p_court_number and status='current' for update;
  select * into requester from public.waitlist_players where facility_id=fid and user_id=public.current_request_user_id() order by updated_at desc limit 1 for update;
  select * into target from public.waitlist_players where facility_id=fid and id=p_target_id and status in('waiting','current') for update;
  if cfg.mode<>'hybrid_waitlist' or cfg.hybrid_rotation_rule<>'kotc' or state.version is distinct from p_expected_version or team.id is null then
    raise exception 'This Waitlist KOTC appearance changed. Refresh and try again.';
  end if;
  if requester.id is null or (not public.is_waitlist_operator() and not exists(
      select 1 from public.hybrid_kotc_slots s where s.facility_id=fid and s.team_id=team.id and s.player_id=requester.id
      union all select 1 from public.hybrid_kotc_substitutes s where s.facility_id=fid and s.team_id=team.id and s.player_id=requester.id)) then
    raise exception 'Only this KOTC team or an admin or host can invite a substitute.';
  end if;
  if target.id is null or target.id=requester.id or exists(select 1 from public.hybrid_kotc_slots s join public.hybrid_kotc_teams t on t.id=s.team_id and t.facility_id=s.facility_id where s.facility_id=fid and s.player_id=target.id and t.status='current')
    or exists(select 1 from public.hybrid_kotc_substitutes s join public.hybrid_kotc_teams t on t.id=s.team_id and t.facility_id=s.facility_id where s.facility_id=fid and s.player_id=target.id and t.status='current') then
    raise exception 'Select an eligible player who is not already assigned to a current KOTC team.';
  end if;
  update public.team_substitute_requests set status='expired',answered_at=now() where facility_id=fid and status='pending' and created_at<=now()-interval '5 minutes';
  if exists(select 1 from public.team_substitute_requests where facility_id=fid and target_id=target.id and status='pending') then raise exception 'That player already has a pending substitute invitation.'; end if;
  insert into public.team_substitute_requests(facility_id,hybrid_team_id,requester_id,target_id,expected_game_number,expected_version)
    values(fid,team.id,requester.id,target.id,p_expected_game_number,p_expected_version) returning id into request_id;
  return jsonb_build_object('request_id',request_id,'message','Substitute invitation sent.','game_number',p_expected_game_number,'version',p_expected_version);
end $$;

create or replace function public.answer_hybrid_kotc_substitute(p_request_id uuid,p_accept boolean)
returns jsonb language plpgsql security definer set search_path=public as $$
declare fid uuid:=public.current_facility_id(); request public.team_substitute_requests; target public.waitlist_players;
  team public.hybrid_kotc_teams; state public.hybrid_kotc_court_state; court public.waitlist_courts;
begin
  perform pg_advisory_xact_lock(hashtextextended(fid::text,7429302));
  select * into request from public.team_substitute_requests where facility_id=fid and id=p_request_id and hybrid_team_id is not null and status='pending' and created_at>now()-interval '5 minutes' for update;
  if request.id is null then raise exception 'This substitute invitation is no longer available.'; end if;
  select * into target from public.waitlist_players where facility_id=fid and id=request.target_id and user_id=public.current_request_user_id() and status in('waiting','current') for update;
  if target.id is null then raise exception 'Only the invited eligible player can answer this request.'; end if;
  if not p_accept then update public.team_substitute_requests set status='declined',answered_at=now() where facility_id=fid and id=request.id; return jsonb_build_object('message','Substitute invitation declined.'); end if;
  select * into team from public.hybrid_kotc_teams where facility_id=fid and id=request.hybrid_team_id and status='current' for update;
  if team.id is null then raise exception 'This KOTC appearance is no longer active.'; end if;
  select * into court from public.waitlist_courts where facility_id=fid and court_number=team.court_number for update;
  select * into state from public.hybrid_kotc_court_state where facility_id=fid and court_number=team.court_number for update;
  if court.game_number is distinct from request.expected_game_number or state.version is distinct from request.expected_version then
    raise exception 'This KOTC appearance changed. Refresh and try again.';
  end if;
  if exists(select 1 from public.hybrid_kotc_slots s join public.hybrid_kotc_teams t on t.id=s.team_id and t.facility_id=s.facility_id where s.facility_id=fid and s.player_id=target.id and t.status='current')
    or exists(select 1 from public.hybrid_kotc_substitutes s join public.hybrid_kotc_teams t on t.id=s.team_id and t.facility_id=s.facility_id where s.facility_id=fid and s.player_id=target.id and t.status='current') then raise exception 'This player is already assigned to a current KOTC team.'; end if;
  insert into public.hybrid_kotc_substitutes(facility_id,team_id,player_id) values(fid,team.id,target.id);
  update public.team_substitute_requests set status='accepted',answered_at=now() where facility_id=fid and id=request.id;
  update public.team_substitute_requests set status='expired',answered_at=now() where facility_id=fid and target_id=target.id and status='pending' and id<>request.id;
  update public.hybrid_kotc_court_state set version=version+1,updated_at=now() where facility_id=fid and court_number=team.court_number and version=request.expected_version;
  return jsonb_build_object('message','You are now a temporary substitute.','court_number',team.court_number,'version',request.expected_version+1);
end $$;

create or replace function public.cancel_hybrid_kotc_substitute_request(p_request_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare fid uuid:=public.current_facility_id(); request public.team_substitute_requests;
begin
  select * into request from public.team_substitute_requests where facility_id=fid and id=p_request_id and hybrid_team_id is not null and status='pending' for update;
  if request.id is null then raise exception 'This substitute invitation is no longer available.'; end if;
  if request.requester_id is distinct from (select id from public.waitlist_players where facility_id=fid and user_id=public.current_request_user_id() order by updated_at desc limit 1) and not public.is_waitlist_operator() then raise exception 'Only the requester or an admin or host can cancel this invitation.'; end if;
  update public.team_substitute_requests set status='declined',answered_at=now() where facility_id=fid and id=request.id;
  return jsonb_build_object('message','Substitute invitation canceled.');
end $$;

create or replace function public.fill_hybrid_kotc_empty_slot(
  p_court_number integer,p_team_id uuid,p_facility_id uuid,p_expected_game_number integer,p_expected_version bigint
) returns jsonb language plpgsql security definer set search_path=public as $$
declare fid uuid:=public.current_facility_id(); cfg public.waitlist_config; state public.hybrid_kotc_court_state;
  team public.hybrid_kotc_teams; filler public.waitlist_players; target_slot public.hybrid_kotc_slots;
begin
  perform public.assert_expected_court_game(p_facility_id,p_court_number,p_expected_game_number);
  perform pg_advisory_xact_lock(hashtextextended(fid::text,7429302));
  select * into cfg from public.waitlist_config where facility_id=fid and id for update;
  select * into state from public.hybrid_kotc_court_state where facility_id=fid and court_number=p_court_number for update;
  select * into team from public.hybrid_kotc_teams where facility_id=fid and id=p_team_id and court_number=p_court_number and status='current' for update;
  select * into filler from public.waitlist_players where facility_id=fid and user_id=public.current_request_user_id() and status='waiting' for update;
  if cfg.mode<>'hybrid_waitlist' or cfg.hybrid_rotation_rule<>'kotc' or state.version is distinct from p_expected_version or team.id is null then raise exception 'This Waitlist KOTC appearance changed. Refresh and try again.'; end if;
  if filler.id is null then raise exception 'Only an eligible waiting player can fill this KOTC slot.'; end if;
  select * into target_slot from public.hybrid_kotc_slots where facility_id=fid and team_id=team.id and player_id is null order by slot_number for update limit 1;
  if target_slot.id is null then raise exception 'This KOTC team has no open slot.'; end if;
  update public.hybrid_kotc_slots set player_id=filler.id,is_substitute=true,original_group_id=null,original_unit_order=null,original_queue_position=filler.queue_position where id=target_slot.id and facility_id=fid and player_id is null;
  if not found then raise exception 'This KOTC slot changed. Refresh and try again.'; end if;
  insert into public.hybrid_kotc_substitutes(facility_id,team_id,player_id) values(fid,team.id,filler.id);
  update public.waitlist_players set status='current',court_number=p_court_number,updated_at=now() where facility_id=fid and id=filler.id and status='waiting';
  update public.hybrid_kotc_court_state set version=version+1,updated_at=now() where facility_id=fid and court_number=p_court_number and version=p_expected_version;
  return jsonb_build_object('message','You are filling the open KOTC slot.','team_id',team.id,'slot_number',target_slot.slot_number,'version',p_expected_version+1);
end $$;

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
  if state.version is distinct from p_expected_version or team.id is null or slot_row.id is null or replacement.id is null then raise exception 'This Waitlist KOTC appearance changed. Refresh and try again.'; end if;
  select coalesce(max(queue_position),0)+1 into queue_tail from public.waitlist_players where facility_id=fid;
  update public.waitlist_players set status='waiting',court_number=null,group_id=null,queue_position=queue_tail,updated_at=now() where facility_id=fid and id=outgoing.id;
  update public.waitlist_players set status='current',court_number=p_court_number,group_id=outgoing.group_id,updated_at=now() where facility_id=fid and id=replacement.id;
  update public.hybrid_kotc_slots set player_id=replacement.id,original_group_id=outgoing.group_id,original_unit_order=slot_row.original_unit_order,original_queue_position=slot_row.original_queue_position,is_substitute=false where facility_id=fid and id=slot_row.id;
  delete from public.hybrid_kotc_substitutes where facility_id=fid and player_id=replacement.id;
  update public.hybrid_kotc_court_state set version=version+1,updated_at=now() where facility_id=fid and court_number=p_court_number and version=p_expected_version;
  return jsonb_build_object('message','KOTC slot replacement completed.','version',p_expected_version+1);
end $$;

revoke all on function public.assert_hybrid_kotc_substitute_integrity() from public,anon,authenticated;
revoke all on function public.request_hybrid_kotc_substitute(integer,uuid,uuid,uuid,integer,bigint),
  public.answer_hybrid_kotc_substitute(uuid,boolean),public.cancel_hybrid_kotc_substitute_request(uuid),
  public.fill_hybrid_kotc_empty_slot(integer,uuid,uuid,integer,bigint),
  public.swap_hybrid_kotc_slot(integer,uuid,smallint,uuid,uuid,integer,bigint) from public,anon;
grant execute on function public.assert_hybrid_kotc_substitute_integrity() to opengym_runtime;
grant execute on function public.request_hybrid_kotc_substitute(integer,uuid,uuid,uuid,integer,bigint),
  public.answer_hybrid_kotc_substitute(uuid,boolean),public.cancel_hybrid_kotc_substitute_request(uuid),
  public.fill_hybrid_kotc_empty_slot(integer,uuid,uuid,integer,bigint),
  public.swap_hybrid_kotc_slot(integer,uuid,smallint,uuid,uuid,integer,bigint) to authenticated;
notify pgrst,'reload schema';
