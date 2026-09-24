import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const sql = readFileSync(new URL('../supabase/fix-waitlist-read-join-geofence-facility-scope.sql', import.meta.url), 'utf8').toLowerCase();

const body = (name) => {
  const start = sql.indexOf(`function public.${name}`);
  assert.notEqual(start, -1, `${name} replacement exists`);
  const end = sql.indexOf('$$;', start);
  assert.notEqual(end, -1, `${name} body closes`);
  return sql.slice(start, end);
};

test('waitlist history, join, and rejoin stay bound to selected facility through trigger/fill helpers', () => {
  for (const name of ['admin_list_waitlist_history', 'join_waitlist', 'rejoin_waitlist_at_back']) {
    assert.match(body(name), /current_facility_id\(\)/);
  }
  assert.match(body('admin_list_waitlist_history'), /e\.facility_id=fid/);
  assert.match(body('join_waitlist'), /facility_id=fid/);
  assert.match(body('rejoin_waitlist_at_back'), /facility_id=fid/);
  assert.match(body('rejoin_waitlist_at_back'), /public\.join_waitlist\(/);
  assert.match(body('rejoin_waitlist_at_back'), /public\.king_prepare_player\(/);
  assert.match(body('log_waitlist_player_change'), /new\.facility_id/);
  assert.match(body('log_waitlist_player_change'), /insert into public\.waitlist_events\(facility_id,/);
});

test('rename rejects foreign player ids and checks name uniqueness only in the active facility', () => {
  const rename = body('rename_waitlist_player');
  assert.match(rename, /where facility_id=fid and id=p_player_id/);
  assert.match(rename, /where p\.facility_id=fid/);
  assert.match(rename, /where facility_id=fid and id=player\.id/);
});

test('geofence configuration read/write RPCs only target the selected facility and preserve browser signatures', () => {
  for (const name of ['admin_set_facility_location', 'admin_select_facility', 'verify_facility_location']) {
    assert.match(body(name), /current_facility_id\(\)/);
    assert.match(body(name), /facility_id=fid and id/);
  }
  for (const signature of [
    'admin_list_waitlist_history()', 'join_waitlist(text,text)', 'rejoin_waitlist_at_back()',
    'rename_waitlist_player(uuid,text,text)', 'admin_set_facility_location(double precision,double precision,integer)',
    'admin_select_facility(text)', 'verify_facility_location(double precision,double precision)',
  ]) assert.match(sql, new RegExp(`grant execute on function public\\.${signature.replaceAll('(', '\\(').replaceAll(')', '\\)')} to authenticated`));
});
