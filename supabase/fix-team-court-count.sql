-- Keep Teams-mode court removal team-aware. Removed courts' teams return to
-- the front of the shared team waitlist instead of remaining orphaned on a
-- court row that no longer exists.

create or replace function public.admin_set_court_count(p_court_count integer)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  cfg public.waitlist_config; old_count integer; court record; team_row record;
  next_game integer; existing_count integer; moved_team_count integer:=0;
  priority_offset integer:=0;
begin
  if not public.is_waitlist_operator() then raise exception 'Admin or host access required.'; end if;
  if p_court_count<1 or p_court_count>12 then raise exception 'Choose between 1 and 12 courts.'; end if;
  perform pg_advisory_xact_lock(7429101);
  select * into cfg from public.waitlist_config where id for update;
  select count(*) into existing_count from public.waitlist_courts;
  old_count:=existing_count;
  if old_count=p_court_count and not exists(
    select 1 from generate_series(1,p_court_count) expected(court_number)
    left join public.waitlist_courts actual using(court_number)
    where actual.court_number is null
  ) then
    update public.waitlist_config set court_count=p_court_count,updated_at=now() where id;
    return jsonb_build_object('message',p_court_count||' court(s) are active.');
  end if;

  perform public.save_admin_undo('change number of courts');

  if p_court_count<old_count and cfg.mode in('teams','teams_rejoin') then
    select count(*) into moved_team_count
    from public.king_teams t where t.status='current' and t.court_number in(
      select c.court_number from public.waitlist_courts c
      order by c.started_at desc,c.game_number desc limit(old_count-p_court_count)
    );
    update public.king_teams set queue_position=queue_position+moved_team_count
      where status='waiting';
    for court in
      select * from public.waitlist_courts
      order by started_at desc,game_number desc limit(old_count-p_court_count)
    loop
      for team_row in
        select * from public.king_teams
        where status='current' and court_number=court.court_number
        order by court_side,created_at,id
      loop
        priority_offset:=priority_offset+1;
        update public.king_teams set status='waiting',queue_position=priority_offset,
          court_number=null,court_side=null,consecutive_wins=0,updated_at=now()
          where id=team_row.id;
        update public.waitlist_players set
          status=case when status='current' then 'waiting' else status end,
          court_number=null,updated_at=now() where team_id=team_row.id and status<>'left';
      end loop;
      delete from public.waitlist_courts where court_number=court.court_number;
    end loop;
    perform public.king_compact_queue();
  elsif p_court_count<old_count then
    for court in select * from public.waitlist_courts order by started_at desc,game_number desc limit(old_count-p_court_count) loop
      update public.waitlist_players set queue_position=queue_position*1000 where status in('waiting','sitout');
      with moved as(select id,row_number()over(order by queue_position,id) rn
        from public.waitlist_players where status='current' and court_number=court.court_number)
      update public.waitlist_players p set status='waiting',court_number=null,queue_position=moved.rn,
        updated_at=now() from moved where p.id=moved.id;
      delete from public.waitlist_courts where court_number=court.court_number;
    end loop;
    with ranked as(select id,row_number()over(order by queue_position,id) rn from public.waitlist_players
      where status in('current','waiting','sitout') and queue_position is not null)
    update public.waitlist_players p set queue_position=ranked.rn from ranked where p.id=ranked.id;
  else
    next_game:=greatest(
      (select coalesce(max(game_number),0) from public.waitlist_courts),
      (select coalesce(max(game_number),0) from public.past_games)
    );
    for court in select expected.court_number
      from generate_series(1,p_court_count) expected(court_number)
      left join public.waitlist_courts actual using(court_number)
      where actual.court_number is null order by expected.court_number
    loop
      next_game:=next_game+1;
      insert into public.waitlist_courts(court_number,game_number,started_at)
      values(court.court_number,next_game,now())
      on conflict(court_number) do update set game_number=excluded.game_number,started_at=excluded.started_at;
    end loop;
    update public.waitlist_config set game_number=next_game where id;
  end if;

  update public.waitlist_config set court_count=p_court_count,updated_at=now() where id;
  if cfg.mode in('teams','teams_rejoin') then
    perform public.king_fill_courts();
  else
    perform public.fill_open_court_slots();
  end if;
  perform public.log_waitlist_operator_action('court_count','changed the number of courts to '||p_court_count||'.');
  return jsonb_build_object('message',p_court_count||' court(s) are now active.');
end;
$$;
