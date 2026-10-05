-- Run against local Supabase after all Stage 1A migrations.
do $$
declare signature text; role_name text;
begin
  foreach signature in array array[
    'public.capture_court_reversal_state()',
    'public.capture_court_reversal_state_legacy()',
    'public.capture_waitlist_state()',
    'public.restore_waitlist_state(jsonb)',
    'public.record_court_reversal(jsonb,integer)',
    'public.reverse_past_game_legacy(uuid)',
    'public.capture_hybrid_kotc_state()',
    'public.restore_hybrid_kotc_state(jsonb)',
    'public.apply_hybrid_court_reverse(jsonb,jsonb,integer)',
    'public.reconcile_hybrid_reverse_player_eligibility(integer)'
  ] loop
    if exists(
      select 1 from pg_proc p,
        lateral aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a
      where p.oid=signature::regprocedure and a.grantee=0 and a.privilege_type='EXECUTE'
    ) then
      raise exception 'Unexpected PUBLIC execute: %',signature;
    end if;
    if exists(select 1 from pg_proc where oid=signature::regprocedure and prosecdef
      and not ('search_path=public'=any(coalesce(proconfig,'{}')))) then
      raise exception 'Unexpected SECURITY DEFINER search_path: %',signature;
    end if;
    foreach role_name in array array['anon','authenticated'] loop
      if has_function_privilege(role_name,signature,'EXECUTE') then
        raise exception 'Unexpected browser execute: % on %',role_name,signature;
      end if;
    end loop;
    if not has_function_privilege('opengym_runtime',signature,'EXECUTE') then
      raise exception 'Missing runtime execute: %',signature;
    end if;
  end loop;
end $$;

-- `reverse_past_game` remains an authenticated legacy-compatible public
-- boundary.  Its final Stage 6 definition scopes the game through
-- current_facility_id() and delegates hybrid reconciliation to private helpers.
do $$
declare signature text := 'public.reverse_past_game(uuid)';
begin
  if has_function_privilege('public',signature,'EXECUTE')
    or has_function_privilege('anon',signature,'EXECUTE')
    or not has_function_privilege('authenticated',signature,'EXECUTE')
  then
    raise exception 'Exact Reverse public boundary ACL is incorrect';
  end if;
  if not exists(
    select 1 from pg_proc
    where oid=signature::regprocedure
      and prosecdef
      and 'search_path=public'=any(coalesce(proconfig,'{}'))
  ) then
    raise exception 'Exact Reverse SECURITY DEFINER search_path is unsafe';
  end if;
end $$;
