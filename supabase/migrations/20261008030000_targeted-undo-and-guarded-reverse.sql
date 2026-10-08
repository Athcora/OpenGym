-- Applied to production 2026-10-07. Audit L5 / S4 / S6 (Undo, Redo, Reverse next game).
--
-- Before: every admin/host action saved a picture of the whole facility, and Undo,
-- Redo and "Reverse next game" deleted every player/team/court/past-game row and
-- re-inserted the picture. That erased anyone who joined afterwards, let one
-- operator's Undo wipe another operator's later work, dropped device links,
-- wrote fake "joined the waitlist" history and rewrote past-game rosters.
--
-- After: while an action runs, a trigger records exactly which rows and fields it
-- changed (undo_changes). Undo puts back only those fields, and only where the
-- field still holds the value the action wrote; anything changed later by someone
-- else is kept. Rows the action created are removed and rows it deleted are
-- restored. Redo is the same in reverse. "Reverse next game" uses the same
-- mechanism and now also checks the facility and the game number on screen.
begin;

-- Old picture-based entries cannot be replayed safely; start the new log clean.
delete from public.admin_redo;
delete from public.admin_undo;

create table if not exists public.undo_changes(
  id bigserial primary key,
  entry_kind text not null check (entry_kind in ('undo','redo')),
  entry_id bigint not null,
  facility_id uuid,
  tbl text not null,
  pk jsonb not null,
  old_row jsonb,
  new_row jsonb,
  created_at timestamptz not null default now()
);
create index if not exists undo_changes_entry_idx on public.undo_changes(entry_kind, entry_id, id);
alter table public.undo_changes enable row level security;
revoke all on public.undo_changes from public, anon, authenticated;
grant select, insert, delete on public.undo_changes to opengym_runtime;
grant usage, select on sequence public.undo_changes_id_seq to opengym_runtime;
drop policy if exists runtime_access on public.undo_changes;
create policy runtime_access on public.undo_changes to opengym_runtime using (true) with check (true);

-- Records one row change into the undo/redo entry named by the transaction-local
-- setting opengym.undo_entry ('undo:<id>' or 'redo:<id>'). No setting, no record.
create or replace function public.record_undo_change()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  ctx text := nullif(current_setting('opengym.undo_entry', true), '');
  o jsonb; n jsonb; pk jsonb := '{}'::jsonb; k text;
begin
  if ctx is null then return null; end if;
  if tg_op<>'INSERT' then o := to_jsonb(old); end if;
  if tg_op<>'DELETE' then n := to_jsonb(new); end if;
  if tg_op='UPDATE' and (o - 'updated_at') = (n - 'updated_at') then return null; end if;
  foreach k in array tg_argv loop
    pk := pk || jsonb_build_object(k, coalesce(n, o)->k);
  end loop;
  insert into public.undo_changes(entry_kind, entry_id, facility_id, tbl, pk, old_row, new_row)
    values(split_part(ctx, ':', 1), split_part(ctx, ':', 2)::bigint,
           nullif(coalesce(n, o)->>'facility_id', '')::uuid, tg_table_name, pk, o, n);
  return null;
end;
$function$;
alter function public.record_undo_change() owner to opengym_runtime;

do $triggers$
declare t record;
begin
  for t in select * from (values
    ('waitlist_players', 'id'), ('king_teams', 'id'), ('waitlist_config', 'id,facility_id'),
    ('waitlist_courts', 'court_number,facility_id'), ('past_games', 'id'), ('team_fill_ins', 'id'),
    ('team_substitutes', 'id'), ('hybrid_kotc_court_state', 'facility_id,court_number'),
    ('hybrid_kotc_slots', 'id'), ('hybrid_kotc_substitutes', 'id'), ('hybrid_kotc_teams', 'id'),
    ('king_mode_state', 'id,facility_id'), ('rejoin_responses', 'id'),
    ('wl_kotc_state', 'facility_id,court_number,game_number'), ('wl_party_substitutes', 'id'),
    ('wl_court_settings', 'facility_id,court_number'), ('wl_facility_settings', 'facility_id'),
    ('king_round_history', 'id'), ('court_game_reversals', 'game_id')
  ) as x(tbl, pk)
  loop
    execute format('drop trigger if exists zz_record_undo_change on public.%I', t.tbl);
    execute format('create trigger zz_record_undo_change after insert or update or delete on public.%I '
      || 'for each row execute function public.record_undo_change(%s)', t.tbl,
      (select string_agg(quote_literal(c), ',') from unnest(string_to_array(t.pk, ',')) c));
  end loop;
end
$triggers$;

