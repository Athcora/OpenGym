-- Preserve the Stage 6 operator replacement inside the established Admin
-- history boundary and keep it dormant for hybrid two_on_two_off.  This is a
-- follow-up migration because the initial lifecycle migration was already
-- applied to the local validation database.
create or replace function public.swap_hybrid_kotc_slot(
  p_court_number integer,p_team_id uuid,p_slot_number smallint,p_replacement_id uuid,p_facility_id uuid,p_expected_game_number integer,p_expected_version bigint
) returns jsonb language plpgsql security definer set search_path=public as $$
declare fid uuid:=public.current_facility_id(); cfg public.waitlist_config; state public.hybrid_kotc_court_state; team public.hybrid_kotc_teams;
  slot_row public.hybrid_kotc_slots; outgoing public.waitlist_players; replacement public.waitlist_players; queue_tail bigint;
begin
  if not public.is_waitlist_operator() then raise exception 'Admin or host access required.'; end if;
  perform public.assert_expected_court_game(p_facility_id,p_court_number,p_expected_game_number);
  perform pg_advisory_xact_lock(hashtextextended(fid::text,7429302));
  select * into cfg from public.waitlist_config where facility_id=fid and id for update;
  select * into state from public.hybrid_kotc_court_state where facility_id=fid and court_number=p_court_number for update;
  select * into team from public.hybrid_kotc_teams where facility_id=fid and id=p_team_id and court_number=p_court_number and status='current' for update;
  select * into slot_row from public.hybrid_kotc_slots where facility_id=fid and team_id=p_team_id and slot_number=p_slot_number and player_id is not null and not is_substitute for update;
  select * into outgoing from public.waitlist_players where facility_id=fid and id=slot_row.player_id for update;
  select * into replacement from public.waitlist_players where facility_id=fid and id=p_replacement_id and status='waiting' for update;
  if cfg.mode<>'hybrid_waitlist' or cfg.hybrid_rotation_rule<>'kotc' or state.version is distinct from p_expected_version or team.id is null or slot_row.id is null or replacement.id is null then raise exception 'This Waitlist KOTC appearance changed. Refresh and try again.'; end if;
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
