create table if not exists public.substitute_requests(
  id uuid primary key default gen_random_uuid(),
  requester_id uuid not null references public.waitlist_players(id) on delete cascade,
  target_id uuid not null references public.waitlist_players(id) on delete cascade,
  status text not null default 'pending' check(status in ('pending','accepted','declined')),
  created_at timestamptz not null default now(),
  answered_at timestamptz
);

alter table public.substitute_requests enable row level security;
drop policy if exists "players view their substitute requests" on public.substitute_requests;
create policy "players view their substitute requests" on public.substitute_requests for select to authenticated
using(exists(select 1 from public.waitlist_players p where (p.id=requester_id or p.id=target_id) and p.user_id=auth.uid()));
revoke insert,update,delete on public.substitute_requests from anon,authenticated;
grant select on public.substitute_requests to authenticated;

do $$ begin
  alter publication supabase_realtime add table public.substitute_requests;
exception when duplicate_object then null; end $$;

create or replace function public.swap_waitlist_players(p_first_id uuid,p_second_id uuid)
returns void language plpgsql security definer set search_path=public as $$
declare first_player public.waitlist_players;second_player public.waitlist_players;first_group uuid;second_group uuid;
declare member_count integer;status_count integer;court_count integer;position_span bigint;
begin
  select * into first_player from public.waitlist_players where id=p_first_id and status in ('current','waiting','sitout') for update;
  select * into second_player from public.waitlist_players where id=p_second_id and status in ('current','waiting','sitout') for update;
  if first_player.id is null or second_player.id is null then raise exception 'Both players must still be in the current game or waitlist.';end if;
  if first_player.id=second_player.id then raise exception 'Choose two different players.';end if;
  first_group:=first_player.group_id;second_group:=second_player.group_id;
  update public.waitlist_players set
    status=case when id=first_player.id then second_player.status else first_player.status end,
    queue_position=case when id=first_player.id then second_player.queue_position else first_player.queue_position end,
    court_number=case when id=first_player.id then second_player.court_number else first_player.court_number end,
    team_id=case when id=first_player.id then second_player.team_id else first_player.team_id end,
    sitout_priority=case when id=first_player.id then second_player.sitout_priority else first_player.sitout_priority end,
    sitout_from_game=case when id=first_player.id then second_player.sitout_from_game else first_player.sitout_from_game end,
    updated_at=now()
  where id in(first_player.id,second_player.id);
  -- A selected player keeps their group only when their new placement remains
  -- in the same contiguous block, status, and court as that group.
  if first_group is not null and first_group is distinct from second_group then
    select count(*),count(distinct status),count(distinct coalesce(court_number,0)),max(queue_position)-min(queue_position)+1
      into member_count,status_count,court_count,position_span from public.waitlist_players where group_id=first_group;
    if member_count<2 or status_count<>1 or court_count<>1 or position_span<>member_count then
      update public.waitlist_players set group_id=null,updated_at=now() where id=first_player.id;
    end if;
  end if;
  if second_group is not null and second_group is distinct from first_group then
    select count(*),count(distinct status),count(distinct coalesce(court_number,0)),max(queue_position)-min(queue_position)+1
      into member_count,status_count,court_count,position_span from public.waitlist_players where group_id=second_group;
    if member_count<2 or status_count<>1 or court_count<>1 or position_span<>member_count then
      update public.waitlist_players set group_id=null,updated_at=now() where id=second_player.id;
    end if;
  end if;
  if first_group is not null and (select count(*) from public.waitlist_players where group_id=first_group)<=1 then update public.waitlist_players set group_id=null,updated_at=now() where group_id=first_group;end if;
  if second_group is not null and second_group is distinct from first_group and (select count(*) from public.waitlist_players where group_id=second_group)<=1 then update public.waitlist_players set group_id=null,updated_at=now() where group_id=second_group;end if;
  insert into public.waitlist_events(actor_user_id,actor_name,event_type,message)
  select p.user_id,p.display_name,'substitute',p.display_name||' swapped positions with '||case when p.id=first_player.id then second_player.display_name else first_player.display_name end||'.'
  from public.waitlist_players p
  where p.id in(first_player.id,second_player.id) and p.user_id is not null;
end;
$$;

