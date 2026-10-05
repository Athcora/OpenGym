-- Hybrid KOTC has no legacy king_teams row to restore into. A returning
-- original player must retain queue priority for the next authoritative KOTC
-- formation, rather than being marked current without a hybrid slot.
create or replace function public.answer_rejoin_prompt(p_response_id uuid,p_choice text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare prompt public.rejoin_responses; player public.waitlist_players; team public.king_teams;
  config public.waitlist_config; open_slots integer; joined_current boolean; fid uuid:=public.current_facility_id();
begin
  perform pg_advisory_xact_lock(7429101);
  if p_choice not in('stay','leave') then raise exception 'Choose rejoin or leave.'; end if;
  select * into prompt from public.rejoin_responses where id=p_response_id and user_id=auth.uid() and facility_id=fid for update;
  select * into player from public.waitlist_players where facility_id=fid and user_id=auth.uid() for update;
  if prompt.id is null or player.id is null then raise exception 'Rejoin request not found for this facility.'; end if;
  if prompt.choice is not null then raise exception 'This rejoin request was already answered.'; end if;
  if prompt.expires_at<=now() then p_choice:='leave'; end if;
  update public.rejoin_responses set choice=p_choice,answered_at=now() where id=prompt.id and facility_id=fid;
  if p_choice='leave' then
    update public.waitlist_players set status='left',queue_position=null,team_id=null,court_number=null,rejoin_expires_at=null,updated_at=now() where id=player.id and facility_id=fid;
    perform public.cleanup_king_rejoin_expirations();
    return jsonb_build_object('message','You left the waitlist.');
  end if;
  select * into config from public.waitlist_config where facility_id=fid and id for update;
  if config.id is null then raise exception 'Facility configuration not found.'; end if;
  if config.mode='hybrid_waitlist' and config.hybrid_rotation_rule='kotc' then
    update public.waitlist_players set status='waiting',court_number=null,team_id=null,
      queue_position=prompt.original_position,rejoin_expires_at=null,updated_at=now()
      where id=player.id and facility_id=fid;
    return jsonb_build_object('message','You kept your saved position for the next Waitlist KOTC game.');
  end if;
  if player.team_id is not null then select * into team from public.king_teams where id=player.team_id and facility_id=fid for update; end if;
  if team.id is not null then
    update public.king_teams set rejoin_expires_at=null,updated_at=now() where id=team.id and facility_id=fid;
    update public.waitlist_players set status=team.status,court_number=team.court_number,rejoin_expires_at=null,updated_at=now() where id=player.id and facility_id=fid;
    perform public.king_fill_courts();
    select * into team from public.king_teams where id=player.team_id and facility_id=fid;
    update public.waitlist_players set status=team.status,court_number=team.court_number,updated_at=now() where id=player.id and facility_id=fid;
    return jsonb_build_object('message','You rejoined your team in its saved position.');
  end if;
  update public.waitlist_players set status='waiting',queue_position=prompt.original_position,rejoin_expires_at=null,updated_at=now() where id=player.id and facility_id=fid;
  select greatest(config.max_players-count(*),0) into open_slots from public.waitlist_players where facility_id=fid and status='current';
  with chosen as(select id from public.waitlist_players where facility_id=fid and status='waiting' order by queue_position,id limit open_slots)
    update public.waitlist_players set status='current',updated_at=now() where facility_id=fid and id in(select id from chosen);
  select exists(select 1 from public.waitlist_players where id=player.id and facility_id=fid and status='current') into joined_current;
  return jsonb_build_object('message',case when joined_current then 'You rejoined the current game.' else 'You kept your saved position in line.' end);
end;
$$;

revoke all on function public.answer_rejoin_prompt(uuid,text) from public,anon;
grant execute on function public.answer_rejoin_prompt(uuid,text) to authenticated,opengym_runtime;
notify pgrst,'reload schema';
