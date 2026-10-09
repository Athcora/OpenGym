-- Held rejoin spots.
--
-- When a game ends, the players who just finished keep their place in line in
-- the order they finished, no matter who taps Rejoin first:
--   * Their spots are held (status 'rejoin') in a hidden line key.
--   * Someone who joins while they are deciding goes ahead of the players who
--     have not tapped yet, but never ahead of a player behind them who already
--     tapped (so the old order is kept).
--   * Seats follow line order. A player who taps early is seated right away,
--     but the seat is provisional while anyone ahead of them in line (or a
--     group-mate) has not answered. When someone ahead taps, the last
--     provisional player on that court moves back to the front of the
--     waitlist and gets an in-app popup + push notification.
--   * Groups: a member who rejoins alone plays as a single. When the rest of
--     the group rejoins they are grouped again; if the whole group no longer
--     fits, they all wait together and the next single takes the seat.
--   * Once nobody ahead of a player is still deciding, their seat is final.
--
-- Fixes the old bug where pending rejoiners were left out of renumbering, so
-- people who joined later could end up ahead of them.
begin;

alter table public.waitlist_players add column if not exists line_key numeric;
alter table public.waitlist_players add column if not exists rejoin_returning boolean not null default false;
comment on column public.waitlist_players.rejoin_returning is
  'True from tapping Rejoin until the player is seated or leaves; a seated group-mate stays provisional until this player is placed too.';
comment on column public.waitlist_players.line_key is
  'True order of the line, including held rejoin spots. Maintained by fill_facility_open_slots(); queue_position is the display order derived from it.';

update public.waitlist_players
   set line_key=queue_position
 where line_key is null and status in ('current','waiting','sitout','rejoin') and queue_position is not null;

-- 1. Finishers keep their order at the back of the line ----------------------
-- end_court_game (and the KOTC advance) first renumbers the finishing players
-- to the back in game order, then flips them to 'rejoin' (or 'waiting' in
-- regular mode). Give them line keys behind everyone else in that order.
create or replace function public.wl_line_keys_after_update()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
begin
  -- Our own line_key updates fire this statement trigger again.
  if pg_trigger_depth()>1 or coalesce(current_setting('opengym.in_allocator',true),'')='1' then
    return null;
  end if;

  with moved as (
    select n.id,n.facility_id,n.queue_position
      from new_rows n join old_rows o on o.id=n.id
     where o.status='current' and n.status in ('rejoin','waiting')
       and n.queue_position is not null
       -- appended behind everyone still active = finished a game
       and n.queue_position>(
         select coalesce(max(p.queue_position),0) from public.waitlist_players p
          where p.facility_id=n.facility_id
            and p.status in ('current','waiting','sitout','rejoin')
            and p.id not in (select x.id from new_rows x join old_rows y on y.id=x.id
                              where y.status='current' and x.status in ('rejoin','waiting')))
  ), base as (
    select m.facility_id,coalesce(max(p.line_key),0) as top
      from (select distinct facility_id from moved) m
      left join public.waitlist_players p
        on p.facility_id=m.facility_id
       and p.status in ('current','waiting','sitout','rejoin')
       and p.id not in (select id from moved)
     group by m.facility_id
  ), ranked as (
    select m.id,b.top+row_number() over(partition by m.facility_id order by m.queue_position,m.id) as k
      from moved m join base b on b.facility_id=m.facility_id
  )
  update public.waitlist_players p set line_key=r.k from ranked r where p.id=r.id;

  -- Players who leave lose their spot.
  update public.waitlist_players p
     set line_key=null
    from new_rows n join old_rows o on o.id=n.id
   where p.id=n.id and n.status='left' and o.status<>'left' and p.line_key is not null;

  return null;
end;
$$;

alter function public.wl_line_keys_after_update() owner to opengym_runtime;
revoke all on function public.wl_line_keys_after_update() from public, anon, authenticated;

drop trigger if exists waitlist_players_line_keys on public.waitlist_players;
create trigger waitlist_players_line_keys
  after update on public.waitlist_players
  referencing old table as old_rows new table as new_rows
  for each statement execute function public.wl_line_keys_after_update();

