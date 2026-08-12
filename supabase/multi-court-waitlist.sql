-- Multi-court support: one shared queue, up to 12 live courts, and globally numbered games.
alter table public.waitlist_config add column if not exists court_count integer not null default 1 check(court_count between 1 and 12);
alter table public.waitlist_players add column if not exists court_number integer;
alter table public.past_games add column if not exists court_number integer not null default 1;

create table if not exists public.waitlist_courts(
  court_number integer primary key check(court_number between 1 and 12),
  game_number integer not null,
  started_at timestamptz not null default now()
);
alter table public.waitlist_courts enable row level security;
drop policy if exists "everyone reads waitlist courts" on public.waitlist_courts;
create policy "everyone reads waitlist courts" on public.waitlist_courts for select to authenticated using(true);

insert into public.waitlist_courts(court_number,game_number)
select 1,game_number from public.waitlist_config where id
on conflict(court_number) do nothing;
update public.waitlist_players set court_number=1 where status='current' and court_number is null;

create or replace function public.fill_open_court_slots()
returns void language plpgsql security definer set search_path=public as $$
declare c record; open_spots integer; block record;
begin
  for c in select court_number from public.waitlist_courts order by started_at,court_number loop
    select greatest(cfg.max_players-count(*),0) into open_spots
    from public.waitlist_config cfg left join public.waitlist_players p
      on p.status='current' and p.court_number=c.court_number where cfg.id group by cfg.max_players;
    for block in
      select coalesce(group_id,id) block_id,count(*)::integer block_size,min(queue_position) first_position,
        bool_or(sitout_priority) priority
      from public.waitlist_players where status='waiting'
      group by coalesce(group_id,id)
      order by bool_or(sitout_priority) desc,min(queue_position),coalesce(group_id,id)
    loop
      exit when open_spots<=0;
      if block.block_size<=open_spots then
        update public.waitlist_players set status='current',court_number=c.court_number,
          sitout_priority=false,updated_at=now()
        where status='waiting' and coalesce(group_id,id)=block.block_id;
        open_spots:=open_spots-block.block_size;
      end if;
    end loop;
  end loop;
  with ranked as(
    select id,row_number()over(order by case when status='current' then 0 else 1 end,
      coalesce(court_number,999),queue_position,id) rn
    from public.waitlist_players where status in('current','waiting') and queue_position is not null)
  update public.waitlist_players p set queue_position=ranked.rn from ranked where p.id=ranked.id;
end; $$;

create or replace function public.admin_set_court_count(p_court_count integer)
returns jsonb language plpgsql security definer set search_path=public as $$
declare cfg public.waitlist_config; old_count integer; court record; next_game integer;
begin
  if not public.is_waitlist_operator() then raise exception 'Admin or host access required.'; end if;
  if p_court_count<1 or p_court_count>12 then raise exception 'Choose between 1 and 12 courts.'; end if;
  perform pg_advisory_xact_lock(7429101);
  select * into cfg from public.waitlist_config where id for update; old_count:=cfg.court_count;
  if old_count=p_court_count then return jsonb_build_object('message',p_court_count||' court(s) are active.'); end if;
  perform public.save_admin_undo('change number of courts');
  if p_court_count<old_count then
    -- Remove the most recently started courts first. Their players keep their
    -- exact within-court order and move ahead of the existing shared waitlist.
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
    next_game:=greatest(cfg.game_number,(select coalesce(max(game_number),0) from public.waitlist_courts));
    for court in old_count+1..p_court_count loop
      next_game:=next_game+1;
      insert into public.waitlist_courts(court_number,game_number,started_at) values(court,next_game,now());
    end loop;
    update public.waitlist_config set game_number=next_game where id;
  end if;
  update public.waitlist_config set court_count=p_court_count,updated_at=now() where id;
  perform public.fill_open_court_slots();
  perform public.log_waitlist_operator_action('court_count','changed the number of courts to '||p_court_count||'.');
  return jsonb_build_object('message',p_court_count||' court(s) are now active.');
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
  next_game:=greatest(cfg.game_number,(select coalesce(max(game_number),0) from public.waitlist_courts))+1;
  update public.waitlist_courts set game_number=next_game,started_at=now() where court_number=p_court_number;
  update public.waitlist_config set game_number=next_game,updated_at=now() where id;
  perform public.fill_open_court_slots();
  actor:=coalesce(caller.display_name,'Admin');
  insert into public.waitlist_events(actor_user_id,actor_name,event_type,message)
    values(auth.uid(),actor,'next_game',actor||' started Game '||next_game||' on Court '||p_court_number||'.');
  return jsonb_build_object('message','Game '||next_game||' started on Court '||p_court_number||'.','game_number',next_game,'court_number',p_court_number,'rejoin_prompts',response_rows);
end; $$;

grant execute on function public.admin_set_court_count(integer) to authenticated;
grant execute on function public.end_court_game(integer) to authenticated;
