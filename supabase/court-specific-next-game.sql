-- Advance and refill only the court whose Next Game button was pressed.
create or replace function public.fill_one_court_slots(p_court_number integer)
returns void language plpgsql security definer set search_path=public as $$
declare cfg public.waitlist_config; open_spots integer; block record;
begin
  select * into cfg from public.waitlist_config where id;
  select greatest(cfg.max_players-count(p.id),0) into open_spots
  from public.waitlist_players p
  where p.status='current' and p.court_number=p_court_number;

  for block in
    select coalesce(group_id,id) block_id,count(*)::integer block_size
    from public.waitlist_players
    where status='waiting'
    group by coalesce(group_id,id)
    order by bool_or(sitout_priority) desc,min(queue_position),coalesce(group_id,id)
  loop
    exit when open_spots<=0;
    if block.block_size<=open_spots then
      update public.waitlist_players
      set status='current',court_number=p_court_number,sitout_priority=false,updated_at=now()
      where status='waiting' and coalesce(group_id,id)=block.block_id;
      open_spots:=open_spots-block.block_size;
    end if;
  end loop;

  with ranked as(
    select id,row_number()over(order by case when status='current' then 0 else 1 end,
      coalesce(court_number,999),queue_position,id) rn
    from public.waitlist_players
    where status in('current','waiting') and queue_position is not null)
  update public.waitlist_players p set queue_position=ranked.rn
  from ranked where p.id=ranked.id;
end; $$;

create or replace function public.end_court_game(p_court_number integer)
returns jsonb language plpgsql security definer set search_path=public as $$
declare caller public.waitlist_players; cfg public.waitlist_config; court public.waitlist_courts;
declare next_game integer; actor text; response_rows jsonb:='[]'::jsonb; last_position bigint;
begin
  perform pg_advisory_xact_lock(7429101);
  select * into cfg from public.waitlist_config where id for update;
  select * into court from public.waitlist_courts where court_number=p_court_number for update;
  if court.court_number is null then raise exception 'That court is not active.'; end if;
  select * into caller from public.waitlist_players where user_id=auth.uid();
  if not public.is_waitlist_operator() and(caller.id is null or caller.status<>'current' or caller.court_number<>p_court_number or caller.restricted) then
    raise exception 'Only an unrestricted player on this court or an admin/host can start its next game.';
  end if;
  perform public.save_admin_undo('start next game');
  insert into public.past_games(game_number,player_names,court_number)
    select court.game_number,coalesce(jsonb_agg(display_name order by queue_position),'[]'::jsonb),p_court_number
    from public.waitlist_players where status='current' and court_number=p_court_number
    on conflict(game_number) do nothing;
  select coalesce(max(queue_position),0) into last_position from public.waitlist_players
    where status in('current','waiting','sitout','rejoin');
  with finished as(select id,row_number()over(order by queue_position,id) rn from public.waitlist_players
    where status='current' and court_number=p_court_number)
  update public.waitlist_players p set queue_position=last_position+finished.rn,court_number=null,updated_at=now()
    from finished where p.id=finished.id;
  if cfg.mode='rejoin' then
    update public.waitlist_players set status='rejoin',rejoin_expires_at=now()+case when user_id is null then interval '15 minutes' else interval '5 minutes' end
      where status='current' and court_number is null and queue_position>last_position;
    with changed as(select * from public.waitlist_players where status='rejoin' and queue_position>last_position and user_id is not null), ins as(
      insert into public.rejoin_responses(user_id,game_number,original_position,expires_at)
      select user_id,court.game_number+1,queue_position,rejoin_expires_at from changed returning id,user_id)
    select coalesce(jsonb_agg(jsonb_build_object('user_id',user_id,'response_id',id)),'[]'::jsonb) into response_rows from ins;
  else
    update public.waitlist_players set status='waiting' where status='current' and court_number is null and queue_position>last_position;
  end if;
  next_game:=greatest(
    (select coalesce(max(game_number),0) from public.waitlist_courts),
    (select coalesce(max(game_number),0) from public.past_games)
  )+1;
  update public.waitlist_courts set game_number=next_game,started_at=now() where court_number=p_court_number;
  update public.waitlist_config set game_number=next_game,updated_at=now() where id;
  perform public.fill_one_court_slots(p_court_number);
  actor:=coalesce(caller.display_name,'Admin');
  insert into public.waitlist_events(actor_user_id,actor_name,event_type,message)
    values(auth.uid(),actor,'next_game',actor||' started Game '||next_game||' on Court '||p_court_number||'.');
  return jsonb_build_object('message','Game '||next_game||' started on Court '||p_court_number||'.','game_number',next_game,'court_number',p_court_number,'rejoin_prompts',response_rows);
end; $$;

grant execute on function public.fill_one_court_slots(integer) to authenticated;
grant execute on function public.end_court_game(integer) to authenticated;