-- 2. Explicit reorders (admin moves, swaps, undo) win -------------------------
-- When something other than the allocator changes a waiting player's
-- queue_position without changing their status, the allocator adopts that
-- order on its next run.
create or replace function public.wl_flag_queue_reorder()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
begin
  if coalesce(current_setting('opengym.in_allocator',true),'')<>'1'
     and new.status=old.status and new.status in ('waiting','sitout')
     and new.queue_position is distinct from old.queue_position then
    perform set_config('opengym.queue_reordered',
      coalesce(current_setting('opengym.queue_reordered',true),'')||new.facility_id::text||',',true);
  end if;
  return new;
end;
$$;

alter function public.wl_flag_queue_reorder() owner to opengym_runtime;
revoke all on function public.wl_flag_queue_reorder() from public, anon, authenticated;

drop trigger if exists waitlist_players_flag_reorder on public.waitlist_players;
create trigger waitlist_players_flag_reorder
  before update of queue_position on public.waitlist_players
  for each row execute function public.wl_flag_queue_reorder();

-- 3. The allocator ----------------------------------------------------------
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

      for unit in
        select coalesce(p.group_id::text,p.id::text) as unit_id,count(*)::integer as size
          from public.waitlist_players p
         where p.facility_id=p_facility_id
           and ((p.status='current' and p.court_number=court.court_number and public.wl_seat_is_provisional(p.id))
             or (p.status='waiting' and p.id not in (select public.wl_active_substitute_ids(p_facility_id))))
         group by coalesce(p.group_id::text,p.id::text)
         order by bool_or(p.sitout_priority) desc,min(p.line_key) nulls last,min(p.id::text)
      loop
        exit when seats<=0;
        continue when unit.size>seats;
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

  -- 3d. Display order -----------------------------------------------------------
  -- queue_position: current players first (by court, line order), then the
  -- waitlist in line order. Held spots show their place in the whole line
  -- (everyone ahead of them, including other held spots).
  with ranked as (
    select id,row_number() over(
      order by case when status='current' then 0 else 1 end,
               coalesce(court_number,999),line_key nulls last,id) rn
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

-- Track players who just tapped Rejoin until they are placed.
create or replace function public.wl_mark_rejoin_returning()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
begin
  if old.status='rejoin' and new.status='waiting' then
    new.rejoin_returning:=true;
  elsif new.status<>'waiting' then
    new.rejoin_returning:=false;
  end if;
  return new;
end;
$$;

alter function public.wl_mark_rejoin_returning() owner to opengym_runtime;
revoke all on function public.wl_mark_rejoin_returning() from public, anon, authenticated;

drop trigger if exists waitlist_players_mark_rejoin_returning on public.waitlist_players;
create trigger waitlist_players_mark_rejoin_returning
  before update of status on public.waitlist_players
  for each row execute function public.wl_mark_rejoin_returning();

-- Helper: is this current player's seat still provisional?
create or replace function public.wl_seat_is_provisional(p_player_id uuid)
returns boolean
language sql
stable
security definer
set search_path=public
as $$
  select exists(
    select 1 from public.waitlist_players me
      join public.waitlist_players held
        on held.facility_id=me.facility_id and held.status='rejoin'
     where me.id=p_player_id and me.status='current'
       and ((held.line_key is not null and me.line_key is not null and held.line_key<me.line_key)
         or (me.group_id is not null and held.group_id=me.group_id)))
  or exists(
    select 1 from public.waitlist_players me
      join public.waitlist_players mate
        on mate.facility_id=me.facility_id and mate.group_id=me.group_id and mate.id<>me.id
     where me.id=p_player_id and me.status='current' and me.group_id is not null
       and mate.status='waiting' and mate.rejoin_returning)
$$;

alter function public.wl_seat_is_provisional(uuid) owner to opengym_runtime;
revoke all on function public.wl_seat_is_provisional(uuid) from public, anon, authenticated;

alter function public.fill_facility_open_slots(uuid,boolean) owner to opengym_runtime;
revoke all on function public.fill_facility_open_slots(uuid,boolean) from public, anon, authenticated;

-- normalize_active_waitlist(): the allocator now owns renumbering.
create or replace function public.normalize_active_waitlist()
returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  fid uuid:=public.current_facility_id();
begin
  if fid is null then
    raise exception 'Select a facility first.';
  end if;
  if not exists(select 1 from public.waitlist_config where facility_id=fid and id) then
    raise exception 'Facility configuration not found.';
  end if;
  perform public.fill_facility_open_slots(fid,true);
end;
$$;

alter function public.normalize_active_waitlist() owner to opengym_runtime;

-- Refill / re-rank after queue_position changes too.
drop trigger if exists waitlist_players_autofill on public.waitlist_players;
create constraint trigger waitlist_players_autofill
  after insert or delete or update of status,court_number,group_id,sitout_priority,facility_id,queue_position
  on public.waitlist_players
  deferrable initially deferred
  for each row execute function public.wl_autofill_after_change();

-- 4. Rejoin answers keep the held spot -------------------------------------------
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
    ' at #'||court_spot||'. Players ahead of you can still rejoin, so you may move back.');
