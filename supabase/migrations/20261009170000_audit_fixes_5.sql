-- Audit fixes (round 5): no groups of one.
--
-- When a group member left through some paths (for example the player's own
-- Leave button), the remaining member kept the group id: a "group" of one,
-- which still showed group styling and was treated as a group unit. Now,
-- whenever a member leaves or changes group, a group left with fewer than two
-- active members is dissolved, and players who left drop their group id.
begin;

create or replace function public.wl_dissolve_small_groups()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
begin
  if old.group_id is null then
    return null;
  end if;
  if public.current_facility_id() is distinct from new.facility_id then
    perform set_config('opengym.facility_override',new.facility_id::text,true);
  end if;
  if new.status='left' and new.group_id is not null then
    update public.waitlist_players set group_id=null where id=new.id;
  end if;
  if (select count(*) from public.waitlist_players
       where facility_id=new.facility_id and group_id=old.group_id and status<>'left')<2 then
    update public.waitlist_players set group_id=null,updated_at=now()
     where facility_id=new.facility_id and group_id=old.group_id;
  end if;
  return null;
end;
$$;

alter function public.wl_dissolve_small_groups() owner to opengym_runtime;
revoke all on function public.wl_dissolve_small_groups() from public, anon, authenticated;

drop trigger if exists waitlist_players_dissolve_small_groups on public.waitlist_players;
create trigger waitlist_players_dissolve_small_groups
  after update of status,group_id on public.waitlist_players
  for each row
  when (old.group_id is not null and (new.status='left' or new.group_id is distinct from old.group_id))
  execute function public.wl_dissolve_small_groups();

-- Clean up groups of one that already exist (per facility, so the
-- facility_isolation policy lets the change and its history rows through).
do $bf$
declare f record;
begin
  for f in select id from public.facilities loop
    perform set_config('opengym.facility_override',f.id::text,true);
    update public.waitlist_players set group_id=null where facility_id=f.id and status='left' and group_id is not null;
    update public.waitlist_players p set group_id=null,updated_at=now()
     where p.facility_id=f.id and p.group_id is not null and p.status<>'left'
       and (select count(*) from public.waitlist_players q where q.group_id=p.group_id and q.status<>'left')<2;
  end loop;
  perform set_config('opengym.facility_override','',true);
end
$bf$;

notify pgrst, 'reload schema';
commit;