create or replace function public.admin_substitute_players(p_first_id uuid,p_second_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare first_name text;second_name text;
begin
  if not public.is_waitlist_operator() then raise exception 'Admin or host access required.';end if;
  select display_name into first_name from public.waitlist_players where id=p_first_id;
  select display_name into second_name from public.waitlist_players where id=p_second_id;
  perform pg_advisory_xact_lock(7429102);perform public.save_admin_undo('substitute players');perform public.swap_waitlist_players(p_first_id,p_second_id);
  perform public.notify_waitlist_operator_player(p.user_id,'substituted your position with another player.') from public.waitlist_players p where p.id in(p_first_id,p_second_id);
  perform public.log_waitlist_operator_action('admin_substitute','substituted '||coalesce(first_name,'a player')||' with '||coalesce(second_name,'another player')||'.');
  return jsonb_build_object('message','The players successfully swapped positions.');
end;
$$;

create or replace function public.request_player_substitute(p_target_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare requester public.waitlist_players;target public.waitlist_players;request_id uuid;
begin
  select * into requester from public.waitlist_players where user_id=auth.uid() and status in ('current','waiting','sitout');
  select * into target from public.waitlist_players where id=p_target_id and status in ('current','waiting','sitout');
  if requester.id is null then raise exception 'You must be active in the waitlist to request a substitute.';end if;
  if target.id is null or target.user_id is null then raise exception 'That player cannot receive a substitute request.';end if;
  if requester.id=target.id then raise exception 'Choose another player.';end if;
  -- Close requests that can no longer be answered and expire requests that
  -- have been left open. A new outgoing request replaces the requester's old
  -- outgoing request instead of trapping them behind a stale error.
  update public.substitute_requests r set status='declined',answered_at=now()
    where r.status='pending' and (r.created_at<now()-interval '5 minutes'
      or not exists(select 1 from public.waitlist_players p where p.id=r.requester_id and p.status in('current','waiting','sitout'))
      or not exists(select 1 from public.waitlist_players p where p.id=r.target_id and p.status in('current','waiting','sitout')));
  update public.substitute_requests set status='declined',answered_at=now()
    where requester_id=requester.id and status='pending';
  if exists(select 1 from public.substitute_requests where status='pending'
    and (requester_id in(requester.id,target.id) or target_id in(requester.id,target.id))) then
    raise exception 'That player is currently deciding another substitute request. Try again shortly.';
  end if;
  insert into public.substitute_requests(requester_id,target_id) values(requester.id,target.id) returning id into request_id;
  insert into public.waitlist_events(actor_user_id,actor_name,event_type,message)
  values(requester.user_id,requester.display_name,'substitute_request',requester.display_name||' requested a permanent substitute swap with '||target.display_name||'.');
  insert into public.waitlist_events(actor_user_id,actor_name,event_type,message)
  values(target.user_id,target.display_name,'substitute_request',target.display_name||' received a permanent substitute request from '||requester.display_name||'.');
  return jsonb_build_object('message','Your substitute request was sent to '||target.display_name||'.','request_id',request_id);
end;
$$;

create or replace function public.answer_player_substitute(p_request_id uuid,p_accept boolean)
returns jsonb language plpgsql security definer set search_path=public as $$
declare request public.substitute_requests;target public.waitlist_players;requester public.waitlist_players;
begin
  perform pg_advisory_xact_lock(7429102);
  select r.* into request from public.substitute_requests r join public.waitlist_players p on p.id=r.target_id where r.id=p_request_id and r.status='pending' and p.user_id=auth.uid() for update;
  if request.id is null then raise exception 'Substitute request not found.';end if;
  if not p_accept then update public.substitute_requests set status='declined',answered_at=now() where id=request.id;return jsonb_build_object('message','Substitute request declined.');end if;
  select * into requester from public.waitlist_players where id=request.requester_id;select * into target from public.waitlist_players where id=request.target_id;
  perform public.swap_waitlist_players(request.requester_id,request.target_id);
  update public.substitute_requests set status='accepted',answered_at=now() where id=request.id;
  update public.substitute_requests set status='declined',answered_at=now()
    where id<>request.id and status='pending'
      and (requester_id in(request.requester_id,request.target_id) or target_id in(request.requester_id,request.target_id));
  insert into public.group_notifications(user_id,message) select requester.user_id,target.display_name||' accepted your substitute request.' where requester.user_id is not null;
  return jsonb_build_object('message','You swapped positions with '||requester.display_name||'.');
end;
$$;

grant execute on function public.admin_substitute_players(uuid,uuid) to authenticated;
grant execute on function public.request_player_substitute(uuid) to authenticated;
grant execute on function public.answer_player_substitute(uuid,boolean) to authenticated;
