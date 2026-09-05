-- Keep the configured number of courts and the live court rows in sync.
-- This also repairs historical states where a reset or restore left ghost courts.

create or replace function public.clear_waitlist_and_history(p_clear_undo boolean default false)
returns void language plpgsql security definer set search_path=public as $$
declare cfg public.waitlist_config;
begin
  select * into cfg from public.waitlist_config where id for update;

  update public.waitlist_players
    set status='left',queue_position=null,group_id=null,team_id=null,court_number=null,
      rejoin_expires_at=null,sitout_priority=false,sitout_from_game=null,updated_at=now()
    where true;

  delete from public.king_round_history where true;
  delete from public.king_teams where true;
  delete from public.king_mode_state where true;
  delete from public.past_games where true;
  delete from public.group_requests where true;
  delete from public.rejoin_responses where true;
  delete from public.group_notifications where true;
  delete from public.substitute_requests where true;

  update public.waitlist_config set game_number=1,updated_at=now() where id;
  delete from public.waitlist_courts where court_number>greatest(1,cfg.court_count);
  insert into public.waitlist_courts(court_number,game_number,started_at)
    select n,n,now() from generate_series(1,greatest(1,cfg.court_count)) n
    on conflict(court_number) do update set game_number=excluded.game_number,started_at=excluded.started_at;
  delete from public.waitlist_events where true;

  if p_clear_undo then
    delete from public.admin_undo where true;
    delete from public.admin_redo where true;
  end if;
end;
$$;

-- Repair empty historical ghost courts immediately. Populated courts remain
-- untouched so a deploy can never displace an active game unexpectedly.
delete from public.waitlist_courts
where court_number>(select greatest(1,court_count) from public.waitlist_config where id)
  and not exists(
    select 1 from public.waitlist_players p
    where p.status='current' and p.court_number=waitlist_courts.court_number
  )
  and not exists(
    select 1 from public.king_teams t
    where t.status='current' and t.court_number=waitlist_courts.court_number
  );

insert into public.waitlist_courts(court_number,game_number,started_at)
select n,n,now()
from public.waitlist_config cfg,
     generate_series(1,greatest(1,cfg.court_count)) n
where cfg.id
on conflict(court_number) do nothing;
