-- Run 4: PostgreSQL grants EXECUTE on new functions to PUBLIC by default.
-- OpenGym uses anonymous Supabase authentication, which maps browser sessions
-- to the authenticated role. No unauthenticated client needs an RPC.
--
-- Keep internal SECURITY DEFINER helpers callable only by their owning runtime
-- role, and explicitly expose just the RPCs used by the browser application.
-- `current_facility_id` and `is_waitlist_admin` are narrowly scoped RLS
-- support helpers used while PostgreSQL evaluates authenticated policies; they
-- must remain executable by that role even though neither is a client-invoked
-- RPC.

revoke all on all functions in schema public from public, anon, authenticated;

alter default privileges for role postgres in schema public
  revoke execute on functions from public;
alter default privileges for role opengym_runtime in schema public
  revoke execute on functions from public;

do $$
declare
  allowed_names text[] := array[
    'admin_accept_all_offline_rejoins_for_facility', 'admin_add_player',
    'admin_answer_offline_rejoin', 'admin_group_players',
    'admin_leave_player', 'admin_list_members',
    'admin_list_offline_rejoins', 'admin_list_waitlist_history',
    'admin_move_king_player', 'admin_move_king_player_to_empty',
    'admin_move_player', 'admin_redo_last',
    'admin_remove_player_from_group', 'admin_remove_team_substitute',
    'admin_reset_waitlist', 'admin_restrict_player',
    'admin_select_facility', 'admin_set_court_count',
    'admin_set_facility_location', 'admin_set_player_sitout',
    'admin_set_session_host', 'admin_substitute_players',
    'admin_undo_last', 'admin_unsit_player', 'advance_court_game',
    'advance_team_king_game', 'advance_team_rotation',
    'answer_player_group', 'answer_player_substitute',
    'answer_rejoin_prompt', 'answer_team_substitute',
    'cancel_team_fill_in', 'cancel_team_sitout', 'claim_waitlist_device',
    'cleanup_king_rejoin_expirations', 'create_facility', 'current_facility_id',
    'fill_in_team_spot', 'join_king_team', 'join_new_king_team',
    'is_waitlist_admin', 'join_waitlist_for_device', 'king_prepare_player',
    'leave_player_group', 'leave_waitlist_for_facility', 'rejoin_waitlist_at_back',
    'remove_player_from_group', 'remove_self_for_geofence',
    'rename_waitlist_player', 'request_player_group',
    'request_player_substitute', 'request_team_substitute',
    'return_after_geofence', 'reverse_next_game',
    'reverse_past_game_guarded', 'save_operator_undo', 'select_facility',
    'set_open_gym_mode', 'set_team_court_rules',
    'sign_in_waitlist_admin', 'sit_out_and_leave_group', 'sit_out_one_game',
    'verify_facility_location'
  ];
  found_names text[];
  fn record;
begin
  select array_agg(distinct p.proname order by p.proname)
    into found_names
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = any(allowed_names);

  if found_names is distinct from (select array_agg(name order by name) from unnest(allowed_names) as name) then
    raise exception 'OpenGym browser RPC allowlist does not match deployed functions';
  end if;

  for fn in
    select p.oid::regprocedure as signature
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = any(allowed_names)
  loop
    execute format('grant execute on function %s to authenticated', fn.signature);
  end loop;
end $$;

notify pgrst, 'reload schema';