-- Removing an undo/redo entry removes its change log.
create or replace function public.delete_undo_changes()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
begin
  delete from public.undo_changes where entry_kind=tg_argv[0] and entry_id=old.id;
  return null;
end;
$function$;
alter function public.delete_undo_changes() owner to opengym_runtime;
drop trigger if exists delete_undo_changes on public.admin_undo;
create trigger delete_undo_changes after delete on public.admin_undo for each row execute function public.delete_undo_changes('undo');
drop trigger if exists delete_undo_changes on public.admin_redo;
create trigger delete_undo_changes after delete on public.admin_redo for each row execute function public.delete_undo_changes('redo');

-- Start an undo entry for the action that is about to run in this transaction.
create or replace function public.save_admin_undo(p_label text)
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare fid uuid := public.current_facility_id(); new_id bigint;
begin
  perform public.lock_facility(); /* per-facility lock (audit L2/L3) */
  if fid is null then raise exception 'Select a facility first.'; end if;
  insert into public.admin_undo(facility_id, admin_user_id, label, snapshot)
    values(fid, public.current_request_user_id(), p_label,
           jsonb_build_object('config', (select to_jsonb(c) from public.waitlist_config c where c.facility_id=fid and c.id)))
    returning id into new_id;
  perform set_config('opengym.undo_entry', 'undo:'||new_id, true);
  delete from public.admin_undo where facility_id=fid and admin_user_id=public.current_request_user_id()
    and id not in (select id from public.admin_undo where facility_id=fid and admin_user_id=public.current_request_user_id() order by id desc limit 5);
  delete from public.admin_redo where facility_id=fid and admin_user_id=public.current_request_user_id();
end;
$function$;

-- Revert one entry's changes, field by field. Returns how many fields were kept
-- because someone changed them after the action.
create or replace function public.apply_undo_changes(p_kind text, p_entry_id bigint)
 returns integer
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  fid uuid := public.current_facility_id();
  parent_order constant text[] := array['waitlist_config','waitlist_courts','king_teams','hybrid_kotc_teams',
    'past_games','waitlist_players','king_mode_state','hybrid_kotc_court_state','wl_facility_settings','wl_court_settings'];
  c record; cur jsonb; target jsonb; k text; skipped integer := 0; pkcond text; setlist text; changed boolean;
begin
  for c in
    with ch as (
      select u.*, row_number() over (partition by u.tbl, u.pk order by u.id) first_rn,
                  row_number() over (partition by u.tbl, u.pk order by u.id desc) last_rn
      from public.undo_changes u where u.entry_kind=p_kind and u.entry_id=p_entry_id),
    net as (
      select f.tbl, f.pk, f.old_row net_old, l.new_row net_new
      from ch f join ch l on l.tbl=f.tbl and l.pk=f.pk and l.last_rn=1
      where f.first_rn=1)
    select net.*,
      case when net_new is null then 1 when net_old is null then 3 else 2 end as pass,
      coalesce(array_position(parent_order, tbl), 99) as prio
    from net
    where net_old is not null or net_new is not null
    order by pass,
      case when net_old is null then -coalesce(array_position(parent_order, tbl), 99)
           else coalesce(array_position(parent_order, tbl), 99) end
  loop
    select string_agg(format('t.%I = r.%I', key, key), ' and ') into pkcond from jsonb_object_keys(c.pk) key;
    execute format('select to_jsonb(t) from public.%I t, jsonb_populate_record(null::public.%I, $1) r where %s',
      c.tbl, c.tbl, pkcond) into cur using c.pk;

    if c.pass=1 then
      -- The action deleted this row: put it back unless it already exists again.
      if cur is null then
        execute format('insert into public.%I %s select * from jsonb_populate_record(null::public.%I, $1)',
          c.tbl, case when c.tbl='king_round_history' then 'overriding system value' else '' end, c.tbl)
          using c.net_old;
      else
        skipped := skipped+1;
      end if;
    elsif c.pass=3 then
      -- The action created this row: remove it.
      if cur is not null then
        execute format('delete from public.%I t using jsonb_populate_record(null::public.%I, $1) r where %s',
          c.tbl, c.tbl, pkcond) using c.pk;
      end if;
    else
      -- The action changed fields: restore each one that still holds the action's value.
      if cur is null then skipped := skipped+1; continue; end if;
      target := cur; changed := false;
      for k in select jsonb_object_keys(c.net_old) loop
        continue when k='updated_at';
        if (c.net_old->k) is distinct from (c.net_new->k) then
          if (cur->k) is not distinct from (c.net_new->k) then
            target := jsonb_set(target, array[k], coalesce(c.net_old->k, 'null'::jsonb));
            changed := true;
          else
            skipped := skipped+1;
          end if;
        end if;
      end loop;
      if changed then
        select string_agg(format('%I = r.%I', key, key), ', ') into setlist
          from jsonb_object_keys(target) key where (target->key) is distinct from (cur->key);
        if cur ? 'updated_at' then setlist := setlist||', updated_at = now()'; end if;
        execute format('update public.%I t set %s from jsonb_populate_record(null::public.%I, $1) r where %s',
          c.tbl, setlist, c.tbl, pkcond) using target;
      end if;
    end if;
  end loop;

  -- Players who joined after the action keep their place behind restored players.
  if exists(select 1 from public.waitlist_players where facility_id=fid and status in ('current','waiting','sitout')
              and queue_position is not null group by queue_position having count(*)>1) then
    with ranked as (
      select id, row_number() over(order by queue_position, updated_at desc, created_at, id) rn
      from public.waitlist_players
      where facility_id=fid and status in ('current','waiting','sitout') and queue_position is not null)
    update public.waitlist_players p set queue_position=ranked.rn from ranked where p.facility_id=fid and p.id=ranked.id;
  end if;
  perform public.king_fill_courts();
  perform public.king_repair_initial_team_names();
  return skipped;
