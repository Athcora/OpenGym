-- Grouping a player who is on a court moves them back to the waitlist, but
-- admin_group_players() left their old court_number in place. The queue
-- renumbering sorts waiting players by court_number first, so that player
-- jumped ahead of everyone else and split their group in the waitlist.
-- Clear court_number whenever grouping sends players to the waitlist.
begin;

do $$
declare def text; patched text;
begin
  def:=pg_get_functiondef('public.admin_group_players(uuid[])'::regprocedure);
  if position('status=''waiting'',court_number=null' in def)>0 then return; end if;
  if (length(def)-length(replace(def,'set status=''waiting'',queue_position=','')))/length('set status=''waiting'',queue_position=')<>1
     or (length(def)-length(replace(def,'set group_id=new_group,status=''waiting'',','')))/length('set group_id=new_group,status=''waiting'',')<>1 then
    raise exception 'admin_group_players() changed; review before patching.';
  end if;
  patched:=replace(def,'set status=''waiting'',queue_position=','set status=''waiting'',court_number=null,queue_position=');
  patched:=replace(patched,'set group_id=new_group,status=''waiting'',','set group_id=new_group,status=''waiting'',court_number=null,');
  execute patched;
end;
$$;

-- Repair any player already left in this state (waiting with a court).
update public.waitlist_players set court_number=null,updated_at=now()
  where status in ('waiting','sitout','rejoin') and court_number is not null;

notify pgrst,'reload schema';
commit;
