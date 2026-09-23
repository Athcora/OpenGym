-- Run 4: the original team roster read policies were intentionally broad so
-- teammates could see current roster state.  Once facilities were introduced,
-- `using (true)` became a permissive RLS policy that bypassed the restrictive
-- facility policy (PostgreSQL combines permissive policies with OR).
--
-- Keep authenticated roster reads working, but constrain them to the selected
-- facility.  The existing facility_isolation policy remains the write guard.

drop policy if exists team_fill_ins_read on public.team_fill_ins;
create policy team_fill_ins_read on public.team_fill_ins
  for select to authenticated
  using (facility_id = public.current_facility_id());

drop policy if exists team_substitutes_read on public.team_substitutes;
create policy team_substitutes_read on public.team_substitutes
  for select to authenticated
  using (facility_id = public.current_facility_id());

drop policy if exists team_substitute_requests_read on public.team_substitute_requests;
create policy team_substitute_requests_read on public.team_substitute_requests
  for select to authenticated
  using (facility_id = public.current_facility_id());
