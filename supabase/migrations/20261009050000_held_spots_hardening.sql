-- Held rejoin spots: hardening found by stress testing.
--
-- 1. Seats placed by an admin/host (drag onto a court, swap) or restored by
--    undo are never provisional: only seats handed out by the allocator while
--    someone ahead is still deciding can be taken back.
-- 2. Swapping a court player with a waitlist player now also swaps their
--    place in the line (line_key), so the one who goes to the waitlist lands
--    exactly where the other one was.
-- 3. Line keys are re-numbered once repeated "insert halfway" placements make
--    them long, so they never run out of precision and tie.
-- 4. A group whose first member rejoined (and was placed) is never split
--    across courts when the rest of the group rejoins.
-- 5. A group is judged at its earliest member's place in line, so one
--    member is never moved off the court while a group-mate stays on.
-- 6. Dragging a group onto a full court pushes out the players already there,
--    never a member of the group being moved.
-- 7. Waitlist display order ignores the old court of players sitting out.
begin;

alter table public.waitlist_players add column if not exists seat_locked boolean not null default false;
comment on column public.waitlist_players.seat_locked is
  'True when the current seat was placed outside the allocator (admin move, swap, undo); such seats are never provisional.';

create or replace function public.wl_mark_rejoin_returning()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
begin
  if tg_op='INSERT' then
    new.seat_locked:=(new.status='current' and coalesce(current_setting('opengym.in_allocator',true),'')<>'1');
    return new;
  end if;
  if old.status='rejoin' and new.status='waiting' then
    new.rejoin_returning:=true;
  elsif new.status<>'waiting' then
    new.rejoin_returning:=false;
  end if;
  if new.status='current' and old.status is distinct from 'current' then
    new.seat_locked:=coalesce(current_setting('opengym.in_allocator',true),'')<>'1';
  elsif new.status<>'current' then
    new.seat_locked:=false;
  end if;
  return new;
end;
$$;

alter function public.wl_mark_rejoin_returning() owner to opengym_runtime;
revoke all on function public.wl_mark_rejoin_returning() from public, anon, authenticated;

drop trigger if exists waitlist_players_mark_rejoin_returning_insert on public.waitlist_players;
create trigger waitlist_players_mark_rejoin_returning_insert
  before insert on public.waitlist_players
  for each row execute function public.wl_mark_rejoin_returning();

create or replace function public.wl_seat_is_provisional(p_player_id uuid)
returns boolean
language sql
stable
security definer
set search_path=public
as $$
  -- A group is judged as one unit at its earliest member's place in line,
  -- and a group with any admin-placed (locked) member is locked as a whole.
  with me as (
    select p.*,
           case when p.group_id is null then p.line_key
                else (select min(g.line_key) from public.waitlist_players g
                       where g.facility_id=p.facility_id and g.group_id=p.group_id
                         and g.status in ('current','waiting')) end as unit_key,
           p.seat_locked or (p.group_id is not null and exists(
             select 1 from public.waitlist_players g
              where g.facility_id=p.facility_id and g.group_id=p.group_id
                and g.status='current' and g.seat_locked)) as unit_locked
      from public.waitlist_players p
     where p.id=p_player_id and p.status='current'
  )
  select exists(
    select 1 from me
      join public.waitlist_players held
        on held.facility_id=me.facility_id and held.status='rejoin'
     where not me.unit_locked
       and ((held.line_key is not null and me.unit_key is not null and held.line_key<me.unit_key)
         or (me.group_id is not null and held.group_id=me.group_id)))
  or exists(
    select 1 from me
      join public.waitlist_players mate
        on mate.facility_id=me.facility_id and mate.group_id=me.group_id and mate.id<>me.id
     where not me.unit_locked and me.group_id is not null
       and mate.status='waiting' and mate.rejoin_returning)
$$;

