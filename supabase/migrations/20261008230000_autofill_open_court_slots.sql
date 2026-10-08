-- Keep every open court seat filled from the waitlist.
--
-- Rule: while a non-KOTC court has fewer than max_players `current` players
-- and someone eligible is `waiting`, seat them. Sitting-out (`sitout`) and
-- pending-rejoin (`rejoin`) players are not `waiting`, so they are never pulled.
--
-- Groups: a group that does not fit the open seats is skipped (it keeps its
-- place in line) and the singles/smaller groups behind it are seated. Groups
-- are never split.
--
-- Before this migration fill_open_court_slots() stopped at the first group that
-- did not fit, leaving singles stuck behind it, and several actions (remove,
-- restrict, move, rejoin-at-back, undo/reverse, max-players changes) never
-- refilled at all. A deferred constraint trigger now re-runs the allocator once
-- per facility at the end of any transaction that changes the roster, so no
-- code path can leave an open seat behind.
begin;

-- 1. Facility-parameterised allocator --------------------------------------
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
  open_spots integer;
  seated integer:=0;
  n integer;
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

  for court in
    select court_number from public.waitlist_courts
    where facility_id=p_facility_id
    order by court_number
  loop
    -- Legacy hybrid KOTC courts are owned by hybrid_kotc_slots.
    continue when public.is_hybrid_kotc_court(p_facility_id,court.court_number);

    select greatest(cfg.max_players-count(*),0)::integer
      into open_spots
      from public.waitlist_players
     where facility_id=p_facility_id and status='current' and court_number=court.court_number;

    continue when open_spots=0;

    for unit in
      select p.group_id,
             case when p.group_id is null then p.id end as member_id,
             count(*)::integer as member_count
        from public.waitlist_players p
       where p.facility_id=p_facility_id
         and p.status='waiting'
         and p.id not in (select public.wl_active_substitute_ids(p_facility_id))
       group by p.group_id, case when p.group_id is null then p.id end
       order by bool_or(p.sitout_priority) desc,
                min(p.queue_position) nulls last,
                min(p.id::text)
    loop
      -- Too big for the open seats: skip, keep its place, try the next unit.
      continue when unit.member_count>open_spots;

      update public.waitlist_players p
         set status='current',court_number=court.court_number,sitout_priority=false,updated_at=now()
       where p.facility_id=p_facility_id
         and p.status='waiting'
         and ((unit.group_id is not null and p.group_id=unit.group_id)
           or (unit.group_id is null and p.id=unit.member_id));
      get diagnostics n=row_count;

      open_spots:=open_spots-n;
      seated:=seated+n;
      exit when open_spots<=0;
    end loop;
  end loop;

  if p_always_renumber or seated>0 then
    with ranked as (
      select id,row_number() over(
        order by case when status='current' then 0 else 1 end,
                 coalesce(court_number,999),queue_position,id) rn
        from public.waitlist_players
       where facility_id=p_facility_id and status in('current','waiting') and queue_position is not null
    )
    update public.waitlist_players p
       set queue_position=ranked.rn
      from ranked
     where p.facility_id=p_facility_id and p.id=ranked.id and p.queue_position is distinct from ranked.rn;
  end if;

  return seated;
end;
$$;

alter function public.fill_facility_open_slots(uuid,boolean) owner to opengym_runtime;
revoke all on function public.fill_facility_open_slots(uuid,boolean) from public, anon, authenticated;

-- 2. Existing entry point now uses the skip-don't-block allocator ----------
create or replace function public.fill_open_court_slots()
returns void
language plpgsql
security definer
set search_path=public
as $$
begin
  perform public.lock_facility(); /* per-facility lock (audit L2/L3) */
  perform public.fill_facility_open_slots(public.current_facility_id(),true);
end;
$$;

alter function public.fill_open_court_slots() owner to opengym_runtime;
revoke all on function public.fill_open_court_slots() from public, anon;
grant execute on function public.fill_open_court_slots() to authenticated;

-- normalize_active_waitlist() (leave / sit out / geofence paths) used to split
-- a group that did not fit. Same rule everywhere now: skip, never split.
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

  perform public.fill_facility_open_slots(fid,false);

  with ranked as (
    select id,row_number() over(order by queue_position,id) rn
      from public.waitlist_players
     where facility_id=fid and status in ('current','waiting','sitout') and queue_position is not null
  )
  update public.waitlist_players p
     set queue_position=ranked.rn
    from ranked
   where p.facility_id=fid and p.id=ranked.id;
end;
$$;

alter function public.normalize_active_waitlist() owner to opengym_runtime;

-- 3. Safety net: refill at commit after any roster change -------------------
create or replace function public.wl_autofill_after_change()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
declare
  fid uuid;
  done text;
begin
  if tg_table_name='waitlist_players' then
    fid:=coalesce(case when tg_op='DELETE' then null else new.facility_id end, old.facility_id);
  else
    fid:=case when tg_op='DELETE' then old.facility_id else new.facility_id end;
  end if;
  if fid is null then
    return null;
  end if;

  -- Run once per facility per transaction. All deferred triggers fire at
  -- commit, after every statement, so the first run already sees final state;
  -- rows the allocator itself updates re-queue this trigger and are skipped.
  done:=coalesce(current_setting('opengym.autofill_done',true),'');
  if position(fid::text in done)>0 then
    return null;
  end if;
  perform set_config('opengym.autofill_done',done||fid::text||',',true);

  -- waitlist_players has a restrictive facility_isolation RLS policy keyed on
  -- current_facility_id(). Request-less callers (cron, SQL editor) have no
  -- facility session, so point the override at this row's facility.
  if public.current_facility_id() is distinct from fid then
    perform set_config('opengym.facility_override',fid::text,true);
  end if;

  begin
    perform public.lock_facility(fid);
    perform public.fill_facility_open_slots(fid,false);
  exception when others then
    -- Never fail the user's action because of the safety net.
    raise warning 'autofill skipped for facility %: %',fid,sqlerrm;
  end;
  return null;
end;
$$;

alter function public.wl_autofill_after_change() owner to opengym_runtime;
revoke all on function public.wl_autofill_after_change() from public, anon, authenticated;

drop trigger if exists waitlist_players_autofill on public.waitlist_players;
create constraint trigger waitlist_players_autofill
  after insert or delete or update of status,court_number,group_id,sitout_priority,facility_id
  on public.waitlist_players
  deferrable initially deferred
  for each row execute function public.wl_autofill_after_change();

drop trigger if exists waitlist_config_autofill on public.waitlist_config;
create constraint trigger waitlist_config_autofill
  after update of max_players,mode,court_count
  on public.waitlist_config
  deferrable initially deferred
  for each row execute function public.wl_autofill_after_change();

drop trigger if exists waitlist_courts_autofill on public.waitlist_courts;
create constraint trigger waitlist_courts_autofill
  after insert or update of hybrid_rotation_rule
  on public.waitlist_courts
  deferrable initially deferred
  for each row execute function public.wl_autofill_after_change();

notify pgrst, 'reload schema';
commit;
