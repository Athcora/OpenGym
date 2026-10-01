
-- The guarded mode/advance/reverse chain runs as the private runtime owner
-- and calls auth.uid()/auth.jwt().  The schema-only baseline does not grant
-- those references to that role, so make the dependency reproducible here.
begin;
grant usage on schema auth to opengym_runtime;
grant execute on function auth.uid() to opengym_runtime;
grant execute on function auth.jwt() to opengym_runtime;
commit;
