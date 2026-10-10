-- Moving players by drag and drop is admin-only. Hosts keep their other
-- tools (Next game, add player, groups, swaps, sit out, rejoin requests).
begin;
do $mig$
declare
  f record;
  def text;
begin
  for f in
    select p.oid from pg_proc p join pg_namespace n on n.oid=p.pronamespace
     where n.nspname='public'
       and p.proname in ('admin_move_player','admin_move_king_player','admin_move_king_player_to_empty')
  loop
    def:=pg_get_functiondef(f.oid);
    if position('is_waitlist_operator()' in def)=0 then continue; end if;
    def:=replace(def,'is_waitlist_operator()','is_waitlist_admin()');
    def:=replace(def,'admin or host','admin');
    def:=replace(def,'admins and hosts','admins');
    execute def;
  end loop;
end
$mig$;
insert into supabase_migrations.schema_migrations(version,name,statements) values ('20261009210000','admin_only_drag',array['see supabase/migrations/20261009210000_admin_only_drag.sql']) on conflict (version) do nothing;
notify pgrst, 'reload schema';
commit;
