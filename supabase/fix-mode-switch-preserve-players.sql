-- Preserve the live participant set when switching between individual and
-- team waitlists. The old implementation restored the stale snapshot from
-- when Teams Mode was first opened, deleting anyone who joined afterward.

create or replace function public.set_open_gym_mode(p_mode text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare current_mode text;
begin
  if not exists(select 1 from public.admin_sessions where user_id=auth.uid()) then
    raise exception 'Admin access required.';
  end if;
  if p_mode not in('regular','rejoin','teams','teams_rejoin') then
    raise exception 'Unknown waitlist mode.';
  end if;

  perform pg_advisory_xact_lock(7429201);
  select mode into current_mode from public.waitlist_config where id for update;
  if current_mode=p_mode then return jsonb_build_object('message','Mode unchanged.'); end if;
  perform public.save_admin_undo('change waitlist mode');

  if p_mode in('teams','teams_rejoin') and current_mode in('teams','teams_rejoin') then
    update public.waitlist_config set mode=p_mode,updated_at=now() where id;
    update public.waitlist_courts set team_mode='king' where team_mode='king_rejoin';

  elsif p_mode in('teams','teams_rejoin') then
    update public.waitlist_config set mode=p_mode,updated_at=now() where id;
    update public.waitlist_courts set team_mode='king' where team_mode='king_rejoin';
    delete from public.rejoin_responses where choice is null;
    update public.waitlist_players set rejoin_expires_at=null,
      status=case when status='rejoin' then 'waiting' else status end,
      updated_at=now() where status<>'left';
    perform public.initialize_king_mode();

  elsif current_mode in('teams','teams_rejoin') then
    -- Flatten the current courts first, followed by the shared team queue.
    -- Players retain their order inside each team; no live participant is
    -- restored from or removed by a historical mode snapshot.
    with ordered as(
      select p.id,row_number() over(order by
        case when t.status='current' then 0 when t.status='waiting' then 1 else 2 end,
        case when t.status='current' then t.court_number end nulls last,
        case when t.status='current' then t.court_side end nulls last,
        case when t.status='waiting' then t.queue_position end nulls last,
        p.queue_position nulls last,p.created_at,p.id
      ) as new_position
      from public.waitlist_players p
      left join public.king_teams t on t.id=p.team_id
      where p.status<>'left'
    )
    update public.waitlist_players p set
      status=case when p.status='sitout' then 'sitout' else 'waiting' end,
      queue_position=ordered.new_position,court_number=null,team_id=null,
      rejoin_expires_at=null,updated_at=now()
    from ordered where p.id=ordered.id;

    delete from public.rejoin_responses where choice is null;
    delete from public.team_fill_ins where true;
    delete from public.team_substitute_requests where true;
    delete from public.team_substitutes where true;
    delete from public.king_teams where true;
    delete from public.king_mode_state where true;
    update public.waitlist_config set mode=p_mode,updated_at=now() where id;
    perform public.fill_open_court_slots();

  else
    update public.waitlist_config set mode=p_mode,updated_at=now() where id;
  end if;

  perform public.log_waitlist_operator_action('mode_change','changed the waitlist mode to '||p_mode||'.');
  return jsonb_build_object('message','Waitlist mode changed to '||p_mode||'.');
end; $$;

grant execute on function public.set_open_gym_mode(text) to authenticated;
