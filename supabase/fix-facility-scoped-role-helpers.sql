-- A facility-scoped admin login or Session Host must not grant operator
-- privileges after the same authenticated browser selects another facility.
-- The app_metadata admin role remains an intentionally global, server-managed
-- super-admin capability; ordinary facility-admin sessions are scoped below.

create or replace function public.is_waitlist_admin()
returns boolean language sql stable security definer set search_path=public as $$
  select coalesce((auth.jwt()->'app_metadata'->>'role')='admin',false)
    or exists(
      select 1
      from public.admin_sessions
      where user_id=auth.uid()
        and facility_id=public.current_facility_id()
    );
$$;

create or replace function public.is_waitlist_host()
returns boolean language sql stable security definer set search_path=public as $$
  select exists(
    select 1
    from public.waitlist_players
    where user_id=auth.uid()
      and facility_id=public.current_facility_id()
      and is_host
      and status in ('current','waiting','sitout','rejoin')
  );
$$;

create or replace function public.is_waitlist_operator()
returns boolean language sql stable security definer set search_path=public as $$
  select public.is_waitlist_admin() or public.is_waitlist_host();
$$;

notify pgrst, 'reload schema';
