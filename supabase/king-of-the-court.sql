-- Isolated King of the Court data and rotation logic for Teams Mode.
alter table public.waitlist_players add column if not exists team_id uuid;
alter table public.waitlist_config add column if not exists king_max_wins integer default 2;

create table if not exists public.king_teams(
  id uuid primary key default gen_random_uuid(),
  name text not null,
  status text not null default 'waiting' check(status in('waiting','current')),
  queue_position bigint not null,
  court_number integer,
  court_side integer check(court_side in(1,2)),
  consecutive_wins integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists king_teams_queue_idx on public.king_teams(status,queue_position);
create index if not exists waitlist_players_team_idx on public.waitlist_players(team_id);

create table if not exists public.king_round_history(
  id bigint generated always as identity primary key,
  court_number integer not null,
  game_number integer not null,
  winning_team_id uuid not null,
  winning_team_name text not null,
  losing_team_name text not null,
  snapshot jsonb not null,
  actor_user_id uuid,
  reversed_at timestamptz,
  created_at timestamptz not null default now()
);
create table if not exists public.king_mode_state(
  id boolean primary key default true check(id),
  regular_state jsonb not null,
  saved_at timestamptz not null default now()
);

alter table public.king_teams enable row level security;
alter table public.king_round_history enable row level security;
alter table public.king_mode_state enable row level security;
drop policy if exists "everyone reads king teams" on public.king_teams;
create policy "everyone reads king teams" on public.king_teams for select to authenticated using(true);
drop policy if exists "everyone reads king rounds" on public.king_round_history;
create policy "everyone reads king rounds" on public.king_round_history for select to authenticated using(true);

create or replace function public.king_team_label(p_id uuid)
returns text language sql stable security definer set search_path=public as $$
  select coalesce(nullif(string_agg(p.display_name, ' + ' order by p.created_at),''),t.name)
  from public.king_teams t left join public.waitlist_players p on p.team_id=t.id and p.status<>'left'
  where t.id=p_id group by t.name;
$$;

create or replace function public.king_compact_queue()
returns void language plpgsql security definer set search_path=public as $$
begin
  with ranked as(
    select id,row_number() over(order by queue_position,created_at,id) rn
    from public.king_teams where status='waiting'
  ) update public.king_teams t set queue_position=r.rn,updated_at=now() from ranked r where t.id=r.id;
end; $$;

create or replace function public.king_fill_courts()
returns void language plpgsql security definer set search_path=public as $$
declare c record; side_no integer; next_team uuid;
begin
  for c in select court_number from public.waitlist_courts order by court_number loop
    for side_no in 1..2 loop
      if not exists(select 1 from public.king_teams where status='current' and court_number=c.court_number and court_side=side_no) then
        select t.id into next_team from public.king_teams t
        where t.status='waiting' and exists(select 1 from public.waitlist_players p where p.team_id=t.id and p.status<>'left')
        order by t.queue_position,t.created_at limit 1 for update skip locked;
        if next_team is not null then
          update public.king_teams set status='current',court_number=c.court_number,court_side=side_no,
            queue_position=0,consecutive_wins=0,updated_at=now() where id=next_team;
          update public.waitlist_players set status='current',court_number=c.court_number,updated_at=now()
            where team_id=next_team and status<>'left';
        end if;
        next_team:=null;
      end if;
    end loop;
  end loop;
  perform public.king_compact_queue();
end; $$;

create or replace function public.join_king_team(p_player_id uuid,p_team_id uuid default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare player public.waitlist_players; target public.king_teams; old_team uuid; member_count integer; next_pos bigint; next_no integer;
begin
  perform pg_advisory_xact_lock(7429201);
  select * into player from public.waitlist_players where id=p_player_id for update;
  if player.id is null or (player.user_id<>auth.uid() and not public.is_waitlist_operator()) then raise exception 'You cannot move that player.'; end if;
  old_team:=player.team_id;
  if p_team_id is null then
    select coalesce(max(queue_position),0)+1 into next_pos from public.king_teams where status='waiting';
    select coalesce(max((regexp_match(name,'[0-9]+'))[1]::integer),0)+1 into next_no from public.king_teams;
    insert into public.king_teams(name,queue_position) values('Team '||next_no,next_pos) returning * into target;
  else
    select * into target from public.king_teams where id=p_team_id for update;
    if target.id is null or target.status<>'waiting' then raise exception 'You can only join a waiting team.'; end if;
    select count(*) into member_count from public.waitlist_players where team_id=target.id and status<>'left';
    if member_count>=6 then raise exception 'That team is full.'; end if;
  end if;
  update public.waitlist_players set team_id=target.id,status=target.status,
    court_number=target.court_number,updated_at=now() where id=player.id;
  if old_team is not null and old_team<>target.id and not exists(select 1 from public.waitlist_players where team_id=old_team and status<>'left') then
    delete from public.king_teams where id=old_team;
  end if;
  perform public.king_fill_courts();
  return jsonb_build_object('message','You joined '||public.king_team_label(target.id)||'.','team_id',target.id);
end; $$;
grant execute on function public.join_king_team(uuid,uuid) to authenticated;

create or replace function public.king_prepare_player(p_player_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
begin
  return public.join_king_team(p_player_id,null);
end; $$;
grant execute on function public.king_prepare_player(uuid) to authenticated;

create or replace function public.set_king_max_wins(p_max_wins integer)
returns jsonb language plpgsql security definer set search_path=public as $$
begin
  if not public.is_waitlist_operator() then raise exception 'Admin or host access required.'; end if;
  if p_max_wins is not null and (p_max_wins<1 or p_max_wins>20) then raise exception 'Choose 1 to 20 wins, or Unlimited.'; end if;
  update public.waitlist_config set king_max_wins=p_max_wins,updated_at=now() where id;
  return jsonb_build_object('message',case when p_max_wins is null then 'Win limit set to Unlimited.' else 'Win limit set to '||p_max_wins||'.' end);
end; $$;
grant execute on function public.set_king_max_wins(integer) to authenticated;

create or replace function public.end_king_game(p_court_number integer,p_winning_team_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare cfg public.waitlist_config; court public.waitlist_courts; winner public.king_teams; loser public.king_teams;
  caller public.waitlist_players; next_pos bigint; next_game integer; winner_stays boolean; snap jsonb;
begin
  perform pg_advisory_xact_lock(7429202);
  select * into cfg from public.waitlist_config where id for update;
  if cfg.mode<>'teams' then raise exception 'King of the Court is only available in Teams Mode.'; end if;
  select * into court from public.waitlist_courts where court_number=p_court_number for update;
  select * into winner from public.king_teams where id=p_winning_team_id and status='current' and court_number=p_court_number for update;
  select * into loser from public.king_teams where status='current' and court_number=p_court_number and id<>p_winning_team_id order by court_side limit 1 for update;
  if winner.id is null or loser.id is null then raise exception 'Two active teams are required on this court.'; end if;
  select * into caller from public.waitlist_players where user_id=auth.uid();
  if not public.is_waitlist_operator() and (caller.id is null or caller.team_id not in(winner.id,loser.id) or caller.restricted) then
    raise exception 'Only a player on this court or an admin/host can record the winner.';
  end if;
  snap:=jsonb_build_object(
    'teams',(select jsonb_agg(to_jsonb(t) order by t.created_at) from public.king_teams t),
    'players',(select jsonb_agg(jsonb_build_object('id',p.id,'status',p.status,'court_number',p.court_number,'team_id',p.team_id)) from public.waitlist_players p),
    'court',to_jsonb(court),'config_game_number',cfg.game_number
  );
  insert into public.past_games(game_number,court_number,player_names)
    select court.game_number,p_court_number,coalesce(jsonb_agg(p.display_name order by t.court_side,p.created_at),'[]'::jsonb)
    from public.king_teams t left join public.waitlist_players p on p.team_id=t.id and p.status<>'left'
    where t.id in(winner.id,loser.id);
  select coalesce(max(queue_position),0)+1 into next_pos from public.king_teams where status='waiting';
  update public.king_teams set status='waiting',queue_position=next_pos,court_number=null,court_side=null,
    consecutive_wins=0,updated_at=now() where id=loser.id;
  update public.waitlist_players set status='waiting',court_number=null,updated_at=now() where team_id=loser.id and status<>'left';
  winner_stays:=cfg.king_max_wins is null or winner.consecutive_wins+1<cfg.king_max_wins;
  if winner_stays then
    update public.king_teams set consecutive_wins=consecutive_wins+1,updated_at=now() where id=winner.id;
  else
    update public.king_teams set status='waiting',queue_position=next_pos+1,court_number=null,court_side=null,
      consecutive_wins=0,updated_at=now() where id=winner.id;
    update public.waitlist_players set status='waiting',court_number=null,updated_at=now() where team_id=winner.id and status<>'left';
  end if;
  next_game:=greatest(
    cfg.game_number,
    (select coalesce(max(game_number),0) from public.waitlist_courts),
    (select coalesce(max(game_number),0) from public.past_games)
  )+1;
  update public.waitlist_config set game_number=next_game,updated_at=now() where id;
  update public.waitlist_courts set game_number=next_game,started_at=now() where court_number=p_court_number;
  insert into public.king_round_history(court_number,game_number,winning_team_id,winning_team_name,losing_team_name,snapshot,actor_user_id)
    values(p_court_number,court.game_number,winner.id,public.king_team_label(winner.id),public.king_team_label(loser.id),snap,auth.uid());
  perform public.king_compact_queue();
  perform public.king_fill_courts();
  insert into public.waitlist_events(actor_user_id,actor_name,event_type,message)
    values(auth.uid(),coalesce(caller.display_name,'Admin'),'king_game',public.king_team_label(winner.id)||' won Game '||court.game_number||' on Court '||p_court_number||'.');
  return jsonb_build_object('message','Advancement complete.','game_number',next_game,'winner',public.king_team_label(winner.id),'winner_stays',winner_stays);
end; $$;
grant execute on function public.end_king_game(integer,uuid) to authenticated;

create or replace function public.reverse_king_game()
returns jsonb language plpgsql security definer set search_path=public as $$
declare round public.king_round_history; item jsonb;
begin
  select * into round from public.king_round_history
    where reversed_at is null and (public.is_waitlist_operator() or actor_user_id=auth.uid())
    order by id desc limit 1 for update;
  if round.id is null then raise exception 'There is no King of the Court advancement available to reverse.'; end if;
  for item in select * from jsonb_array_elements(round.snapshot->'teams') loop
    insert into public.king_teams(id,name,status,queue_position,court_number,court_side,consecutive_wins,created_at,updated_at)
    values((item->>'id')::uuid,item->>'name',item->>'status',(item->>'queue_position')::bigint,
      nullif(item->>'court_number','')::integer,nullif(item->>'court_side','')::integer,
      (item->>'consecutive_wins')::integer,(item->>'created_at')::timestamptz,now())
    on conflict(id) do update set name=excluded.name,status=excluded.status,queue_position=excluded.queue_position,
      court_number=excluded.court_number,court_side=excluded.court_side,consecutive_wins=excluded.consecutive_wins,
      updated_at=now();
  end loop;
  for item in select * from jsonb_array_elements(round.snapshot->'players') loop
    update public.waitlist_players set status=item->>'status',court_number=nullif(item->>'court_number','')::integer,
      team_id=nullif(item->>'team_id','')::uuid,updated_at=now() where id=(item->>'id')::uuid;
  end loop;
  update public.waitlist_courts set game_number=(round.snapshot->'court'->>'game_number')::integer,
    started_at=(round.snapshot->'court'->>'started_at')::timestamptz where court_number=round.court_number;
  update public.waitlist_config set game_number=(round.snapshot->>'config_game_number')::integer,updated_at=now() where id;
  delete from public.past_games where game_number=round.game_number and court_number=round.court_number;
  update public.king_round_history set reversed_at=now() where id=round.id;
  return jsonb_build_object('message','The previous King of the Court game and team order were restored.');
end; $$;
grant execute on function public.reverse_king_game() to authenticated;

-- Switching into Teams Mode turns active players into stable teams without
-- changing the regular/rejoin tables or their rotation functions.
create or replace function public.initialize_king_mode()
returns void language plpgsql security definer set search_path=public as $$
declare p record; created_team uuid; next_pos bigint:=0;
begin
  if not exists(select 1 from public.waitlist_config where id and mode='teams') then return; end if;
  for p in select * from public.waitlist_players where status<>'left' and team_id is null order by queue_position,id loop
    next_pos:=next_pos+1;
    insert into public.king_teams(name,queue_position) values('Team '||next_pos,next_pos) returning id into created_team;
    update public.waitlist_players set team_id=created_team,status='waiting',court_number=null where id=p.id;
  end loop;
  perform public.king_fill_courts();
end; $$;

create or replace function public.set_open_gym_mode(p_mode text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare current_mode text; saved jsonb; team_to_delete uuid; player_to_clear uuid;
begin
  if not exists(select 1 from public.admin_sessions where user_id=auth.uid()) then raise exception 'Admin access required.'; end if;
  if p_mode not in('regular','rejoin','teams') then raise exception 'Unknown waitlist mode.'; end if;
  select mode into current_mode from public.waitlist_config where id for update;
  if current_mode=p_mode then return jsonb_build_object('message','Mode unchanged.'); end if;
  if p_mode='teams' then
    insert into public.king_mode_state(id,regular_state,saved_at)
      values(true,public.capture_waitlist_state(),now())
      on conflict(id) do update set regular_state=excluded.regular_state,saved_at=now();
    update public.waitlist_config set mode='teams',updated_at=now() where id;
    perform public.initialize_king_mode();
  elsif current_mode='teams' then
    select regular_state into saved from public.king_mode_state where id;
    if saved is not null then perform public.restore_waitlist_state(saved); end if;
    update public.waitlist_config set mode=p_mode,updated_at=now() where id;
    for team_to_delete in select id from public.king_teams loop
      delete from public.king_teams where id=team_to_delete;
    end loop;
    for player_to_clear in select id from public.waitlist_players where team_id is not null loop
      update public.waitlist_players set team_id=null where id=player_to_clear;
    end loop;
  else
    update public.waitlist_config set mode=p_mode,updated_at=now() where id;
  end if;
  return jsonb_build_object('message','Waitlist mode changed to '||p_mode||'.');
end; $$;
grant execute on function public.set_open_gym_mode(text) to authenticated;

do $$ begin
  alter publication supabase_realtime add table public.king_teams;
exception when duplicate_object then null; end $$;
do $$ begin
  alter publication supabase_realtime add table public.king_round_history;
exception when duplicate_object then null; end $$;
