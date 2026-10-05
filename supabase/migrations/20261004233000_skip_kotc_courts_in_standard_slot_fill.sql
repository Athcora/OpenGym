-- KOTC court appearances are owned exclusively by hybrid_kotc_slots.  The
-- standard allocator must not promote a joining player to `current` on a KOTC
-- court, because that would create a player with no authoritative KOTC slot.
begin;

do $$
begin
  if to_regprocedure('public.fill_open_court_slots()') is null then
    raise exception 'Expected public.fill_open_court_slots() before installing the KOTC allocation guard.';
  end if;
  if to_regprocedure('public.is_hybrid_kotc_court(uuid,integer)') is null then
    raise exception 'Expected public.is_hybrid_kotc_court(uuid,integer) before installing the KOTC allocation guard.';
  end if;
end;
$$;

create or replace function public.fill_open_court_slots()
returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  c record;
  open_spots integer;
  candidate record;
  group_size integer;
  fid uuid:=public.current_facility_id();
begin
  for c in
    select court_number
    from public.waitlist_courts
    where facility_id=fid
    order by court_number
  loop
    -- A KOTC court's physical roster is represented by its hybrid slots. Do
    -- not create a second, unowned `current` representation here.
    if public.is_hybrid_kotc_court(fid,c.court_number) then
      continue;
    end if;

    select greatest(cfg.max_players-count(p.id),0)
      into open_spots
    from public.waitlist_config cfg
    left join public.waitlist_players p
      on p.facility_id=fid
      and p.status='current'
      and p.court_number=c.court_number
    where cfg.facility_id=fid
      and cfg.id
    group by cfg.max_players;

    while open_spots>0 loop
      select p.id,p.group_id
        into candidate
      from public.waitlist_players p
      where p.facility_id=fid
        and p.status='waiting'
      order by p.sitout_priority desc,p.queue_position,p.id
      limit 1;

      exit when candidate.id is null;

      if candidate.group_id is null then
        update public.waitlist_players
        set status='current',court_number=c.court_number,sitout_priority=false,updated_at=now()
        where facility_id=fid and id=candidate.id;
        open_spots:=open_spots-1;
      else
        select count(*)
          into group_size
        from public.waitlist_players
        where facility_id=fid and status='waiting' and group_id=candidate.group_id;
        exit when group_size>open_spots;
        update public.waitlist_players
        set status='current',court_number=c.court_number,sitout_priority=false,updated_at=now()
        where facility_id=fid and status='waiting' and group_id=candidate.group_id;
        open_spots:=open_spots-group_size;
      end if;
    end loop;
  end loop;

  with ranked as (
    select id,row_number() over(
      order by case when status='current' then 0 else 1 end,
               coalesce(court_number,999),queue_position,id
    ) rn
    from public.waitlist_players
    where facility_id=fid and status in('current','waiting') and queue_position is not null
  )
  update public.waitlist_players p
  set queue_position=ranked.rn
  from ranked
  where p.facility_id=fid and p.id=ranked.id;
end;
$$;

alter function public.fill_open_court_slots() owner to opengym_runtime;
revoke all on function public.fill_open_court_slots() from public, anon;
grant execute on function public.fill_open_court_slots() to authenticated;
-- The predicate remains private to browser roles, but this SECURITY DEFINER
-- allocator runs as opengym_runtime and therefore needs this internal grant.
grant execute on function public.is_hybrid_kotc_court(uuid,integer) to opengym_runtime;

do $$
begin
  if not has_function_privilege('opengym_runtime','public.is_hybrid_kotc_court(uuid,integer)','EXECUTE') then
    raise exception 'opengym_runtime must execute the private KOTC court predicate.';
  end if;
  if has_function_privilege('authenticated','public.is_hybrid_kotc_court(uuid,integer)','EXECUTE')
     or has_function_privilege('anon','public.is_hybrid_kotc_court(uuid,integer)','EXECUTE')
     or has_function_privilege('public','public.is_hybrid_kotc_court(uuid,integer)','EXECUTE') then
    raise exception 'KOTC court predicate must remain private to browser roles.';
  end if;
end;
$$;

notify pgrst, 'reload schema';
commit;
