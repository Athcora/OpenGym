-- Repair the current active-court sequence without changing player order.
-- This is safe before launch when no completed games should be retained.
with ordered as (
  select court_number,row_number() over(order by started_at,court_number)::integer game_number
  from public.waitlist_courts
)
update public.waitlist_courts c
set game_number=ordered.game_number
from ordered
where c.court_number=ordered.court_number;

update public.waitlist_config
set game_number=(select coalesce(max(game_number),1) from public.waitlist_courts),updated_at=now()
where id;
