-- Audit fixes (round 2): tell players when their rejoin time ran out.
--
-- When the rejoin timer runs out, the server (or another client) removes the
-- player. If their app was closed or in the background, they later opened it
-- to a waitlist screen with only a Rejoin button and no explanation. Now the
-- removal sends them the same "Timed Out" popup (and a push notification),
-- which the app shows the next time it opens.
begin;

create or replace function public.wl_notify_rejoin_timeout()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
declare
  deadline timestamptz;
  slug text;
begin
  if new.user_id is null then
    return null;
  end if;
  select max(r.expires_at) into deadline
    from public.rejoin_responses r
   where r.facility_id=new.facility_id and r.user_id=new.user_id;
  deadline:=coalesce(old.rejoin_expires_at,deadline);
  if deadline is null or deadline>now() then
    return null;
  end if;
  select f.slug into slug from public.facilities f where f.id=new.facility_id;
  insert into public.group_notifications(facility_id,user_id,message)
  values(new.facility_id,new.user_id,
    'LINE_UPDATE|Timed Out|You did not rejoin in time, so you were removed from the waitlist.');
  insert into public.push_outbox(facility_id,user_id,notification)
  values(new.facility_id,new.user_id,jsonb_build_object(
    'title','Timed Out',
    'body','You did not rejoin in time, so you were removed from the waitlist.',
    'kind','line_update',
    'url',case when slug is null then '/' else '/g/'||slug end,
    'tag','open-gym-rejoin-timeout'));
  return null;
exception when others then
  raise warning 'rejoin timeout notice skipped: %', sqlerrm;
  return null;
end;
$$;

alter function public.wl_notify_rejoin_timeout() owner to opengym_runtime;
revoke all on function public.wl_notify_rejoin_timeout() from public, anon, authenticated;

drop trigger if exists waitlist_players_notify_rejoin_timeout on public.waitlist_players;
create trigger waitlist_players_notify_rejoin_timeout
  after update of status on public.waitlist_players
  for each row
  when (old.status='rejoin' and new.status='left')
  execute function public.wl_notify_rejoin_timeout();

notify pgrst, 'reload schema';
commit;
