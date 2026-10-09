-- Line spots: one number per person while finishers decide.
--
-- During the rejoin window, an early tapper (provisional seat) was shown their
-- court position (e.g. #6) while the finisher ahead of them who had not tapped
-- yet was shown "Your spot (#6) is held". Players waiting behind a held spot
-- could likewise share a number with it.
--
-- The allocator now writes line_spot while any held spot exists: everyone
-- not definitely playing (held spots, early tappers on provisional seats, the
-- waitlist) is numbered in line order right after the players who are
-- definitely playing. Otherwise line_spot is NULL and players see their
-- normal court / waitlist position. The "You rejoined" popup and the
-- "Moved to the waitlist" message use the same number the list shows.
begin;

alter table public.waitlist_players
  add column if not exists line_spot integer;

comment on column public.waitlist_players.line_spot is
  'Place in the whole line (held rejoin spots included) while finishers are still deciding. NULL = show the normal position.';

-- waitlist_players uses column-level grants: the app reads this column.
grant select (line_spot) on public.waitlist_players to anon, authenticated;

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
               case when status='current' then court_number else 999 end,
               case when status='current' and public.wl_seat_is_provisional(id) then 1 else 0 end,
               line_key nulls last,id) rn
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

  -- Line spots: while finishers are still deciding (any held spot exists),
  -- everyone who is not definitely playing -- held spots, early tappers on a
  -- provisional seat, and the waitlist -- is numbered in line order right
  -- after the players who are definitely playing. So no two people are ever
  -- shown the same number. NULL = show the normal court / waitlist position.
  if exists(select 1 from public.waitlist_players
             where facility_id=p_facility_id and status='rejoin') then
    with firm as (
      select count(*)::integer n from public.waitlist_players c
       where c.facility_id=p_facility_id and c.status='current'
         and not public.wl_seat_is_provisional(c.id)
    ), pending as (
      select p.id,row_number() over(order by p.line_key nulls last,p.id)::integer rn
        from public.waitlist_players p
       where p.facility_id=p_facility_id
         and (p.status in ('rejoin','waiting','sitout')
           or (p.status='current' and public.wl_seat_is_provisional(p.id)))
    ), spots as (
      select p.id,case when pending.id is null then null else firm.n+pending.rn end spot
        from public.waitlist_players p
        cross join firm
        left join pending on pending.id=p.id
       where p.facility_id=p_facility_id
         and (p.status in ('current','waiting','sitout','rejoin') or p.line_spot is not null)
    )
    update public.waitlist_players p set line_spot=spots.spot
      from spots
     where p.id=spots.id and p.line_spot is distinct from spots.spot;
    -- Held spots show the same number everywhere (rejoin screen, admin list).
    update public.waitlist_players set queue_position=line_spot
     where facility_id=p_facility_id and status='rejoin'
       and line_spot is not null and queue_position is distinct from line_spot;
  else
    update public.waitlist_players set line_spot=null
     where facility_id=p_facility_id and line_spot is not null;
  end if;

  -- 3e. Tell players who were moved back to the waitlist ----------------------
  select f.slug into slug from public.facilities f where f.id=p_facility_id;
  for r in
    select p.id,p.user_id from public.waitlist_players p
     where p.facility_id=p_facility_id and p.status='waiting' and p.id=any(start_current)
  loop
    -- The number shown on their row: their line spot, or else the normal
    -- waitlist numbering (which starts right after a full court).
    select coalesce(
             (select line_spot from public.waitlist_players where id=r.id),
             cfg.max_players+1+count(*))::integer into waiting_rank
      from public.waitlist_players q
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

