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

-- Rejoin timeouts ultimately call leave_waitlist.  Keep that mutation and the
-- operator-managed (no-phone) rejoin path inside the operator's facility too.
-- These functions predate facilities and otherwise select the first row for a
-- user/request across every gym.
create or replace function public.leave_waitlist()
returns jsonb language plpgsql security definer set search_path=public as $$
declare player public.waitlist_players; fid uuid:=public.current_facility_id();
begin
  perform pg_advisory_xact_lock(7429101);
  select * into player from public.waitlist_players
    where facility_id=fid and user_id=auth.uid() for update;
  if player.id is null or player.status='left' then
    return jsonb_build_object('message','You are not currently in this facility waitlist.');
  end if;
  update public.waitlist_players
    set status='left',queue_position=null,rejoin_expires_at=null,updated_at=now()
    where id=player.id and facility_id=fid;
  if player.status='current' then
    update public.waitlist_players set status='current',updated_at=now()
      where facility_id=fid and id=(
        select id from public.waitlist_players
          where facility_id=fid and status='waiting'
          order by queue_position limit 1
      );
  end if;
  return jsonb_build_object('message','You left the waitlist.');
end; $$;

create or replace function public.admin_list_offline_rejoins()
returns table(id uuid,display_name text,queue_position bigint,expires_at timestamptz)
language plpgsql security definer set search_path=public as $$
declare fid uuid:=public.current_facility_id();
begin
  if not public.is_waitlist_operator() then raise exception 'Admin or host access required.'; end if;
  update public.waitlist_players set status='left',queue_position=null,rejoin_expires_at=null,updated_at=now()
    where facility_id=fid and user_id is null and status='rejoin' and rejoin_expires_at<=now();
  return query select p.id,p.display_name,p.queue_position,p.rejoin_expires_at
    from public.waitlist_players p
    where p.facility_id=fid and p.user_id is null and p.status='rejoin'
    order by p.queue_position;
end; $$;

create or replace function public.admin_answer_offline_rejoin(p_player_id uuid,p_stay boolean)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  player public.waitlist_players; active_count integer; max_players integer;
  new_status text; fid uuid:=public.current_facility_id();
begin
  if not public.is_waitlist_operator() then raise exception 'Admin or host access required.'; end if;
  select * into player from public.waitlist_players
    where id=p_player_id and facility_id=fid and user_id is null and status='rejoin' for update;
  if player.id is null then raise exception 'This rejoin request is no longer available.'; end if;
  if player.rejoin_expires_at<=now() then
    update public.waitlist_players set status='left',queue_position=null,rejoin_expires_at=null,updated_at=now()
      where id=player.id and facility_id=fid;
    raise exception 'The 15-minute rejoin window has expired.';
  end if;
  perform public.save_admin_undo(case when p_stay then 'rejoin player' else 'remove rejoin player' end);
  select count(*) into active_count from public.waitlist_players
    where facility_id=fid and status in('current','waiting','sitout');
  select c.max_players into max_players from public.waitlist_config c
    where c.facility_id=fid and c.id;
  if max_players is null then raise exception 'Facility configuration not found.'; end if;
  new_status:=case when active_count<max_players then 'current' else 'waiting' end;
  update public.waitlist_players
    set status=case when p_stay then new_status else 'left' end,
      queue_position=case when p_stay then player.queue_position else null end,
      rejoin_expires_at=null,updated_at=now()
    where id=player.id and facility_id=fid;
  if p_stay then
    perform public.log_waitlist_operator_action('admin_rejoin','returned '||player.display_name||case when new_status='current' then ' directly to the current game.' else ' to their saved queue position.' end);
  end if;
  return jsonb_build_object('message',case when p_stay and new_status='current' then player.display_name||' rejoined the current game.' when p_stay then player.display_name||' rejoined at their saved position.' else player.display_name||' was removed.' end);
end; $$;

grant execute on function public.leave_waitlist() to authenticated;
grant execute on function public.admin_list_offline_rejoins() to authenticated;
grant execute on function public.admin_answer_offline_rejoin(uuid,boolean) to authenticated;
