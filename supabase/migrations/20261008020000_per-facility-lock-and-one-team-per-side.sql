-- Applied to production 2026-10-07. Audit L2/L3 (race conditions).
--
-- Before: queue-changing functions serialized on seven different global advisory
-- lock numbers (7429101, 7429102, 7429103, 7429201, 7429202, 7429204, 7429301),
-- some took none, and guard wrappers took row locks before the advisory lock.
-- Two actions could therefore seat two teams on one court side, and Next Game vs
-- Reverse on the same court could deadlock. Every facility also waited on every
-- other facility.
--
-- After: one lock per facility, taken as the very first statement of every
-- browser-callable function that runs in plpgsql (and of the internal functions
-- that used the old numbers), so all actions in a facility take turns and always
-- lock in the same order. A deferred exclusion constraint makes "two current
-- teams on the same court side" impossible.
begin;

create or replace function public.lock_facility(p_facility uuid default null)
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
begin
  perform pg_advisory_xact_lock(hashtext('opengym:facility:'||coalesce(coalesce(p_facility,public.current_facility_id())::text,'none')));
end;
$function$;
revoke all on function public.lock_facility(uuid) from public, anon, authenticated;
grant execute on function public.lock_facility(uuid) to opengym_runtime;

do $migration$
declare
  r record;
  body text;
  marker constant text := 'perform public.lock_facility(); /* per-facility lock (audit L2/L3) */';
  start_pos integer;
  changed integer := 0;
begin
  for r in
    select p.oid, p.proname, pg_get_functiondef(p.oid) as def
    from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace
    join pg_language l on l.oid=p.prolang
    where n.nspname='public' and p.prokind='f' and l.lanname='plpgsql'
      and pg_get_function_result(p.oid)<>'trigger'
      and p.provolatile='v'
      and p.proname not in ('lock_facility','select_facility','admin_select_facility','sign_in_waitlist_admin',
                            'create_facility','run_midnight_pacific_waitlist_reset','run_rejoin_expirations')
      and (has_function_privilege('authenticated',p.oid,'execute')
           or pg_get_functiondef(p.oid) ~ 'pg_advisory_xact_lock\((7429101|7429102|7429103|7429201|7429202|7429204|7429301)\)')
  loop
    body := regexp_replace(r.def,
      'pg_advisory_xact_lock\((7429101|7429102|7429103|7429201|7429202|7429204|7429301)\)',
      'public.lock_facility()', 'g');
    if position(marker in body)=0 then
      start_pos := position('$function$' in body);
      if start_pos=0 then raise exception 'No $function$ body in %', r.proname; end if;
      -- First BEGIN of the plpgsql body: take the facility lock before anything else.
      body := substr(body,1,start_pos-1)
        || regexp_replace(substr(body,start_pos), '\m(begin)\M', E'\\1\n  '||marker||E'\n', 'i');
    end if;
    if body is distinct from r.def then
      execute body;
      changed := changed+1;
    end if;
  end loop;

  -- The midnight reset loops over facilities: lock each facility as it is reset.
  select pg_get_functiondef(p.oid) into body from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname='run_midnight_pacific_waitlist_reset';
  if body !~ 'lock_facility\(facility\.id\)' then
    body := replace(body, 'perform pg_advisory_xact_lock(7429103);', '');
    if body !~ 'for facility in select f\.id from public\.facilities f where f\.active order by f\.id loop' then
      raise exception 'Midnight reset loop not found';
    end if;
    body := regexp_replace(body,
      '(for facility in select f\.id from public\.facilities f where f\.active order by f\.id loop)',
      E'\\1\n  perform public.lock_facility(facility.id);');
    execute body;
    changed := changed+1;
  end if;

  -- The rejoin-expiry job locks each facility before cleaning it.
  select pg_get_functiondef(p.oid) into body from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname='run_rejoin_expirations';
  if body !~ 'lock_facility\(f\.id\)' then
    body := replace(body, 'perform set_config(''opengym.facility_override'', f.id::text, true);',
      E'perform set_config(''opengym.facility_override'', f.id::text, true);\n    perform public.lock_facility(f.id);');
    execute body;
    changed := changed+1;
  end if;

  if exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
            where n.nspname='public' and p.prokind='f'
              and pg_get_functiondef(p.oid) ~ 'pg_advisory_xact_lock\((7429101|7429102|7429103|7429201|7429202|7429204|7429301)\)') then
    raise exception 'An old global lock number is still in use';
  end if;
  raise notice 'Per-facility lock added to % functions', changed;
end
$migration$;

-- At most one current team per court side, checked when each transaction commits
-- (so rotations that swap sides inside one action still work).
alter table public.king_teams drop constraint if exists king_teams_one_current_team_per_side;
alter table public.king_teams add constraint king_teams_one_current_team_per_side
  exclude using btree (facility_id with =, court_number with =, court_side with =)
  where (status='current' and court_number is not null and court_side is not null)
  deferrable initially deferred;

commit;
