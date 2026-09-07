-- The player identity is unique inside a facility, not across every facility.
-- Update the live join function to target the facility-aware unique constraint.
do $$
declare definition text;
begin
  select pg_get_functiondef(p.oid) into definition
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname='join_waitlist'
    and pg_get_function_identity_arguments(p.oid)='p_first_name text, p_last_name text';

  definition:=replace(definition,'ON CONFLICT (user_id)','ON CONFLICT (facility_id, user_id)');
  definition:=replace(definition,'on conflict(user_id)','on conflict(facility_id,user_id)');
  execute definition;
  alter function public.join_waitlist(text,text) owner to opengym_runtime;
end $$;

-- Device identity lookups must also be scoped explicitly. These functions can
-- run with elevated privileges and must never claim a player from another gym.
-- Apply the definitions in prevent-duplicate-device-players.sql after this fix.
