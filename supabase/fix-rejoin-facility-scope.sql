-- Keep every player rejoin decision inside the facility that issued its prompt.
-- The earlier implementation located a player/config/queue by user or status alone,
-- which is unsafe now that one account can have historical rows in multiple gyms.

create or replace function public.answer_rejoin_prompt(p_response_id uuid,p_choice text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  prompt public.rejoin_responses;
  player public.waitlist_players;
  team public.king_teams;
  config public.waitlist_config;
  open_slots integer;
  joined_current boolean;
  fid uuid:=public.current_facility_id();
begin
  perform pg_advisory_xact_lock(7429101);
  if p_choice not in('stay','leave') then raise exception 'Choose rejoin or leave.'; end if;

  select * into prompt from public.rejoin_responses
    where id=p_response_id and user_id=auth.uid() and facility_id=fid
    for update;
  select * into player from public.waitlist_players
    where facility_id=fid and user_id=auth.uid()
    for update;
  if prompt.id is null or player.id is null then raise exception 'Rejoin request not found for this facility.'; end if;
  if prompt.choice is not null then raise exception 'This rejoin request was already answered.'; end if;
  if prompt.expires_at<=now() then p_choice:='leave'; end if;

  update public.rejoin_responses set choice=p_choice,answered_at=now()
    where id=prompt.id and facility_id=fid;
  if p_choice='leave' then
    update public.waitlist_players
      set status='left',queue_position=null,team_id=null,court_number=null,rejoin_expires_at=null,updated_at=now()
      where id=player.id and facility_id=fid;
    perform public.cleanup_king_rejoin_expirations();
    return jsonb_build_object('message','You left the waitlist.');
  end if;

  if player.team_id is not null then
    select * into team from public.king_teams where id=player.team_id and facility_id=fid for update;
  end if;
  if team.id is not null then
    update public.king_teams set rejoin_expires_at=null,updated_at=now() where id=team.id and facility_id=fid;
    update public.waitlist_players set status=team.status,court_number=team.court_number,rejoin_expires_at=null,updated_at=now()
      where id=player.id and facility_id=fid;
    perform public.king_fill_courts();
    select * into team from public.king_teams where id=player.team_id and facility_id=fid;
    update public.waitlist_players set status=team.status,court_number=team.court_number,updated_at=now()
      where id=player.id and facility_id=fid;
    return jsonb_build_object('message','You rejoined your team in its saved position.');
  end if;

  update public.waitlist_players set status='waiting',queue_position=prompt.original_position,rejoin_expires_at=null,updated_at=now()
    where id=player.id and facility_id=fid;
  select * into config from public.waitlist_config where facility_id=fid and id for update;
  if config.id is null then raise exception 'Facility configuration not found.'; end if;
  select greatest(config.max_players-count(*),0) into open_slots
    from public.waitlist_players where facility_id=fid and status='current';
  with chosen as(
    select id from public.waitlist_players
      where facility_id=fid and status='waiting'
      order by queue_position,id limit open_slots
  ) update public.waitlist_players set status='current',updated_at=now()
    where facility_id=fid and id in(select id from chosen);
  select exists(select 1 from public.waitlist_players where id=player.id and facility_id=fid and status='current') into joined_current;
  return jsonb_build_object('message',case when joined_current then 'You rejoined the current game.' else 'You kept your saved position in line.' end);
end; $$;

create or replace function public.cleanup_king_rejoin_expirations()
returns jsonb language plpgsql security definer set search_path=public as $$
declare fid uuid:=public.current_facility_id();
begin
  if fid is null then return jsonb_build_object('message','No facility selected.'); end if;
  update public.rejoin_responses set choice='leave',answered_at=now()
    where facility_id=fid and choice is null and expires_at<=now();
  update public.waitlist_players
    set status='left',queue_position=null,team_id=null,court_number=null,rejoin_expires_at=null,updated_at=now()
    where facility_id=fid and status='rejoin' and rejoin_expires_at<=now();
  update public.king_teams t set rejoin_expires_at=null,updated_at=now()
    where t.facility_id=fid and t.rejoin_expires_at is not null and exists(
      select 1 from public.waitlist_players p
        where p.facility_id=fid and p.team_id=t.id and p.status in('waiting','current','sitout'));
  delete from public.king_teams t
    where t.facility_id=fid and t.rejoin_expires_at<=now()
      and not exists(select 1 from public.waitlist_players p where p.facility_id=fid and p.team_id=t.id and p.status in('waiting','current','sitout'));
  perform public.king_compact_queue();
  perform public.king_fill_courts();
  return jsonb_build_object('message','Expired team rejoin reservations cleared.');
end; $$;

grant execute on function public.answer_rejoin_prompt(uuid,text) to authenticated;
grant execute on function public.cleanup_king_rejoin_expirations() to authenticated;
