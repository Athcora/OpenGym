-- All joins enter the shared waiting queue, then this allocator fills every
-- active court in numeric order before anybody remains on the waitlist.
create or replace function public.fill_open_court_slots()
returns void language plpgsql security definer set search_path=public as $$
declare c record; open_spots integer; candidate record; group_size integer;
begin
  -- Never redistribute players who are already playing. Fill each court's
  -- vacancies from the shared queue, in court order, so an operation on one
  -- court cannot silently alter another court.
  for c in select court_number from public.waitlist_courts order by court_number loop
    select greatest(cfg.max_players-count(p.id),0) into open_spots
    from public.waitlist_config cfg left join public.waitlist_players p
      on p.status='current' and p.court_number=c.court_number
    where cfg.id group by cfg.max_players;

    while open_spots>0 loop
      select p.id,p.group_id into candidate from public.waitlist_players p
      where p.status='waiting'
      order by p.sitout_priority desc,p.queue_position,p.id limit 1;
      exit when candidate.id is null;

      if candidate.group_id is null then
        update public.waitlist_players set status='current',court_number=c.court_number,
          sitout_priority=false,updated_at=now() where id=candidate.id;
        open_spots:=open_spots-1;
      else
        select count(*) into group_size from public.waitlist_players
          where status='waiting' and group_id=candidate.group_id;
        exit when group_size>open_spots;
        update public.waitlist_players set status='current',court_number=c.court_number,
          sitout_priority=false,updated_at=now()
          where status='waiting' and group_id=candidate.group_id;
        open_spots:=open_spots-group_size;
      end if;
    end loop;
  end loop;

  with ranked as (
    select id,row_number() over(order by case when status='current' then 0 else 1 end,
      coalesce(court_number,999),queue_position,id) rn
    from public.waitlist_players where status in('current','waiting') and queue_position is not null
  )
  update public.waitlist_players p set queue_position=ranked.rn
  from ranked where p.id=ranked.id;
end; $$;

select public.fill_open_court_slots();
