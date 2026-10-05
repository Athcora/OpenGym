begin;

create or replace function public.current_request_claims()
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare raw_claims text;
begin
  raw_claims:=current_setting('request.jwt.claims',true);
  if raw_claims is null or btrim(raw_claims)='' then return '{}'::jsonb; end if;
  begin return raw_claims::jsonb; exception when others then return '{}'::jsonb; end;
end $$;

create or replace function public.current_request_user_id()
returns uuid language plpgsql stable security definer set search_path=public as $$
declare value text;
begin
  value:=coalesce(public.current_request_claims()->>'sub',current_setting('request.jwt.claim.sub',true));
  if value is null or btrim(value)='' then return null; end if;
  begin return value::uuid; exception when invalid_text_representation then return null; end;
end $$;

create or replace function public.current_facility_id()
returns uuid language sql stable security definer set search_path=public as $$
  select facility_id from public.user_facility_sessions where user_id=public.current_request_user_id()
$$;

create or replace function public.is_waitlist_admin()
returns boolean language sql stable security definer set search_path=public as $$
  select coalesce((public.current_request_claims()->'app_metadata'->>'role')='admin',false)
    or exists(select 1 from public.admin_sessions where user_id=public.current_request_user_id() and facility_id=public.current_facility_id())
$$;

create or replace function public.is_waitlist_host()
returns boolean language sql stable security definer set search_path=public as $$
  select exists(select 1 from public.waitlist_players where user_id=public.current_request_user_id() and facility_id=public.current_facility_id() and is_host and status in ('current','waiting','sitout','rejoin'))
$$;

revoke all on function public.current_request_claims(),public.current_request_user_id() from public,anon,authenticated;
grant execute on function public.current_request_claims(),public.current_request_user_id() to opengym_runtime;
revoke all on function auth.uid(),auth.jwt() from opengym_runtime;
revoke usage on schema auth from opengym_runtime;
commit;
