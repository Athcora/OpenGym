-- Preserve each runtime helper's original body and boundary, replacing only
-- the Supabase-managed auth.uid() dependency with our private request helper.
do $$
declare item record; definition text;
begin
  for item in
    select p.oid
    from pg_proc p join pg_roles r on r.oid=p.proowner
    where r.rolname='opengym_runtime' and p.prokind='f'
      and pg_get_functiondef(p.oid) like '%auth.uid()%'
  loop
    definition:=replace(pg_get_functiondef(item.oid),'auth.uid()','public.current_request_user_id()');
    execute definition;
  end loop;
end $$;

do $$
begin
  if exists(
    select 1 from pg_proc p join pg_roles r on r.oid=p.proowner
    where r.rolname='opengym_runtime' and p.prokind='f'
      and pg_get_functiondef(p.oid) like '%auth.uid()%'
  ) then raise exception 'runtime auth.uid dependency remains'; end if;
end $$;
