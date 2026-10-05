-- LOCAL ONLY, run as supabase_admin before importing the public schema dump.
-- A schema-only dump does not include cluster roles or auth-schema privileges.
do $$
begin
  if not exists(select 1 from pg_roles where rolname='opengym_runtime') then
    create role opengym_runtime noinherit nologin;
  end if;
end $$;
grant opengym_runtime to postgres;
grant usage,create on schema public to opengym_runtime;
grant usage on schema auth to opengym_runtime;
grant execute on function auth.uid() to opengym_runtime;
