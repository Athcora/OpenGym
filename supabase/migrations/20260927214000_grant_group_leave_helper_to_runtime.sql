-- The three SECURITY DEFINER browser RPCs run as opengym_runtime.  Their
-- private queue-order helper is intentionally unavailable to API roles, but
-- must remain executable by that owner role when it is invoked internally.
begin;

grant execute on function public.detach_group_member_preserving_queue(uuid,uuid,uuid)
  to opengym_runtime;

commit;
