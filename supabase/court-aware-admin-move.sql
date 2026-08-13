drop function if exists public.admin_move_player(uuid,text,integer);
drop function if exists public.admin_move_player(uuid,text,integer,integer);

create or replace function public.admin_move_player(
  p_player_id uuid,
  p_status text,
  p_index integer,
  p_court_number integer
)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  player public.waitlist_players;
  source_court integer;
  destination_court integer;
  moving_count integer;
  v_max_players integer;
  target_position bigint;
  open_spots integer;
  candidate record;
begin
  if not public.is_waitlist_operator() then raise exception 'Admin or host access required.'; end if;
  if p_status not in ('current','waiting') then raise exception 'Invalid destination.'; end if;
  perform pg_advisory_xact_lock(7429101);

  select * into player from public.waitlist_players where id=p_player_id for update;
  if player.id is null then raise exception 'Player not found.'; end if;
  source_court:=player.court_number;
  destination_court:=case when p_status='current' then coalesce(p_court_number,source_court,1) else null end;
  select cfg.max_players into v_max_players from public.waitlist_config cfg where cfg.id = true;
  select count(*) into moving_count from public.waitlist_players
    where id=player.id or (player.group_id is not null and group_id=player.group_id);
  if moving_count>v_max_players then raise exception 'This group is larger than a court.'; end if;
  perform public.save_admin_undo('move player');

  -- Open large gaps without changing the relative order of any court or queue.
  update public.waitlist_players set queue_position=queue_position*1000
    where status in ('current','waiting','sitout') and queue_position is not null;

  if p_status='waiting' then
    select queue_position into target_position from public.waitlist_players
      where status in ('waiting','sitout') and id<>player.id
        and (player.group_id is null or group_id is distinct from player.group_id)
      order by queue_position offset greatest(p_index,0) limit 1;
    if target_position is null then
      select coalesce(max(queue_position),0)+1000 into target_position from public.waitlist_players
        where status in ('current','waiting','sitout');
    end if;
    with moving as (
      select id,row_number() over(order by queue_position,id) rn from public.waitlist_players
      where id=player.id or (player.group_id is not null and group_id=player.group_id)
    )
    update public.waitlist_players p set status='waiting',court_number=null,
      queue_position=target_position-moving_count+moving.rn,updated_at=now()
      from moving where p.id=moving.id;
  else
    select queue_position into target_position from public.waitlist_players
      where status='current' and court_number=destination_court and id<>player.id
        and (player.group_id is null or group_id is distinct from player.group_id)
      order by queue_position offset greatest(p_index,0) limit 1;
    if target_position is null then
      select coalesce(max(queue_position),0)+1000 into target_position from public.waitlist_players
        where status='current' and court_number=destination_court;
    end if;
    with moving as (
      select id,row_number() over(order by queue_position,id) rn from public.waitlist_players
      where id=player.id or (player.group_id is not null and group_id=player.group_id)
    )
    update public.waitlist_players p set status='current',court_number=destination_court,
      sitout_priority=false,queue_position=target_position-moving_count+moving.rn,updated_at=now()
      from moving where p.id=moving.id;

    -- Only the players displaced beyond this court's 12 spots move to the
    -- front of the shared waitlist. Other courts are never touched.
    with ranked as (
      select id,row_number() over(order by queue_position,id) rn from public.waitlist_players
      where status='current' and court_number=destination_court
    ), displaced as (
      select p.id,row_number() over(order by p.queue_position,p.id) rn
      from public.waitlist_players p join ranked r on r.id=p.id where r.rn>v_max_players
    ), queue_head as (
      select coalesce(min(queue_position),1000000) head from public.waitlist_players
      where status in ('waiting','sitout')
    )
    update public.waitlist_players p set status='waiting',court_number=null,
      queue_position=queue_head.head-moving_count+displaced.rn,updated_at=now()
      from displaced cross join queue_head where p.id=displaced.id;
  end if;

  -- Refill only a court that the move actually vacated.
  if source_court is not null and source_court is distinct from destination_court then
    select greatest(v_max_players-count(p.id),0) into open_spots
      from public.waitlist_config cfg left join public.waitlist_players p
        on p.status='current' and p.court_number=source_court where cfg.id = true group by cfg.max_players;
    for candidate in
      select coalesce(group_id,id) block_id,count(*)::integer block_size,min(queue_position) first_position
      from public.waitlist_players where status='waiting'
      group by coalesce(group_id,id) order by min(queue_position)
    loop
      if candidate.block_size<=open_spots then
        update public.waitlist_players set status='current',court_number=source_court,
          sitout_priority=false,updated_at=now() where status='waiting' and coalesce(group_id,id)=candidate.block_id;
        open_spots:=open_spots-candidate.block_size;
      end if;
      exit when open_spots=0;
    end loop;
  end if;

  with ranked as (
    select id,row_number() over(order by case when status='current' then 0 else 1 end,
      coalesce(court_number,999),queue_position,id) rn from public.waitlist_players
    where status in ('current','waiting','sitout') and queue_position is not null
  )
  update public.waitlist_players p set queue_position=ranked.rn from ranked where p.id=ranked.id;
  return jsonb_build_object('message','Player moved.','source_court',source_court,'destination_court',destination_court);
end; $$;

grant execute on function public.admin_move_player(uuid,text,integer,integer) to authenticated;
