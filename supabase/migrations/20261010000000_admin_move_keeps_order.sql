-- Admin drag and drop: the player stays where they were dropped.
--
-- The line has a hidden order (line_key) that the automatic seating step
-- (fill_facility_open_slots) re-sorts every court and the waitlist by after
-- each change. admin_move_player only rewrote the visible positions, so:
--   * moving a player within a court snapped them straight back, and
--   * a player dragged onto a court landed at the end instead of the spot
--     they were dropped on.
-- Now the hidden order is rebuilt from the new visible order at the end of
-- the move (re-using the same set of keys, so held rejoin spots keep their
-- place relative to everyone else).
begin;
do $mig$
declare
  def text;
  marker text:=$q$return jsonb_build_object('message','Player moved.'$q$;
begin
  select pg_get_functiondef('public.admin_move_player(uuid,text,integer,integer)'::regprocedure) into def;
  if position('keep the hidden line order' in def)>0 then
    raise notice 'admin_move_player already keeps the line order';
    return;
  end if;
  if position(marker in def)=0 then
    raise exception 'admin_move_player: return statement not found';
  end if;
  def:=replace(def,marker,$q$-- keep the hidden line order in step with the new visible order
with active as (
  select id,line_key,row_number() over(order by queue_position,id) rn
    from public.waitlist_players
   where facility_id=fid and status in ('current','waiting','sitout')
), top as (
  select coalesce(max(line_key),0) k from public.waitlist_players where facility_id=fid
), pool as (
  select line_key k from active where line_key is not null
  union all
  select top.k+row_number() over(order by a.rn) from active a cross join top where a.line_key is null
), keys as (
  select k,row_number() over(order by k) rn from pool
)
update public.waitlist_players p set line_key=keys.k
  from active join keys on keys.rn=active.rn
 where p.id=active.id and p.line_key is distinct from keys.k;
$q$||marker);
  execute def;
end
$mig$;
insert into supabase_migrations.schema_migrations(version,name,statements) values ('20261010000000','admin_move_keeps_order',array['see supabase/migrations/20261010000000_admin_move_keeps_order.sql']) on conflict (version) do nothing;
notify pgrst, 'reload schema';
commit;
