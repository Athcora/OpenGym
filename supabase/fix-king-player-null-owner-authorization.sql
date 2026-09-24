-- Reject authenticated users moving admin-created King players whose
-- user_id is NULL. SQL's `NULL <> auth.uid()` evaluates to NULL, so a PL/pgSQL
-- IF previously treated the ownership rejection as false.
begin;

do $$
declare
  target record;
  definition text;
  patched text;
  old_guard constant text := 'player.user_id<>auth.uid()';
  new_guard constant text := 'player.user_id is distinct from auth.uid()';
begin
  for target in
    select p.oid,p.proname
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public'
      and (p.oid='public.join_king_team(uuid,uuid)'::regprocedure
        or p.oid='public.join_new_king_team(uuid)'::regprocedure
        or p.oid='public.king_prepare_player(uuid)'::regprocedure)
  loop
    definition:=pg_get_functiondef(target.oid);
    if (length(definition)-length(replace(definition,old_guard,''))) / length(old_guard) <> 1 then
      raise exception 'Expected exactly one null-sensitive ownership guard in %',target.proname;
    end if;
    patched:=replace(definition,old_guard,new_guard);
    execute patched;
    if position(new_guard in pg_get_functiondef(target.oid))=0 then
      raise exception 'Null-safe ownership guard did not deploy in %',target.proname;
    end if;
  end loop;
end;
$$;

notify pgrst,'reload schema';
commit;
