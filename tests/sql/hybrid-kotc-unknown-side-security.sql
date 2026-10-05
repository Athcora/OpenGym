-- Stage 5 ACL/search-path contract for the unknown-side selection boundary.
begin;
do $$
declare fn regprocedure;
begin
  foreach fn in array array[
    'public.create_hybrid_kotc_identified_side(integer,smallint,integer,uuid[])'::regprocedure,
    'public.replace_hybrid_kotc_reversal_before(jsonb,integer)'::regprocedure
  ] loop
    if has_function_privilege('public',fn,'execute') or has_function_privilege('anon',fn,'execute')
      or has_function_privilege('authenticated',fn,'execute')
    then raise exception 'Stage5 internal helper leaked execute: %',fn; end if;
  end loop;
  foreach fn in array array[
    'public.prepare_hybrid_kotc_result(integer,text,uuid,integer,bigint)'::regprocedure,
    'public.confirm_hybrid_kotc_unknown_result(integer,text,uuid,integer,bigint,uuid[])'::regprocedure,
    'public.advance_hybrid_kotc_game(integer,text,uuid,integer,bigint)'::regprocedure
  ] loop
    if has_function_privilege('public',fn,'execute') or has_function_privilege('anon',fn,'execute')
      or not has_function_privilege('authenticated',fn,'execute')
    then raise exception 'Stage5 public boundary ACL incorrect: %',fn; end if;
  end loop;
  if not exists(
    select 1 from pg_proc p where p.oid in (
      'public.create_hybrid_kotc_identified_side(integer,smallint,integer,uuid[])'::regprocedure,
      'public.replace_hybrid_kotc_reversal_before(jsonb,integer)'::regprocedure,
      'public.prepare_hybrid_kotc_result(integer,text,uuid,integer,bigint)'::regprocedure,
      'public.confirm_hybrid_kotc_unknown_result(integer,text,uuid,integer,bigint,uuid[])'::regprocedure,
      'public.advance_hybrid_kotc_game(integer,text,uuid,integer,bigint)'::regprocedure
    ) and p.prosecdef and p.proconfig @> array['search_path=public']
    group by 1 having count(*)=5
  ) then raise exception 'Stage5 SECURITY DEFINER search_path contract is incomplete'; end if;
end $$;
-- Demonstrate a client role cannot call the private materializer directly.
set local role authenticated;
do $$ begin
  perform public.create_hybrid_kotc_identified_side(1,1::smallint,1,array[gen_random_uuid()]);
  raise exception 'authenticated invoked an internal materializer';
exception when insufficient_privilege then null;
end $$;
rollback;
