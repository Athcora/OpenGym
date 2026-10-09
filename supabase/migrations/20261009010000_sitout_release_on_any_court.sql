-- Sit-outs end at the next game start on ANY court.
--
-- Game numbers are per court, but sit_out_one_game / admin_set_player_sitout /
-- sit_out_and_leave_group store sitout_from_game using the sitter's own court
-- number (or the facility max), and end_court_game only releases sit-outs
-- whose sitout_from_game <= the ending court's number. So a player who sat out
-- on Court 2 stayed sitting out when Court 1 started its next game, even
-- though that game was the next one available to them.
--
-- New rule:
--   * Left a game in progress (current -> sitout): that game was the sit-out.
--     The next game that starts on any court releases them with priority, and
--     the allocator seats them in it.
--   * Sat out while waiting: they skip the next game start (any court), or as
--     many starts as the Game N they chose, then are released the same way.
begin;

alter table public.waitlist_players
  add column if not exists sitout_skips_remaining smallint;

comment on column public.waitlist_players.sitout_skips_remaining is
  'Game starts (on any court) this sit-out still has to skip before release. 0 = release at the next start.';

-- 1. Record how many game starts a new sit-out must skip ----------------------
create or replace function public.wl_mark_sitout_skips()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
declare
  facility_game integer;
begin
  if new.status='sitout' and old.status is distinct from 'sitout' then
    if old.status='current' then
      new.sitout_skips_remaining:=0;
    else
      select game_number into facility_game
        from public.waitlist_config where facility_id=new.facility_id and id;
      new.sitout_skips_remaining:=greatest(1,coalesce(new.sitout_from_game-facility_game,1));
    end if;
  elsif new.status is distinct from 'sitout' then
    new.sitout_skips_remaining:=null;
  end if;
  return new;
end;
$$;

alter function public.wl_mark_sitout_skips() owner to opengym_runtime;
revoke all on function public.wl_mark_sitout_skips() from public, anon, authenticated;

drop trigger if exists waitlist_players_mark_sitout_skips on public.waitlist_players;
create trigger waitlist_players_mark_sitout_skips
  before update of status on public.waitlist_players
  for each row execute function public.wl_mark_sitout_skips();

-- 2. Any court starting a game releases served sit-outs -----------------------
create or replace function public.wl_release_sitouts_on_game_start()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
declare
  mode text;
begin
  select c.mode into mode from public.waitlist_config c where c.facility_id=new.facility_id and c.id;
  -- Team / King modes manage sit-outs per team.
  if mode is null or mode ~* '(king|team)' then
    return null;
  end if;

  -- Restrictive facility_isolation RLS: make sure we can see this facility.
  if public.current_facility_id() is distinct from new.facility_id then
    perform set_config('opengym.facility_override',new.facility_id::text,true);
  end if;

  begin
    -- Served: release with priority so the allocator seats them first.
    update public.waitlist_players
       set status='waiting',court_number=null,sitout_from_game=null,
           sitout_priority=true,updated_at=now()
     where facility_id=new.facility_id
       and status='sitout'
       and coalesce(sitout_skips_remaining,0)<=0;

    -- Still skipping: this start counts as one skipped game.
    update public.waitlist_players
       set sitout_skips_remaining=sitout_skips_remaining-1
     where facility_id=new.facility_id
       and status='sitout'
       and sitout_skips_remaining>0;
  exception when others then
    raise warning 'sit-out release skipped for facility %: %',new.facility_id,sqlerrm;
  end;
  return null;
end;
$$;

alter function public.wl_release_sitouts_on_game_start() owner to opengym_runtime;
revoke all on function public.wl_release_sitouts_on_game_start() from public, anon, authenticated;

-- Fires inside end_court_game / advance_* when the court's game_number is
-- bumped, which is before they call fill_open_court_slots(), so released
-- players are seated in the game that is starting.
drop trigger if exists waitlist_courts_release_sitouts on public.waitlist_courts;
create trigger waitlist_courts_release_sitouts
  after update of game_number on public.waitlist_courts
  for each row
  when (new.game_number>old.game_number)
  execute function public.wl_release_sitouts_on_game_start();

-- 3. Backfill sit-outs that already exist --------------------------------------
-- Existing sit-outs keep NULL (= release at the next game start on any court).

notify pgrst, 'reload schema';
commit;
