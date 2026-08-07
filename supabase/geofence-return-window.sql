-- Durable player return window after leaving an enabled facility geofence.
create table if not exists public.geofence_return_prompts (
  id uuid primary key default gen_random_uuid(), player_id uuid not null references public.waitlist_players(id) on delete cascade,
  user_id uuid not null, original_status text not null check (original_status in ('current','waiting','sitout')),
  original_position bigint not null, removed_at timestamptz not null default now(),
  saved_position_until timestamptz not null default (now()+interval '1 minute'),
  expires_at timestamptz not null default (now()+interval '10 minutes'), resolved_at timestamptz, resolution text
);
create unique index if not exists geofence_return_one_pending_per_player on public.geofence_return_prompts(player_id) where resolved_at is null;
alter table public.geofence_return_prompts enable row level security;
drop policy if exists "players view their geofence return window" on public.geofence_return_prompts;
create policy "players view their geofence return window" on public.geofence_return_prompts for select to authenticated using (user_id=auth.uid());

create or replace function public.normalize_active_waitlist()
returns void language plpgsql security definer set search_path=public as $$
declare c public.waitlist_config; candidate record; open_spots integer;
begin
  select * into c from public.waitlist_config where id;
  update public.waitlist_players set status='waiting' where status in ('current','waiting') and queue_position is not null;
  open_spots:=c.max_players;
  for candidate in select p.group_id,case when p.group_id is null then p.id end member_id,count(*)::integer member_count,min(p.queue_position) first_position
    from public.waitlist_players p where p.status='waiting' and p.queue_position is not null
    group by p.group_id,case when p.group_id is null then p.id end order by min(p.queue_position)
  loop
    if candidate.member_count<=open_spots then
      update public.waitlist_players p set status='current',updated_at=now()
      where (candidate.group_id is not null and p.group_id=candidate.group_id) or (candidate.group_id is null and p.id=candidate.member_id);
      open_spots:=open_spots-candidate.member_count;
    end if;
    exit when open_spots=0;
  end loop;
  with ranked as (select id,row_number() over(order by queue_position,id) rn from public.waitlist_players where status in ('current','waiting','sitout') and queue_position is not null)
  update public.waitlist_players p set queue_position=ranked.rn from ranked where p.id=ranked.id;
end; $$;

create or replace function public.remove_self_for_geofence()
returns jsonb language plpgsql security definer set search_path=public as $$
declare p public.waitlist_players; c public.waitlist_config; prompt public.geofence_return_prompts; remaining integer;
begin
  if public.is_waitlist_admin() then raise exception 'This return window is only for players.'; end if;
  select * into c from public.waitlist_config where id;
  if not c.geofence_enabled or c.mode='teams' then raise exception 'The facility location check is not active for this waitlist.'; end if;
  select * into p from public.waitlist_players where user_id=auth.uid() for update;
  if p.id is null then raise exception 'Player not found.'; end if;
  select * into prompt from public.geofence_return_prompts where player_id=p.id and resolved_at is null and expires_at>now() order by removed_at desc limit 1;
  if prompt.id is not null then return jsonb_build_object('id',prompt.id,'removed_at',prompt.removed_at,'saved_position_until',prompt.saved_position_until,'expires_at',prompt.expires_at); end if;
  if p.status not in ('current','waiting','sitout') or p.queue_position is null then raise exception 'You are not currently in the waitlist.'; end if;
  insert into public.geofence_return_prompts(player_id,user_id,original_status,original_position) values(p.id,auth.uid(),p.status,p.queue_position) returning * into prompt;
  update public.waitlist_players set status='left',queue_position=null,group_id=null,rejoin_expires_at=null,updated_at=now() where id=p.id;
  if p.group_id is not null then select count(*) into remaining from public.waitlist_players where group_id=p.group_id and status in ('current','waiting','sitout'); if remaining<2 then update public.waitlist_players set group_id=null,updated_at=now() where group_id=p.group_id; end if; end if;
  perform public.normalize_active_waitlist();
  insert into public.waitlist_events(actor_user_id,actor_name,event_type,message) values(auth.uid(),p.display_name,'geofence_leave',p.display_name||' was removed after leaving the facility area.');
  return jsonb_build_object('id',prompt.id,'removed_at',prompt.removed_at,'saved_position_until',prompt.saved_position_until,'expires_at',prompt.expires_at);
end; $$;

create or replace function public.return_after_geofence(p_prompt_id uuid,p_latitude double precision,p_longitude double precision)
returns jsonb language plpgsql security definer set search_path=public as $$
declare prompt public.geofence_return_prompts; p public.waitlist_players; c public.waitlist_config; distance_m double precision; target bigint; back_position bigint; saved boolean;
begin
  select * into prompt from public.geofence_return_prompts where id=p_prompt_id and user_id=auth.uid() for update;
  if prompt.id is null or prompt.resolved_at is not null then raise exception 'This return window is no longer available.'; end if;
  if prompt.expires_at<=now() then update public.geofence_return_prompts set resolved_at=now(),resolution='expired' where id=prompt.id; raise exception 'Your 10-minute return window has expired.'; end if;
  select * into c from public.waitlist_config where id;
  if c.geofence_enabled and c.facility_latitude is not null and c.facility_longitude is not null then
    distance_m:=6371000*acos(least(1,greatest(-1,sin(radians(c.facility_latitude))*sin(radians(p_latitude))+cos(radians(c.facility_latitude))*cos(radians(p_latitude))*cos(radians(p_longitude-c.facility_longitude)))));
    if distance_m>c.geofence_radius_m then return jsonb_build_object('inside',false,'distance_m',round(distance_m::numeric,1),'radius_m',c.geofence_radius_m); end if;
  end if;
  select * into p from public.waitlist_players where id=prompt.player_id for update;
  if p.id is null then raise exception 'Player not found.'; end if;
  saved:=now()<=prompt.saved_position_until;
  select coalesce(max(queue_position),0)+1 into back_position from public.waitlist_players where status in ('current','waiting','sitout');
  target:=case when saved then least(prompt.original_position,back_position) else back_position end;
  update public.waitlist_players set queue_position=queue_position+1 where status in ('current','waiting','sitout') and queue_position>=target;
  update public.waitlist_players set status='waiting',queue_position=target,rejoin_expires_at=null,updated_at=now() where id=p.id;
  perform public.normalize_active_waitlist();
  update public.geofence_return_prompts set resolved_at=now(),resolution=case when saved then 'saved_position' else 'back' end where id=prompt.id;
  insert into public.waitlist_events(actor_user_id,actor_name,event_type,message) values(auth.uid(),p.display_name,'geofence_return',p.display_name||case when saved then ' returned to their saved position.' else ' rejoined at the back of the waitlist.' end);
  return jsonb_build_object('inside',true,'saved_position',saved,'message',case when saved then 'You are back at your saved position.' else 'You rejoined at the back of the waitlist.' end);
end; $$;
grant execute on function public.remove_self_for_geofence() to authenticated;
grant execute on function public.return_after_geofence(uuid,double precision,double precision) to authenticated;
do $$ begin alter publication supabase_realtime add table public.geofence_return_prompts; exception when duplicate_object then null; end $$;