create or replace function public.answer_rejoin_prompt(p_response_id uuid, p_choice text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare prompt public.rejoin_responses; player public.waitlist_players; team public.king_teams;
config public.waitlist_config; joined_current boolean; me public.waitlist_players; court_spot integer;
fid uuid:=public.current_facility_id();
begin
perform public.lock_facility(); /* per-facility lock (audit L2/L3) */
if p_choice not in('stay','leave') then raise exception 'Choose rejoin or leave.'; end if;
select * into prompt from public.rejoin_responses where id=p_response_id and user_id=public.current_request_user_id() and facility_id=fid for update;
select * into player from public.waitlist_players where facility_id=fid and user_id=public.current_request_user_id() for update;
if prompt.id is null or player.id is null then raise exception 'Rejoin request not found for this facility.'; end if;
if prompt.choice is not null then raise exception 'This rejoin request was already answered.'; end if;
if prompt.expires_at<=now() then p_choice:='leave'; end if;
update public.rejoin_responses set choice=p_choice,answered_at=now() where id=prompt.id and facility_id=fid;
if p_choice='leave' then
update public.waitlist_players set status='left',queue_position=null,team_id=null,court_number=null,rejoin_expires_at=null,updated_at=now() where id=player.id and facility_id=fid;
perform public.cleanup_king_rejoin_expirations();
return jsonb_build_object('message','You left the waitlist.');
end if;
select * into config from public.waitlist_config where facility_id=fid and id for update;
if config.id is null then raise exception 'Facility configuration not found.'; end if;
if config.mode='hybrid_waitlist' and config.hybrid_rotation_rule='kotc' then
update public.waitlist_players set status='waiting',court_number=null,team_id=null,
queue_position=prompt.original_position,rejoin_expires_at=null,updated_at=now()
where id=player.id and facility_id=fid;
return jsonb_build_object('message','You kept your saved position for the next Waitlist KOTC game.');
end if;
if player.team_id is not null then select * into team from public.king_teams where id=player.team_id and facility_id=fid for update; end if;
if team.id is not null then
update public.king_teams set rejoin_expires_at=null,updated_at=now() where id=team.id and facility_id=fid;
update public.waitlist_players set status=team.status,court_number=team.court_number,rejoin_expires_at=null,updated_at=now() where id=player.id and facility_id=fid;
perform public.king_fill_courts();
select * into team from public.king_teams where id=player.team_id and facility_id=fid;
update public.waitlist_players set status=team.status,court_number=team.court_number,updated_at=now() where id=player.id and facility_id=fid;
return jsonb_build_object('message','You rejoined your team in its saved position.');
end if;
-- Keep the held spot (line_key); the allocator seats by line order.
update public.waitlist_players set status='waiting',rejoin_expires_at=null,updated_at=now() where id=player.id and facility_id=fid;
perform public.fill_open_court_slots();
select * into me from public.waitlist_players where id=player.id and facility_id=fid;
joined_current:=me.status='current';
if joined_current and public.wl_seat_is_provisional(me.id) and me.user_id is not null then
  select 1+count(*) into court_spot from public.waitlist_players q
   where q.facility_id=fid and q.status='current' and q.court_number=me.court_number and q.queue_position<me.queue_position;
  insert into public.group_notifications(facility_id,user_id,message)
  values(fid,me.user_id,'LINE_UPDATE|You rejoined|You''re in Game '||
    coalesce((select game_number from public.waitlist_courts where facility_id=fid and court_number=me.court_number),config.game_number)||
    ' at #'||coalesce(me.line_spot,court_spot)||'. Players ahead of you can still rejoin, so you may move back.');
end if;
return jsonb_build_object('message',case when joined_current then 'You rejoined the current game.' else 'You kept your saved position in line.' end);
end;
$function$;

alter function public.answer_rejoin_prompt(uuid,text) owner to opengym_runtime;

-- Dragging a group member only moves group-mates who are still in line.
-- Members who left (or are still deciding on a held spot) keep their group_id
-- and were being pulled back onto the court with the group.
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
select count(*) into moving_count from public.waitlist_players where facility_id=fid and (id=player.id or (player.group_id is not null and group_id=player.group_id and status in ('current','waiting','sitout')));
if moving_count>v_max_players then raise exception 'This group is larger than a court.'; end if;
perform public.save_admin_undo('move player');
update public.waitlist_players set queue_position=queue_position*1000 where facility_id=fid and status in ('current','waiting','sitout') and queue_position is not null;
if p_status='waiting' then
select queue_position into target_position from public.waitlist_players where facility_id=fid and status in ('waiting','sitout') and id<>player.id and (player.group_id is null or group_id is distinct from player.group_id) order by queue_position offset greatest(p_index,0) limit 1;
if target_position is null then select coalesce(max(queue_position),0)+1000 into target_position from public.waitlist_players where facility_id=fid and status in ('current','waiting','sitout'); end if;
with moving as (select id,row_number() over(order by queue_position,id) rn from public.waitlist_players where facility_id=fid and (id=player.id or (player.group_id is not null and group_id=player.group_id and status in ('current','waiting','sitout'))))
update public.waitlist_players p set status='waiting',court_number=null,queue_position=target_position-moving_count+moving.rn-1,updated_at=now() from moving where p.facility_id=fid and p.id=moving.id;
else
select queue_position into target_position from public.waitlist_players where facility_id=fid and status='current' and court_number=destination_court and id<>player.id and (player.group_id is null or group_id is distinct from player.group_id) order by queue_position offset greatest(p_index,0) limit 1;
if target_position is null then select coalesce(max(queue_position),0)+1000 into target_position from public.waitlist_players where facility_id=fid and status='current' and court_number=destination_court; end if;
with moving as (select id,row_number() over(order by queue_position,id) rn from public.waitlist_players where facility_id=fid and (id=player.id or (player.group_id is not null and group_id=player.group_id and status in ('current','waiting','sitout'))))
update public.waitlist_players p set status='current',court_number=destination_court,sitout_priority=false,queue_position=target_position-moving_count+moving.rn-1,updated_at=now() from moving where p.facility_id=fid and p.id=moving.id;
-- Overflow: push out the last players who were already on the court, never
-- a member of the group that was just moved in (keeps groups together).
with ranked as (select id,row_number() over(order by case when id=player.id or (player.group_id is not null and group_id=player.group_id and status in ('current','waiting','sitout')) then 0 else 1 end,queue_position,id) rn from public.waitlist_players where facility_id=fid and status='current' and court_number=destination_court), displaced as (select p.id,row_number() over(order by p.queue_position,p.id) rn from public.waitlist_players p join ranked r on r.id=p.id where p.facility_id=fid and r.rn>v_max_players), queue_head as (select coalesce(min(queue_position),1000000) head from public.waitlist_players where facility_id=fid and status in ('waiting','sitout'))
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

update public.waitlist_players set line_spot=null where line_spot is not null;
do $$
declare f record;
begin
  for f in select facility_id from public.waitlist_config where id loop
    perform set_config('opengym.facility_override',f.facility_id::text,true);
    perform public.fill_facility_open_slots(f.facility_id,true);
  end loop;
  perform set_config('opengym.facility_override','',true);
end $$;

notify pgrst, 'reload schema';
commit;