end;
$function$;
alter function public.apply_undo_changes(text, bigint) owner to opengym_runtime;
revoke all on function public.apply_undo_changes(text, bigint) from public, anon, authenticated;

create or replace function public.admin_undo_last()
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare entry public.admin_undo; fid uuid := public.current_facility_id(); redo_id bigint; skipped integer;
begin
  perform public.lock_facility(); /* per-facility lock (audit L2/L3) */
  if fid is null or not public.is_waitlist_operator() then raise exception 'Admin or host access required.'; end if;
  select * into entry from public.admin_undo where facility_id=fid and admin_user_id=public.current_request_user_id()
    order by id desc limit 1 for update;
  if entry.id is null then raise exception 'Nothing to undo.'; end if;
  if not exists(select 1 from public.undo_changes where entry_kind='undo' and entry_id=entry.id) then
    delete from public.admin_undo where facility_id=fid and id=entry.id;
    return jsonb_build_object('message', 'Nothing to undo for: '||entry.label||'.');
  end if;
  insert into public.admin_redo(facility_id, admin_user_id, label, snapshot)
    values(fid, public.current_request_user_id(), entry.label, entry.snapshot) returning id into redo_id;
  delete from public.admin_redo where facility_id=fid and admin_user_id=public.current_request_user_id()
    and id not in (select id from public.admin_redo where facility_id=fid and admin_user_id=public.current_request_user_id() order by id desc limit 5);
  perform set_config('opengym.undo_entry', 'redo:'||redo_id, true);
  skipped := public.apply_undo_changes('undo', entry.id);
  perform set_config('opengym.undo_entry', '', true);
  delete from public.admin_undo where facility_id=fid and id=entry.id;
  perform public.log_waitlist_operator_action('admin_undo', 'undid: '||entry.label||'.');
  return jsonb_build_object('message', 'Undid: '||entry.label||'.'
    ||case when skipped>0 then ' Changes made since then by others were kept.' else '' end);
end;
$function$;

create or replace function public.admin_redo_last()
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare entry public.admin_redo; fid uuid := public.current_facility_id(); undo_id bigint; skipped integer;
begin
  perform public.lock_facility(); /* per-facility lock (audit L2/L3) */
  if fid is null or not public.is_waitlist_operator() then raise exception 'Admin or host access required.'; end if;
  select * into entry from public.admin_redo where facility_id=fid and admin_user_id=public.current_request_user_id()
    order by id desc limit 1 for update;
  if entry.id is null then raise exception 'Nothing to redo.'; end if;
  insert into public.admin_undo(facility_id, admin_user_id, label, snapshot)
    values(fid, public.current_request_user_id(), entry.label, entry.snapshot) returning id into undo_id;
  delete from public.admin_undo where facility_id=fid and admin_user_id=public.current_request_user_id()
    and id not in (select id from public.admin_undo where facility_id=fid and admin_user_id=public.current_request_user_id() order by id desc limit 5);
  perform set_config('opengym.undo_entry', 'undo:'||undo_id, true);
  skipped := public.apply_undo_changes('redo', entry.id);
  perform set_config('opengym.undo_entry', '', true);
  delete from public.admin_redo where facility_id=fid and id=entry.id;
  perform public.log_waitlist_operator_action('admin_redo', 'redid: '||entry.label||'.');
  return jsonb_build_object('message', 'Redid: '||entry.label||'.'
    ||case when skipped>0 then ' Changes made since then by others were kept.' else '' end);