alter function public.wl_seat_is_provisional(uuid) owner to opengym_runtime;
revoke all on function public.wl_seat_is_provisional(uuid) from public, anon, authenticated;

create or replace function public.fill_facility_open_slots(
  p_facility_id uuid,
  p_always_renumber boolean default true
)
returns integer
language plpgsql
security definer
set search_path=public
as $$
declare
  cfg public.waitlist_config;
  court record;
  unit record;
  r record;
  seats integer;
  seated integer:=0;
  changed boolean;
  pass integer:=0;
  lower_key numeric;
  upper_key numeric;
  start_current uuid[];
  waiting_rank integer;
  slug text;
  reorder boolean;
  picked uuid[];
begin
  if p_facility_id is null then
    return 0;
  end if;
  select * into cfg from public.waitlist_config where facility_id=p_facility_id and id;
  if cfg.facility_id is null or coalesce(cfg.max_players,0)<=0 then
    return 0;
  end if;
  -- Team / King modes seat whole teams through king_fill_courts().
  if cfg.mode::text ~* '(king|team)' then
    return 0;
  end if;

  perform set_config('opengym.in_allocator','1',true);

  select coalesce(array_agg(id),'{}') into start_current
    from public.waitlist_players where facility_id=p_facility_id and status='current';

  -- 3a. Keys for rows that do not have one yet --------------------------------
  -- Held spots without a key (created before this migration): back of line.
  for r in
    select id from public.waitlist_players
     where facility_id=p_facility_id and status='rejoin' and line_key is null
     order by queue_position nulls last,id
  loop
    update public.waitlist_players
       set line_key=coalesce((select max(line_key) from public.waitlist_players
                               where facility_id=p_facility_id
                                 and status in ('current','waiting','sitout','rejoin')),0)+1
     where id=r.id;
  end loop;

  -- Seated directly (e.g. admin add to a court): seated for real.
  update public.waitlist_players
     set line_key=coalesce((select min(line_key) from public.waitlist_players
                             where facility_id=p_facility_id
                               and status in ('current','waiting','sitout','rejoin')),1)-1
   where facility_id=p_facility_id and status='current' and line_key is null;

  -- New / returning waiting players, in their queue order. A player added at
  -- the back goes ahead of held spots whose owners have not tapped yet, but
  -- behind everyone who is actually in line.
  for r in
    select p.id,p.queue_position,
           (select max(q.line_key) from public.waitlist_players q
             where q.facility_id=p_facility_id and q.status in ('waiting','sitout')
               and q.line_key is not null
               and (q.queue_position,q.id)<(p.queue_position,p.id)) as prev_key,
           exists(select 1 from public.waitlist_players q
                   where q.facility_id=p_facility_id and q.status in ('waiting','sitout')
                     and q.line_key is not null
                     and (q.queue_position,q.id)>(p.queue_position,p.id)) as has_later
      from public.waitlist_players p
     where p.facility_id=p_facility_id and p.status in ('waiting','sitout') and p.line_key is null
     order by p.queue_position nulls last,p.id
  loop
    if r.has_later then
      lower_key:=r.prev_key;
    else
      select max(line_key) into lower_key from public.waitlist_players
       where facility_id=p_facility_id and status in ('current','waiting','sitout');
    end if;
    select min(line_key) into upper_key from public.waitlist_players
     where facility_id=p_facility_id and status in ('current','waiting','sitout','rejoin')
       and line_key>coalesce(lower_key,-1e18);
    update public.waitlist_players
       set line_key=case
         when lower_key is null and upper_key is null then 1
         when lower_key is null then upper_key-1
         when upper_key is null then lower_key+1
         else (lower_key+upper_key)/2 end
     where id=r.id;
  end loop;

  -- 3b. Adopt explicit reorders of the waitlist ------------------------------
  reorder:=position(p_facility_id::text in coalesce(current_setting('opengym.queue_reordered',true),''))>0;
  if reorder then
    with w as (
      select id,row_number() over(order by queue_position nulls last,id) rn
        from public.waitlist_players
       where facility_id=p_facility_id and status in ('waiting','sitout')
    ), k as (
      select line_key,row_number() over(order by line_key) rn
        from public.waitlist_players
       where facility_id=p_facility_id and status in ('waiting','sitout')
    )
    update public.waitlist_players p set line_key=k.line_key
      from w join k on k.rn=w.rn
     where p.id=w.id and p.line_key is distinct from k.line_key;
    perform set_config('opengym.queue_reordered',
      replace(coalesce(current_setting('opengym.queue_reordered',true),''),p_facility_id::text||',',''),true);
  end if;

  -- 3c. Seat by line order, bumping provisional seats when needed -------------
  -- A seat is provisional while someone ahead of that player in line is still
  -- deciding, or while one of their group-mates is still deciding.
  loop
    pass:=pass+1;
    changed:=false;
    for court in
      select court_number from public.waitlist_courts
       where facility_id=p_facility_id order by court_number
    loop
      continue when public.is_hybrid_kotc_court(p_facility_id,court.court_number);

      select cfg.max_players-count(*) into seats
        from public.waitlist_players c
       where c.facility_id=p_facility_id and c.status='current' and c.court_number=court.court_number
         and not public.wl_seat_is_provisional(c.id);

      picked:='{}';

      -- A unit is a single or a whole group: its waiting members plus any
      -- provisional members. A group with a provisional member on another
      -- court is decided there, so it is never split across courts.
      for unit in
        select coalesce(p.group_id::text,p.id::text) as unit_id,count(*)::integer as size,
               bool_or(p.status='current' and p.court_number<>court.court_number) as elsewhere
          from public.waitlist_players p
         where p.facility_id=p_facility_id
           and ((p.status='current' and public.wl_seat_is_provisional(p.id))
             or (p.status='waiting' and p.id not in (select public.wl_active_substitute_ids(p_facility_id))))
         group by coalesce(p.group_id::text,p.id::text)
         order by bool_or(p.sitout_priority) desc,min(p.line_key) nulls last,min(p.id::text)
      loop
        exit when seats<=0;
        continue when unit.elsewhere or unit.size>seats;
        picked:=picked||array(
          select p.id from public.waitlist_players p
           where p.facility_id=p_facility_id
             and coalesce(p.group_id::text,p.id::text)=unit.unit_id
             and ((p.status='current' and p.court_number=court.court_number)
               or (p.status='waiting' and p.id not in (select public.wl_active_substitute_ids(p_facility_id)))));
        seats:=seats-unit.size;
      end loop;

      -- Provisional seats that lost out move back to the waitlist (spot kept).
      update public.waitlist_players p
         set status='waiting',court_number=null,updated_at=now()
       where p.facility_id=p_facility_id and p.status='current' and p.court_number=court.court_number
         and public.wl_seat_is_provisional(p.id)
         and not (p.id=any(picked));
      if found then changed:=true; end if;

      update public.waitlist_players p
         set status='current',court_number=court.court_number,sitout_priority=false,updated_at=now()
       where p.facility_id=p_facility_id and p.status='waiting'
         and p.id=any(picked);
      if found then changed:=true; end if;
    end loop;
    exit when not changed or pass>=4;
  end loop;

  select count(*) into seated from public.waitlist_players
   where facility_id=p_facility_id and status='current' and not (id=any(start_current));

  -- Keep line keys compact: repeated "insert halfway" placement eventually
  -- runs out of precision, so re-number them in order once they get long.
  if exists(select 1 from public.waitlist_players
             where facility_id=p_facility_id and status in ('current','waiting','sitout','rejoin')
               and line_key is not null and line_key<>round(line_key,6)) then
    with r as (
      select id,row_number() over(order by line_key nulls last,id) rn
        from public.waitlist_players
       where facility_id=p_facility_id and status in ('current','waiting','sitout','rejoin')
    )
    update public.waitlist_players p set line_key=r.rn from r
     where p.id=r.id and p.line_key is distinct from r.rn;
  end if;

  -- 3d. Display order -----------------------------------------------------------
  -- queue_position: current players first (by court, line order), then the
  -- waitlist in line order. Held spots show their place in the whole line
  -- (everyone ahead of them, including other held spots).
  with ranked as (
    select id,row_number() over(
      order by case when status='current' then 0 else 1 end,
               case when status='current' then court_number else 999 end,line_key nulls last,id) rn
      from public.waitlist_players
     where facility_id=p_facility_id and status in ('current','waiting','sitout')
  )
  update public.waitlist_players p set queue_position=ranked.rn
    from ranked
   where p.id=ranked.id and p.queue_position is distinct from ranked.rn;

  update public.waitlist_players p
     set queue_position=1+(select count(*) from public.waitlist_players q
                            where q.facility_id=p_facility_id
                              and q.status in ('current','waiting','sitout','rejoin')
                              and q.line_key<p.line_key)
   where p.facility_id=p_facility_id and p.status='rejoin' and p.line_key is not null;

  -- 3e. Tell players who were moved back to the waitlist ----------------------
  select f.slug into slug from public.facilities f where f.id=p_facility_id;
  for r in
    select p.id,p.user_id from public.waitlist_players p
     where p.facility_id=p_facility_id and p.status='waiting' and p.id=any(start_current)
  loop
    select 1+count(*) into waiting_rank from public.waitlist_players q
     where q.facility_id=p_facility_id and q.status in ('waiting','sitout')
       and q.line_key<(select line_key from public.waitlist_players where id=r.id);
    if r.user_id is not null then
      insert into public.group_notifications(facility_id,user_id,message)
      values(p_facility_id,r.user_id,
        'LINE_UPDATE|Moved to the waitlist|Players ahead of you rejoined. You''re now #'||waiting_rank||' on the waitlist.');
      insert into public.push_outbox(facility_id,user_id,notification)
      values(p_facility_id,r.user_id,jsonb_build_object(
        'title','Moved to the waitlist',
        'body','Players ahead of you rejoined. You''re now #'||waiting_rank||' on the waitlist.',
        'kind','line_update',
        'url',case when slug is null then '/' else '/g/'||slug end,
        'tag','open-gym-line-update'));
    end if;
  end loop;

  perform set_config('opengym.in_allocator','',true);
  return seated;
