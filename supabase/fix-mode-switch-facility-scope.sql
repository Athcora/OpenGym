-- A facility administrator may change only the mode and team layout of the
-- facility selected in user_facility_sessions.  These helpers execute as the
-- runtime role, so RLS alone cannot provide that boundary.

create or replace function public.initialize_king_mode()
returns void language plpgsql security definer set search_path=public as $$
declare
  player_row record; created_team uuid; player_no integer:=0; team_no integer:=0;
  fid uuid:=public.current_facility_id();
begin
  if fid is null then raise exception 'Select a facility first.'; end if;
  if not exists(select 1 from public.waitlist_config where facility_id=fid and id and mode in('teams','teams_rejoin')) then return; end if;
  delete from public.king_teams t where t.facility_id=fid and not exists(
    select 1 from public.waitlist_players member
    where member.facility_id=fid and member.team_id=t.id and member.status<>'left'
  );
  for player_row in
    select * from public.waitlist_players
    where facility_id=fid and status<>'left' and team_id is null
    order by case when status='current' then 0 else 1 end,
      court_number nulls last,queue_position nulls last,created_at,id
  loop
    player_no:=player_no+1;
    if (player_no-1)%6=0 then
      team_no:=team_no+1;
      insert into public.king_teams(facility_id,name,queue_position)
        values(fid,'Team '||team_no,team_no) returning id into created_team;
    end if;
    update public.waitlist_players set team_id=created_team,status='waiting',court_number=null,
      queue_position=((player_no-1)%6)+1,updated_at=now()
      where facility_id=fid and id=player_row.id;
  end loop;
  perform public.king_fill_courts();
end;
$$;

create or replace function public.set_open_gym_mode(p_mode text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare current_mode text; fid uuid:=public.current_facility_id();
begin
  if fid is null then raise exception 'Select a facility first.'; end if;
  if not public.is_waitlist_admin() then raise exception 'Admin access required.'; end if;
  if p_mode not in('regular','rejoin','teams','teams_rejoin') then raise exception 'Unknown waitlist mode.'; end if;
  perform pg_advisory_xact_lock(7429201);
  select mode into current_mode from public.waitlist_config where facility_id=fid and id for update;
  if current_mode is null then raise exception 'Facility configuration not found.'; end if;
  if current_mode=p_mode then return jsonb_build_object('message','Mode unchanged.'); end if;
  perform public.save_admin_undo('change waitlist mode');
  if p_mode in('teams','teams_rejoin') and current_mode in('teams','teams_rejoin') then
    update public.waitlist_config set mode=p_mode,updated_at=now() where facility_id=fid and id;
    update public.waitlist_courts set team_mode='king' where facility_id=fid and team_mode='king_rejoin';
  elsif p_mode in('teams','teams_rejoin') then
    update public.waitlist_config set mode=p_mode,updated_at=now() where facility_id=fid and id;
    update public.waitlist_courts set team_mode='king' where facility_id=fid and team_mode='king_rejoin';
    delete from public.rejoin_responses where facility_id=fid and choice is null;
    update public.waitlist_players set rejoin_expires_at=null,
      status=case when status='rejoin' then 'waiting' else status end,updated_at=now()
      where facility_id=fid and status<>'left';
    perform public.initialize_king_mode();
  elsif current_mode in('teams','teams_rejoin') then
    with ordered as(
      select p.id,row_number() over(order by
        case when t.status='current' then 0 when t.status='waiting' then 1 else 2 end,
        case when t.status='current' then t.court_number end nulls last,
        case when t.status='current' then t.court_side end nulls last,
        case when t.status='waiting' then t.queue_position end nulls last,
        p.queue_position nulls last,p.created_at,p.id) as new_position
      from public.waitlist_players p left join public.king_teams t
        on t.facility_id=fid and t.id=p.team_id
      where p.facility_id=fid and p.status<>'left'
    ) update public.waitlist_players p set
      status=case when p.status='sitout' then 'sitout' else 'waiting' end,
      queue_position=ordered.new_position,court_number=null,team_id=null,
      rejoin_expires_at=null,updated_at=now()
      from ordered where p.facility_id=fid and p.id=ordered.id;
    delete from public.rejoin_responses where facility_id=fid and choice is null;
    delete from public.team_fill_ins where facility_id=fid;
    delete from public.team_substitute_requests where facility_id=fid;
    delete from public.team_substitutes where facility_id=fid;
    delete from public.king_teams where facility_id=fid;
    delete from public.king_mode_state where facility_id=fid;
    update public.waitlist_config set mode=p_mode,updated_at=now() where facility_id=fid and id;
    perform public.fill_open_court_slots();
  else
    update public.waitlist_config set mode=p_mode,updated_at=now() where facility_id=fid and id;
  end if;
  perform public.log_waitlist_operator_action('mode_change','changed the waitlist mode to '||p_mode||'.');
  return jsonb_build_object('message','Waitlist mode changed to '||p_mode||'.');
end;
$$;

notify pgrst, 'reload schema';