end;
$function$;

-- Reverse next game: same targeted mechanism, plus facility and game-number checks.
grant execute on function public.assert_expected_facility(uuid) to opengym_runtime;
create or replace function public.reverse_next_game_guarded(p_facility_id uuid, p_expected_game integer)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  entry public.admin_undo; snapshot_game integer; current_game integer; actor text;
  fid uuid := public.current_facility_id(); skipped integer;
begin
  perform public.lock_facility(); /* per-facility lock (audit L2/L3) */
  if fid is null then raise exception 'Select a facility first.'; end if;
  if p_facility_id is not null then perform public.assert_expected_facility(p_facility_id); end if;
  if public.is_waitlist_operator() then
    select * into entry from public.admin_undo where facility_id=fid and label='start next game' order by id desc limit 1 for update;
  else
    select * into entry from public.admin_undo where facility_id=fid and label='start next game'
      and admin_user_id=public.current_request_user_id() order by id desc limit 1 for update;
  end if;
  if entry.id is null then raise exception 'There is no recent next-game action you can reverse.'; end if;
  select game_number into current_game from public.waitlist_config where facility_id=fid and id for update;
  if p_expected_game is not null and current_game is distinct from p_expected_game then
    raise exception 'This game has already changed. Refresh and try again.';
  end if;
  snapshot_game := (entry.snapshot->'config'->>'game_number')::integer;
  if snapshot_game is null or current_game<>snapshot_game+1 then
    raise exception 'This game can no longer be reversed because the waitlist has already advanced.';
  end if;
  perform set_config('opengym.undo_entry', '', true);
  skipped := public.apply_undo_changes('undo', entry.id);
  delete from public.rejoin_responses where facility_id=fid and game_number>snapshot_game;
  delete from public.admin_undo where facility_id=fid and id=entry.id;
  delete from public.admin_redo where facility_id=fid and admin_user_id=entry.admin_user_id;
  select coalesce(display_name, 'Admin') into actor from public.waitlist_players
    where facility_id=fid and user_id=public.current_request_user_id();
  insert into public.waitlist_events(facility_id, actor_user_id, actor_name, event_type, message)
    values(fid, public.current_request_user_id(), coalesce(actor, 'Admin'), 'next_game_reversed',
           coalesce(actor, 'Admin')||' reversed the start of Game '||(snapshot_game+1)||'.');
  return jsonb_build_object('message', 'Game '||(snapshot_game+1)||' was reversed. Game '||snapshot_game
    ||' and its queue order are restored.'
    ||case when skipped>0 then ' Changes made since then by others were kept.' else '' end);
end;
$function$;
alter function public.reverse_next_game_guarded(uuid, integer) owner to opengym_runtime;
revoke all on function public.reverse_next_game_guarded(uuid, integer) from public, anon;
grant execute on function public.reverse_next_game_guarded(uuid, integer) to authenticated;

-- Older app versions still call the unguarded name; route it through the same checks.
create or replace function public.reverse_next_game()
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
begin
  perform public.lock_facility(); /* per-facility lock (audit L2/L3) */
  return public.reverse_next_game_guarded(null, null);
end;
$function$;

-- Team next-game actions save their own undo entry inside the same transaction
-- (the app used to save it in a separate request, so nothing would be recorded).
create or replace function public.save_operator_undo(p_label text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
begin
  if public.current_facility_id() is null or not public.is_waitlist_operator() then
    raise exception 'Admin or host access required.';
  end if;
  return jsonb_build_object('saved', true);
end;
$function$;

do $advance$
declare body text; fn text; lbl text;
begin
  for fn, lbl in select * from (values ('advance_team_rotation','start next team game'),
                                       ('advance_team_king_game','start next king game')) v loop
    select pg_get_functiondef(p.oid) into body from pg_proc p join pg_namespace n on n.oid=p.pronamespace
      where n.nspname='public' and p.proname=fn;
    if body is null then raise exception 'Function % not found', fn; end if;
    if body !~ 'save_admin_undo' then
      if position('perform public.lock_facility(); /* per-facility lock (audit L2/L3) */' in body)=0 then
        raise exception 'Lock marker missing in %', fn;
      end if;
      body := replace(body, 'perform public.lock_facility(); /* per-facility lock (audit L2/L3) */',
        'perform public.lock_facility(); /* per-facility lock (audit L2/L3) */'
        ||E'\n  if public.is_waitlist_operator() then perform public.save_admin_undo('||quote_literal(lbl)||'); end if;');
      execute body;
    end if;
  end loop;
end
$advance$;

notify pgrst, 'reload schema';
commit;
