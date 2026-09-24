import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const root = new URL('../', import.meta.url);
const app = readFileSync(new URL('app/WaitlistApp.tsx', root), 'utf8');
const sql = readFileSync(new URL('supabase/guard-rejoin-at-back-facility-context.sql', root), 'utf8').toLowerCase();
const migration = readFileSync(new URL('supabase/migrations/20260924070000_guard-rejoin-at-back-facility-context.sql', root), 'utf8');
const grants = readFileSync(new URL('supabase/harden-rpc-execute-grants.sql', root), 'utf8');

test('rejoin at back binds the browser-rendered facility and checks it again under the action lock', () => {
  assert.match(app, /rpc\('rejoin_waitlist_at_back_for_facility',\{p_expected_facility:facility\.id\},false\)/);
  assert.match(sql, /function public\.rejoin_waitlist_at_back_for_facility\(p_expected_facility uuid\)/);
  assert.match(sql, /p_expected_facility is null or p_expected_facility is distinct from fid/);
  assert.match(sql, /pg_advisory_xact_lock\(7429101\)/);
  assert.match(sql, /fid:=public\.current_facility_id\(\);[\s\S]*?p_expected_facility is distinct from fid/);
  assert.match(sql, /where facility_id=fid and user_id=auth\.uid\(\) for update/);
  assert.match(sql, /where facility_id=fid and id=player\.id/);
  assert.match(sql, /where facility_id=fid and user_id=auth\.uid\(\) and choice is null/);
});

test('rejoin at back keeps the complete helper and trigger path facility scoped and executable only by authenticated', () => {
  assert.match(sql, /delete from public\.king_teams where facility_id=fid and id=old_team_id/);
  assert.match(sql, /public\.join_waitlist\(player\.first_name,player\.last_name\)/);
  assert.match(sql, /public\.king_prepare_player\(player\.id\)/);
  assert.match(sql, /where facility_id=new\.facility_id and id=new\.team_id/);
  assert.match(sql, /insert into public\.waitlist_events\(facility_id,actor_user_id/);
  assert.match(sql, /values\(new\.facility_id,new\.user_id/);
  assert.match(sql, /revoke all on function public\.rejoin_waitlist_at_back\(\) from public, anon, authenticated/);
  assert.match(sql, /grant execute on function public\.rejoin_waitlist_at_back_for_facility\(uuid\) to authenticated/);
  assert.match(grants, /'rejoin_waitlist_at_back_for_facility'/);
  assert.doesNotMatch(grants, /'rejoin_waitlist_at_back'/);
  assert.equal(migration.toLowerCase().slice(migration.indexOf('begin;')).replace(/\r\n/g, '\n'), sql.slice(sql.indexOf('begin;')).replace(/\r\n/g, '\n'));
});
