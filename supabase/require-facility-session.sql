-- Run 4: a selected facility is an authorization boundary.  Never fall back to
-- PHR for a newly authenticated browser that has not selected a facility yet.
-- A NULL return makes restrictive facility RLS policies deny queue rows until
-- select_facility() records the user's selected facility.

create or replace function public.current_facility_id()
returns uuid language sql stable security definer set search_path=public as $$
  select facility_id
  from public.user_facility_sessions
  where user_id=auth.uid()
$$;

grant execute on function public.current_facility_id() to authenticated;

notify pgrst, 'reload schema';