end if;
return jsonb_build_object('message',case when joined_current then 'You rejoined the current game.' else 'You kept your saved position in line.' end);
end;
$function$;

alter function public.answer_rejoin_prompt(uuid,text) owner to opengym_runtime;

create or replace function public.admin_answer_offline_rejoin(p_player_id uuid, p_stay boolean)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
player public.waitlist_players;
restored public.waitlist_players;
fid uuid:=public.current_facility_id();
begin
perform public.lock_facility(); /* per-facility lock (audit L2/L3) */
if not public.is_waitlist_operator() then raise exception 'Admin or host access required.'; end if;
select * into player from public.waitlist_players
where id=p_player_id and facility_id=fid and user_id is null and status='rejoin' for update;
if player.id is null then raise exception 'This rejoin request is no longer available.'; end if;
if player.rejoin_expires_at<=now() then
update public.waitlist_players set status='left',queue_position=null,rejoin_expires_at=null,updated_at=now()
where id=player.id and facility_id=fid;
raise exception 'The 15-minute rejoin window has expired.';
end if;
perform public.save_admin_undo(case when p_stay then 'rejoin player' else 'remove rejoin player' end);
-- Rejoining keeps the held spot (line_key); leaving gives it up.
update public.waitlist_players
set status=case when p_stay then 'waiting' else 'left' end,
court_number=null,
queue_position=case when p_stay then player.queue_position else null end,
rejoin_expires_at=null,
updated_at=now()
where id=player.id and facility_id=fid;
if not p_stay then
return jsonb_build_object('message',player.display_name||' was removed.');
end if;
perform public.fill_open_court_slots();
select * into restored from public.waitlist_players where id=player.id and facility_id=fid;
perform public.log_waitlist_operator_action(
'admin_rejoin',
'returned '||player.display_name||case when restored.status='current' then ' to Court '||restored.court_number||'.' else ' to their saved queue position.' end
);
return jsonb_build_object(
'message',
case when restored.status='current' then player.display_name||' rejoined Court '||restored.court_number||'.' else player.display_name||' rejoined at their saved position.' end
);
end; $function$;

alter function public.admin_answer_offline_rejoin(uuid,boolean) owner to opengym_runtime;

-- 5. Admin/host list of everyone still deciding --------------------------------
create or replace function public.admin_list_pending_rejoins()
returns table(id uuid, display_name text, queue_position bigint, expires_at timestamptz, offline boolean)
language plpgsql
security definer
set search_path to 'public'
as $function$
declare fid uuid:=public.current_facility_id();
begin
perform public.lock_facility();
if not public.is_waitlist_operator() then raise exception 'Admin or host access required.'; end if;
update public.waitlist_players set status='left',queue_position=null,rejoin_expires_at=null,updated_at=now()
 where facility_id=fid and user_id is null and status='rejoin' and rejoin_expires_at<=now();
return query
  select p.id,p.display_name,p.queue_position::bigint,p.rejoin_expires_at,(p.user_id is null)
    from public.waitlist_players p
   where p.facility_id=fid and p.status='rejoin' and p.rejoin_expires_at>now()
   order by p.line_key nulls last,p.queue_position;
end; $function$;

alter function public.admin_list_pending_rejoins() owner to opengym_runtime;
revoke all on function public.admin_list_pending_rejoins() from public, anon;
grant execute on function public.admin_list_pending_rejoins() to authenticated;

notify pgrst, 'reload schema';
commit;
