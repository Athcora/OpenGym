-- A player in line (waiting) or holding a rejoin spot is not on a court.
--
-- Admin "unsit" put a player back in line but kept the court they sat out
-- from. The waitlist renumbering after an admin drag sorts by court number,
-- so that player could jump ahead of everyone in line. This rule clears the
-- court for every path that puts a player in line.
begin;

create or replace function public.wl_clear_idle_court()
returns trigger
language plpgsql
set search_path to 'public'
as $function$
begin
  if new.status in ('waiting','rejoin') and new.court_number is not null then
    new.court_number:=null;
    new.seat_locked:=false;
  end if;
  return new;
end;
$function$;

drop trigger if exists waitlist_players_clear_idle_court on public.waitlist_players;
create trigger waitlist_players_clear_idle_court
  before insert or update of status, court_number on public.waitlist_players
  for each row execute function public.wl_clear_idle_court();

update public.waitlist_players set court_number=null,seat_locked=false
 where status in ('waiting','rejoin') and court_number is not null;

insert into supabase_migrations.schema_migrations(version,name,statements)
values ('20261010140000','waiting_players_have_no_court',array['see supabase/migrations/20261010140000_waiting_players_have_no_court.sql'])
on conflict (version) do nothing;
commit;
