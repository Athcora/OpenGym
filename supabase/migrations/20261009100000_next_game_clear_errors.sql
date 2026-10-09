-- Clearer "could not start the next game" errors.
--
-- end_court_game() first heals overfilled courts (repair_facility_court_assignments
-- returns the players past max_players to the waitlist), then checks that the
-- caller is playing on that court. A player who had been placed past capacity
-- (e.g. after a Reverse put 17 on a 12-player court) was moved off the court in
-- that step and then told "Only an unrestricted player on this court or an
-- admin/host can start its next game", even though they were not restricted.
-- The Reverse overfill is fixed separately; this makes the message say what
-- actually happened. The function body is otherwise unchanged.
begin;

do $mig$
declare
  def text;
  old_check text:='then raise exception ''Only an unrestricted player on this court or an admin/host can start its next game.''; end if;';
  new_check text:='then raise exception ''%'', case'
    ||' when caller.id is null or caller.status<>''current'' then ''You are not in the current game anymore, so you cannot start the next one. Refresh to see the latest lineup.'''
    ||' when caller.court_number<>p_court_number then ''You are playing on Court ''||caller.court_number||'', so you can only start the next game there.'''
    ||' else ''You are restricted from starting games. Ask an admin or host.'' end; end if;';
begin
  select pg_get_functiondef('public.end_court_game(integer)'::regprocedure) into def;
  if position(old_check in def)=0 then
    raise notice 'end_court_game: caller check not found, left unchanged';
    return;
  end if;
  execute replace(def,old_check,new_check);
end
$mig$;

notify pgrst, 'reload schema';
commit;