end;
$$;

alter function public.fill_facility_open_slots(uuid,boolean) owner to opengym_runtime;
revoke all on function public.fill_facility_open_slots(uuid,boolean) from public, anon, authenticated;

CREATE OR REPLACE FUNCTION public.swap_waitlist_players(p_first_id uuid, p_second_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
declare first_player public.waitlist_players; second_player public.waitlist_players; first_group uuid; second_group uuid; member_count integer; status_count integer; court_count integer; position_span bigint; fid uuid:=public.current_facility_id();
begin
if fid is null then raise exception 'Select a facility first.'; end if;
select * into first_player from public.waitlist_players where facility_id=fid and id=p_first_id and status in ('current','waiting','sitout') for update;
select * into second_player from public.waitlist_players where facility_id=fid and id=p_second_id and status in ('current','waiting','sitout') for update;
if first_player.id is null or second_player.id is null then raise exception 'Both players must still be in the current game or waitlist.'; end if; if first_player.id=second_player.id then raise exception 'Choose two different players.'; end if;
first_group:=first_player.group_id; second_group:=second_player.group_id;
update public.waitlist_players set status=case when id=first_player.id then second_player.status else first_player.status end,queue_position=case when id=first_player.id then second_player.queue_position else first_player.queue_position end,line_key=case when id=first_player.id then second_player.line_key else first_player.line_key end,court_number=case when id=first_player.id then second_player.court_number else first_player.court_number end,team_id=case when id=first_player.id then second_player.team_id else first_player.team_id end,sitout_priority=case when id=first_player.id then second_player.sitout_priority else first_player.sitout_priority end,sitout_from_game=case when id=first_player.id then second_player.sitout_from_game else first_player.sitout_from_game end,updated_at=now() where facility_id=fid and id in(first_player.id,second_player.id);
if first_group is not null and first_group is distinct from second_group then select count(*),count(distinct status),count(distinct coalesce(court_number,0)),max(queue_position)-min(queue_position)+1 into member_count,status_count,court_count,position_span from public.waitlist_players where facility_id=fid and group_id=first_group; if member_count<2 or status_count<>1 or court_count<>1 or position_span<>member_count then update public.waitlist_players set group_id=null,updated_at=now() where facility_id=fid and id=first_player.id; end if; end if;
if second_group is not null and second_group is distinct from first_group then select count(*),count(distinct status),count(distinct coalesce(court_number,0)),max(queue_position)-min(queue_position)+1 into member_count,status_count,court_count,position_span from public.waitlist_players where facility_id=fid and group_id=second_group; if member_count<2 or status_count<>1 or court_count<>1 or position_span<>member_count then update public.waitlist_players set group_id=null,updated_at=now() where facility_id=fid and id=second_player.id; end if; end if;
if first_group is not null and (select count(*) from public.waitlist_players where facility_id=fid and group_id=first_group)<=1 then update public.waitlist_players set group_id=null,updated_at=now() where facility_id=fid and group_id=first_group; end if;
if second_group is not null and second_group is distinct from first_group and (select count(*) from public.waitlist_players where facility_id=fid and group_id=second_group)<=1 then update public.waitlist_players set group_id=null,updated_at=now() where facility_id=fid and group_id=second_group; end if;
insert into public.waitlist_events(facility_id,actor_user_id,actor_name,event_type,message) select fid,p.user_id,p.display_name,'substitute',p.display_name||' swapped positions with '||case when p.id=first_player.id then second_player.display_name else first_player.display_name end||'.' from public.waitlist_players p where p.facility_id=fid and p.id in(first_player.id,second_player.id) and p.user_id is not null;
end $function$;

alter function public.swap_waitlist_players(uuid,uuid) owner to opengym_runtime;

CREATE OR REPLACE FUNCTION public.admin_move_player(p_player_id uuid, p_status text, p_index integer, p_court_number integer)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
declare player public.waitlist_players; source_court integer; destination_court integer; moving_count integer;
v_max_players integer; target_position bigint; open_spots integer; candidate record; fid uuid:=public.current_facility_id();
begin
perform public.lock_facility(); /* per-facility lock (audit L2/L3) */

if fid is null or not public.is_waitlist_operator() then raise exception 'Admin or host access required.'; end if;
if p_status not in ('current','waiting') then raise exception 'Invalid destination.'; end if;
perform public.lock_facility();
select * into player from public.waitlist_players where facility_id=fid and id=p_player_id for update;
if player.id is null then raise exception 'Player not found.'; end if;
source_court:=player.court_number; destination_court:=case when p_status='current' then coalesce(p_court_number,source_court,1) else null end;
select max_players into v_max_players from public.waitlist_config where facility_id=fid and id;
select count(*) into moving_count from public.waitlist_players where facility_id=fid and (id=player.id or (player.group_id is not null and group_id=player.group_id));
if moving_count>v_max_players then raise exception 'This group is larger than a court.'; end if;
perform public.save_admin_undo('move player');
update public.waitlist_players set queue_position=queue_position*1000 where facility_id=fid and status in ('current','waiting','sitout') and queue_position is not null;
if p_status='waiting' then
select queue_position into target_position from public.waitlist_players where facility_id=fid and status in ('waiting','sitout') and id<>player.id and (player.group_id is null or group_id is distinct from player.group_id) order by queue_position offset greatest(p_index,0) limit 1;
if target_position is null then select coalesce(max(queue_position),0)+1000 into target_position from public.waitlist_players where facility_id=fid and status in ('current','waiting','sitout'); end if;
with moving as (select id,row_number() over(order by queue_position,id) rn from public.waitlist_players where facility_id=fid and (id=player.id or (player.group_id is not null and group_id=player.group_id)))
update public.waitlist_players p set status='waiting',court_number=null,queue_position=target_position-moving_count+moving.rn-1,updated_at=now() from moving where p.facility_id=fid and p.id=moving.id;
else
select queue_position into target_position from public.waitlist_players where facility_id=fid and status='current' and court_number=destination_court and id<>player.id and (player.group_id is null or group_id is distinct from player.group_id) order by queue_position offset greatest(p_index,0) limit 1;
if target_position is null then select coalesce(max(queue_position),0)+1000 into target_position from public.waitlist_players where facility_id=fid and status='current' and court_number=destination_court; end if;
with moving as (select id,row_number() over(order by queue_position,id) rn from public.waitlist_players where facility_id=fid and (id=player.id or (player.group_id is not null and group_id=player.group_id)))
update public.waitlist_players p set status='current',court_number=destination_court,sitout_priority=false,queue_position=target_position-moving_count+moving.rn-1,updated_at=now() from moving where p.facility_id=fid and p.id=moving.id;
-- Overflow: push out the last players who were already on the court, never
-- a member of the group that was just moved in (keeps groups together).
with ranked as (select id,row_number() over(order by case when id=player.id or (player.group_id is not null and group_id=player.group_id) then 0 else 1 end,queue_position,id) rn from public.waitlist_players where facility_id=fid and status='current' and court_number=destination_court), displaced as (select p.id,row_number() over(order by p.queue_position,p.id) rn from public.waitlist_players p join ranked r on r.id=p.id where p.facility_id=fid and r.rn>v_max_players), queue_head as (select coalesce(min(queue_position),1000000) head from public.waitlist_players where facility_id=fid and status in ('waiting','sitout'))
update public.waitlist_players p set status='waiting',court_number=null,queue_position=queue_head.head-moving_count+displaced.rn-1,updated_at=now() from displaced cross join queue_head where p.facility_id=fid and p.id=displaced.id;
end if;
if source_court is not null and source_court is distinct from destination_court then
select greatest(v_max_players-count(p.id),0) into open_spots from public.waitlist_config cfg left join public.waitlist_players p on p.facility_id=fid and p.status='current' and p.court_number=source_court where cfg.facility_id=fid and cfg.id group by cfg.max_players;
for candidate in select coalesce(group_id,id) block_id,count(*)::integer block_size from public.waitlist_players where facility_id=fid and status='waiting' and id<>player.id and (player.group_id is null or group_id is distinct from player.group_id) group by coalesce(group_id,id) order by min(queue_position) loop
if candidate.block_size<=open_spots then update public.waitlist_players set status='current',court_number=source_court,sitout_priority=false,updated_at=now() where facility_id=fid and status='waiting' and coalesce(group_id,id)=candidate.block_id; open_spots:=open_spots-candidate.block_size; end if;
exit when open_spots=0;
end loop;
end if;
with ranked as (select id,row_number() over(order by case when status='current' then 0 else 1 end,coalesce(court_number,999),queue_position,id) rn from public.waitlist_players where facility_id=fid and status in ('current','waiting','sitout') and queue_position is not null)
update public.waitlist_players p set queue_position=ranked.rn from ranked where p.facility_id=fid and p.id=ranked.id;
return jsonb_build_object('message','Player moved.','source_court',source_court,'destination_court',destination_court);
end $function$;

alter function public.admin_move_player(uuid,text,integer,integer) owner to opengym_runtime;

notify pgrst, 'reload schema';
commit;
