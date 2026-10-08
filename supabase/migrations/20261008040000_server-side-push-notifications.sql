-- Applied to production 2026-10-07. Audit F8 (notifications sent from a player's phone).
--
-- The database now queues each notification in push_outbox in the same
-- transaction as the change that causes it, and asks the send-push Edge Function
-- to deliver the queue as soon as that transaction commits (pg_net). A cron job
-- retries anything left undelivered. Recipients and text are decided here, never
-- by the browser.
--   * Rejoin prompt created         -> "Rejoin the OpenGym waitlist?" to that player.
--   * Rejoin prompt removed         -> its unsent notification is cancelled
--                                      (e.g. the game was reversed).
--   * A court's game number rises    -> "Game N has started" to the players now on
--     (Regular / Rejoin modes)          that court, except whoever pressed Next Game.
begin;

create extension if not exists pg_net;

create table if not exists public.push_outbox(
  id bigserial primary key,
  facility_id uuid,
  user_id uuid not null,
  notification jsonb not null,
  created_at timestamptz not null default now(),
  claimed_at timestamptz,
  sent_at timestamptz,
  attempts integer not null default 0,
  last_error text
);
create index if not exists push_outbox_pending_idx on public.push_outbox(id) where sent_at is null;
alter table public.push_outbox enable row level security;
revoke all on public.push_outbox from public, anon, authenticated;
grant select, insert, update, delete on public.push_outbox to opengym_runtime;
grant usage, select on sequence public.push_outbox_id_seq to opengym_runtime;
drop policy if exists runtime_access on public.push_outbox;
create policy runtime_access on public.push_outbox to opengym_runtime using (true) with check (true);

-- Ask the Edge Function to deliver the queue (runs after commit via pg_net).
create or replace function public.request_push_drain()
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
begin
  perform net.http_post(
    url := 'https://yxykrybhsrmxelkumxxr.supabase.co/functions/v1/send-push',
    body := '{"drain":true}'::jsonb,
    headers := '{"Content-Type":"application/json"}'::jsonb);
end;
$function$;
revoke all on function public.request_push_drain() from public, anon, authenticated;
grant execute on function public.request_push_drain() to opengym_runtime;

-- Once per transaction that queued something, request delivery at commit.
create or replace function public.push_outbox_request_drain()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
begin
  if current_setting('opengym.push_drain_requested', true) is distinct from '1' then
    perform set_config('opengym.push_drain_requested', '1', true);
    perform public.request_push_drain();
  end if;
  return null;
end;
$function$;
drop trigger if exists push_outbox_request_drain on public.push_outbox;
create constraint trigger push_outbox_request_drain
  after insert on public.push_outbox
  deferrable initially deferred
  for each row execute function public.push_outbox_request_drain();

-- Rejoin prompts.
create or replace function public.queue_rejoin_push()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare slug text;
begin
  if tg_op='DELETE' then
    delete from public.push_outbox
      where sent_at is null and notification->>'responseId'=old.id::text;
    return null;
  end if;
  if new.user_id is null or new.choice is not null then return null; end if;
  select f.slug into slug from public.facilities f where f.id=new.facility_id;
  insert into public.push_outbox(facility_id, user_id, notification)
    values(new.facility_id, new.user_id, jsonb_build_object(
      'title', 'Rejoin the OpenGym waitlist?',
      'body', 'Choose Rejoin or Leave within five minutes.',
      'kind', 'rejoin',
      'url', case when slug is null then '/' else '/g/'||slug end,
      'tag', 'open-gym-rejoin',
      'responseId', new.id));
  return null;
end;
$function$;
alter function public.queue_rejoin_push() owner to opengym_runtime;
drop trigger if exists queue_rejoin_push on public.rejoin_responses;
create trigger queue_rejoin_push after insert or delete on public.rejoin_responses
  for each row execute function public.queue_rejoin_push();

-- "Game N has started" for the players on that court once the action finishes.
create or replace function public.queue_game_start_push()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare cfg public.waitlist_config; slug text;
begin
  if new.game_number is null or old.game_number is null or new.game_number<=old.game_number then return null; end if;
  select * into cfg from public.waitlist_config where facility_id=new.facility_id and id;
  if cfg.mode not in ('regular','rejoin') then return null; end if;
  -- The court row may have advanced again later in the same transaction.
  if (select c.game_number from public.waitlist_courts c where c.facility_id=new.facility_id and c.court_number=new.court_number)
       is distinct from new.game_number then
    return null;
  end if;
  select f.slug into slug from public.facilities f where f.id=new.facility_id;
  insert into public.push_outbox(facility_id, user_id, notification)
    select new.facility_id, p.user_id, jsonb_build_object(
      'title', 'Game '||new.game_number||' has started',
      'body', 'You are in the current game. Head to the court!',
      'kind', 'game_started',
      'url', case when slug is null then '/' else '/g/'||slug end,
      'tag', 'open-gym-game-'||new.court_number)
    from public.waitlist_players p
    where p.facility_id=new.facility_id and p.status='current' and p.court_number=new.court_number
      and p.user_id is not null and p.user_id is distinct from public.current_request_user_id();
  return null;
end;
$function$;
alter function public.queue_game_start_push() owner to opengym_runtime;
drop trigger if exists queue_game_start_push on public.waitlist_courts;
create constraint trigger queue_game_start_push
  after update of game_number on public.waitlist_courts
  deferrable initially deferred
  for each row execute function public.queue_game_start_push();

-- Used only by the Edge Function (service role).
create or replace function public.claim_push_outbox(p_limit integer default 200)
 returns setof public.push_outbox
 language sql
 security definer
 set search_path to 'public'
as $function$
  update public.push_outbox o set claimed_at=now(), attempts=o.attempts+1
  where o.id in (
    select id from public.push_outbox
    where sent_at is null and attempts<5 and created_at>now()-interval '15 minutes'
      and (claimed_at is null or claimed_at<now()-interval '2 minutes')
    order by id limit p_limit
    for update skip locked)
  returning o.*;
$function$;

create or replace function public.complete_push_outbox(p_results jsonb)
 returns void
 language sql
 security definer
 set search_path to 'public'
as $function$
  update public.push_outbox o set
    sent_at=case when r.error is null then now() end,
    claimed_at=case when r.error is null then o.claimed_at end,
    last_error=r.error
  from jsonb_to_recordset(p_results) as r(id bigint, error text)
  where o.id=r.id;
$function$;
revoke all on function public.claim_push_outbox(integer) from public, anon, authenticated;
revoke all on function public.complete_push_outbox(jsonb) from public, anon, authenticated;
grant execute on function public.claim_push_outbox(integer) to service_role;
grant execute on function public.complete_push_outbox(jsonb) to service_role;

-- Safety net: retry anything still pending, and prune old rows.
create or replace function public.run_push_outbox_maintenance()
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
begin
  delete from public.push_outbox where created_at<now()-interval '1 day';
  if exists(select 1 from public.push_outbox where sent_at is null and attempts<5
              and created_at>now()-interval '15 minutes' and created_at<now()-interval '20 seconds') then
    perform public.request_push_drain();
  end if;
end;
$function$;
revoke all on function public.run_push_outbox_maintenance() from public, anon, authenticated;
select cron.schedule('opengym-push-outbox', '* * * * *', 'select public.run_push_outbox_maintenance();');

notify pgrst, 'reload schema';
commit;
