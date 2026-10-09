-- Fix: joining failed with 'column reference "r.id" is ambiguous'.
--
-- While finishers are deciding, each new player is placed halfway between two
-- line keys. After about six joins the keys get long and the allocator
-- renumbers them. That renumbering used a CTE named "r", which clashes with the
-- function's record variable "r", so every join, add or seat after that point
-- failed. The CTE is renamed; nothing else changes.
begin;

do $mig$
declare
  def text;
begin
  select pg_get_functiondef('public.fill_facility_open_slots(uuid,boolean)'::regprocedure) into def;
  if position('with renum as (' in def)>0 then
    raise notice 'fill_facility_open_slots: already fixed';
    return;
  end if;
  if position('    with r as (' in def)=0
     or position('set line_key=r.rn from r' in def)=0
     or position('where p.id=r.id and p.line_key is distinct from r.rn;' in def)=0 then
    raise exception 'fill_facility_open_slots: renumber block not found';
  end if;
  def:=replace(def,'    with r as (','    with renum as (');
  def:=replace(def,'set line_key=r.rn from r','set line_key=renum.rn from renum');
  def:=replace(def,'where p.id=r.id and p.line_key is distinct from r.rn;','where p.id=renum.id and p.line_key is distinct from renum.rn;');
  execute def;
end
$mig$;

notify pgrst, 'reload schema';
commit;
