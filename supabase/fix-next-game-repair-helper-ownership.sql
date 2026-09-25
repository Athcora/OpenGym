-- The guarded browser endpoint reaches end_court_game() as opengym_runtime.
-- Keep its repair helper private, but align ownership so that the runtime
-- can execute the nested SECURITY DEFINER call after grant hardening.
begin;

alter function public.repair_facility_court_assignments(uuid) owner to opengym_runtime;
revoke all on function public.repair_facility_court_assignments(uuid) from public, anon, authenticated;
revoke all on function public.repair_facility_court_assignments(uuid) from service_role;
grant execute on function public.repair_facility_court_assignments(uuid) to opengym_runtime;
grant execute on function public.repair_facility_court_assignments(uuid) to service_role;

notify pgrst, 'reload schema';
commit;