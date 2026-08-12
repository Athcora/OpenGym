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
declare c record; open_spots integer; block record; split_group uuid; split_members uuid[]; promoted_group uuid; remaining_size integer;
begin
  -- Compact the players already on courts before using the shared waitlist.
  -- This prevents Court 2 (or any later court) from keeping players while an
  -- earlier-numbered court has an open position.
  with settings as(
    select max_players from public.waitlist_config where id
  ), ranked as(
    select p.id,row_number()over(order by p.court_number,p.queue_position,p.id) rn,
      settings.max_players
    from public.waitlist_players p cross join settings
    where p.status='current'
  )
  update public.waitlist_players p
    set court_number=((ranked.rn-1)/ranked.max_players)+1,updated_at=now()
  from ranked where p.id=ranked.id;

  -- Courts always fill in numeric order: Court 1, then Court 2, and so on.
  for c in select court_number from public.waitlist_courts order by court_number loop
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
    -- If whole groups cannot fill the final spaces, split only the earliest
    -- group that is too large. This guarantees a court reaches 12 whenever
    -- enough waiting players exist while preserving groups whenever possible.
    if open_spots>0 then
      select p.group_id,count(*)::integer
        into split_group,remaining_size
      from public.waitlist_players p
      where p.status='waiting' and p.group_id is not null
      group by p.group_id
      having count(*)>open_spots
      order by min(p.queue_position),p.group_id
      limit 1;
      if split_group is not null then
        select array_agg(chosen.id order by chosen.queue_position,chosen.id)
          into split_members
        from (
          select p.id,p.queue_position
          from public.waitlist_players p
          where p.status='waiting' and p.group_id=split_group
          order by p.queue_position,p.id
          limit open_spots
        ) chosen;
        remaining_size:=remaining_size-coalesce(array_length(split_members,1),0);
        promoted_group:=case when coalesce(array_length(split_members,1),0)>1 then gen_random_uuid() else null end;
        insert into public.group_notifications(user_id,message)
          select distinct p.user_id,
            'Your group needed to split because there were not enough single players to make a full court.'
          from public.waitlist_players p
          where p.group_id=split_group and p.user_id is not null;
        update public.waitlist_players p
          set status='current',court_number=c.court_number,group_id=promoted_group,
              sitout_priority=false,updated_at=now()
          where p.id=any(split_members);
        if remaining_size<2 then
          update public.waitlist_players set group_id=null,updated_at=now()
          where group_id=split_group;
        end if;
        open_spots:=0;
      end if;
    end if;
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

-- Undo/redo must include every piece of multi-court state. Older restore
-- functions omitted court_number and the court rows, which collapsed all
-- restored current players onto Court 1.
create or replace function public.capture_waitlist_state()
returns jsonb language sql security definer set search_path=public as $$
  select jsonb_build_object(
    'players',coalesce((select jsonb_agg(to_jsonb(p) order by p.queue_position nulls last) from public.waitlist_players p),'[]'::jsonb),
    'config',(select to_jsonb(c) from public.waitlist_config c where c.id),
    'courts',coalesce((select jsonb_agg(to_jsonb(c) order by c.court_number) from public.waitlist_courts c),'[]'::jsonb),
    'past_games',coalesce((select jsonb_agg(to_jsonb(g) order by g.game_number) from public.past_games g),'[]'::jsonb)
  );
$$;

create or replace function public.restore_waitlist_state(p_state jsonb)
returns void language plpgsql security definer set search_path=public as $$
declare item jsonb; restored_court_count integer;
begin
  delete from public.waitlist_players where true;
  for item in select * from jsonb_array_elements(coalesce(p_state->'players','[]'::jsonb)) loop
    insert into public.waitlist_players(
      id,user_id,first_name,last_name,display_name,status,queue_position,restricted,
      rejoin_expires_at,created_at,updated_at,group_id,is_host,sitout_priority,sitout_from_game,court_number
    ) values(
      (item->>'id')::uuid,nullif(item->>'user_id','')::uuid,item->>'first_name',item->>'last_name',
      item->>'display_name',item->>'status',nullif(item->>'queue_position','')::bigint,
      coalesce((item->>'restricted')::boolean,false),nullif(item->>'rejoin_expires_at','')::timestamptz,
      (item->>'created_at')::timestamptz,now(),nullif(item->>'group_id','')::uuid,
      coalesce((item->>'is_host')::boolean,false),coalesce((item->>'sitout_priority')::boolean,false),
      nullif(item->>'sitout_from_game','')::integer,nullif(item->>'court_number','')::integer
    );
  end loop;
  restored_court_count:=coalesce(nullif(p_state->'config'->>'court_count','')::integer,1);
  update public.waitlist_config set
    game_number=(p_state->'config'->>'game_number')::integer,
    max_players=(p_state->'config'->>'max_players')::integer,
    court_count=restored_court_count,
    mode=p_state->'config'->>'mode',updated_at=now()
  where id;
  delete from public.waitlist_courts where true;
  if jsonb_array_length(coalesce(p_state->'courts','[]'::jsonb))>0 then
    for item in select * from jsonb_array_elements(p_state->'courts') loop
      insert into public.waitlist_courts(court_number,game_number,started_at)
      values((item->>'court_number')::integer,(item->>'game_number')::integer,(item->>'started_at')::timestamptz);
    end loop;
  else
    insert into public.waitlist_courts(court_number,game_number,started_at)
    select n,(p_state->'config'->>'game_number')::integer-greatest(restored_court_count-n,0),now()
    from generate_series(1,restored_court_count) n;
  end if;
  delete from public.past_games where true;
  for item in select * from jsonb_array_elements(coalesce(p_state->'past_games','[]'::jsonb)) loop
    insert into public.past_games(id,game_number,player_names,ended_at,court_number)
    values((item->>'id')::uuid,(item->>'game_number')::integer,item->'player_names',
      (item->>'ended_at')::timestamptz,coalesce(nullif(item->>'court_number','')::integer,1));
  end loop;
end;
$$;

create or replace function public.repair_active_court_assignments()
returns void language plpgsql security definer set search_path=public as $$
declare cfg public.waitlist_config; court record; player_id uuid; occupied integer;
begin
  select * into cfg from public.waitlist_config where id;
  -- Keep the earliest players already assigned to each court and release only overflow.
  with ranked as(
    select id,row_number()over(partition by court_number order by queue_position,id) rn
    from public.waitlist_players where status='current')
  update public.waitlist_players p set court_number=null from ranked
  where p.id=ranked.id and (p.court_number is null or ranked.rn>cfg.max_players);
  for court in select * from public.waitlist_courts order by started_at,court_number loop
    select count(*) into occupied from public.waitlist_players
      where status='current' and court_number=court.court_number;
    for player_id in select id from public.waitlist_players
      where status='current' and court_number is null order by queue_position,id
      limit greatest(cfg.max_players-occupied,0)
    loop
      update public.waitlist_players set court_number=court.court_number where id=player_id;
    end loop;
  end loop;
  -- If every active court is full, any remaining legacy overflow returns to the
  -- front of the shared waitlist instead of being silently shown on Court 1.
  update public.waitlist_players set status='waiting',court_number=null,updated_at=now()
    where status='current' and court_number is null;
  with ranked as(select id,row_number()over(order by case when status='current' then 0 else 1 end,queue_position,id) rn
    from public.waitlist_players where status in('current','waiting','sitout') and queue_position is not null)
  update public.waitlist_players p set queue_position=ranked.rn from ranked where p.id=ranked.id;
end;
$$;

select public.repair_active_court_assignments();
