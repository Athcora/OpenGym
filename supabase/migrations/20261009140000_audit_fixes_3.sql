-- Audit fixes (round 3): close requests when a player leaves.
--
-- A pending Group Up or swap request stayed "pending" after either player
-- left the waitlist (or timed out). The other player could later get a
-- "wants to group with you" popup from someone who is gone. Leaving now closes
-- the player's open requests in both directions.
begin;

create or replace function public.wl_close_requests_on_leave()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
begin
  update public.group_requests
     set status='cancelled',answered_at=coalesce(answered_at,now())
   where facility_id=new.facility_id and status='pending'
     and (requester_id=new.id or target_id=new.id);
  update public.substitute_requests
     set status='declined',answered_at=coalesce(answered_at,now())
   where facility_id=new.facility_id and status='pending'
     and (requester_id=new.id or target_id=new.id);
  return null;
exception when others then
  raise warning 'closing requests skipped: %', sqlerrm;
  return null;
end;
$$;

alter function public.wl_close_requests_on_leave() owner to opengym_runtime;
revoke all on function public.wl_close_requests_on_leave() from public, anon, authenticated;

drop trigger if exists waitlist_players_close_requests_on_leave on public.waitlist_players;
create trigger waitlist_players_close_requests_on_leave
  after update of status on public.waitlist_players
  for each row
  when (new.status='left' and old.status is distinct from 'left')
  execute function public.wl_close_requests_on_leave();

-- Close requests already left behind by players who are gone.
update public.group_requests r set status='cancelled',answered_at=coalesce(r.answered_at,now())
 where r.status='pending' and exists(
   select 1 from public.waitlist_players p
    where p.id in (r.requester_id,r.target_id) and p.status='left');
update public.substitute_requests r set status='declined',answered_at=coalesce(r.answered_at,now())
 where r.status='pending' and exists(
   select 1 from public.waitlist_players p
    where p.id in (r.requester_id,r.target_id) and p.status='left');

notify pgrst, 'reload schema';
commit;
