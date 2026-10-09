-- Switching to Waitlist (New) logged two history entries: "Admin changed the
-- waitlist mode to rejoin." (an internal step) and "The waitlist is now
-- Waitlist (New)." Only the second is kept now.
begin;
do $mig$
declare
  def text;
begin
  select pg_get_functiondef('public.set_waitlist_new_mode(uuid,boolean)'::regprocedure) into def;
  if position('internal rejoin-mode entry' in def)=0 then
    if position($q$perform public.set_open_gym_mode('rejoin');$q$ in def)=0 then
      raise exception 'set_waitlist_new_mode: mode switch not found';
    end if;
    def:=replace(def,$q$perform public.set_open_gym_mode('rejoin');$q$,
      $q$perform public.set_open_gym_mode('rejoin');
    -- internal rejoin-mode entry: Waitlist (New) logs its own entry below.
    delete from public.waitlist_events
     where facility_id=fid and created_at>=now()
       and message like '%changed the waitlist mode to rejoin.';$q$);
    execute def;
  end if;
end
$mig$;
insert into supabase_migrations.schema_migrations(version,name,statements) values ('20261009190000','waitlist_new_history',array['see supabase/migrations/20261009190000_waitlist_new_history.sql']) on conflict (version) do nothing;
notify pgrst, 'reload schema';
commit;
