-- The browser may use only the guarded entrypoints.  Nested helpers execute
-- under the SECURITY DEFINER owner and must not be callable by client roles.
begin;

revoke all on function public.advance_court_game(integer,uuid,integer)
  from public, anon;
grant execute on function public.advance_court_game(integer,uuid,integer)
  to authenticated;

revoke all on function public.reverse_past_game_guarded(uuid,uuid)
  from public, anon;
grant execute on function public.reverse_past_game_guarded(uuid,uuid)
  to authenticated;

revoke all on function public.end_court_game(integer)
  from public, anon, authenticated, service_role;
grant execute on function public.end_court_game(integer)
  to opengym_runtime;

notify pgrst, 'reload schema';
commit;
