import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

// Executable model of detach_group_member_preserving_queue. It deliberately
// works for any group size and keeps unrelated rows in their original order.
function detach(rows, departing) {
  const target = rows.find(row => row.id === departing);
  const group = target.group;
  const survivors = rows.filter(row => row.group === group && row.id !== departing);
  const before = survivors.some(row => row.position < target.position);
  const after = survivors.some(row => row.position > target.position);
  target.group = null;
  if (survivors.length >= 2 && before && after) {
    const first = Math.min(...survivors.map(row => row.position));
    const survivorIds = new Set(survivors.map(row => row.id));
    rows.sort((left, right) => {
      const key = row => survivorIds.has(row.id) || row.id === departing ? first : row.position;
      const kind = row => survivorIds.has(row.id) ? 0 : row.id === departing ? 1 : 2;
      return key(left) - key(right) || kind(left) - kind(right) || left.position - right.position;
    });
  }
  rows.forEach((row, index) => { row.position = index + 1; });
  return rows.map(row => row.id);
}

function grouped(ids, group = 'g') { return ids.map((id, index) => ({ id, group, position: index + 1 })); }
function order(ids, departing) { return detach(grouped(ids), departing); }

test('middle departures preserve arbitrary-size group order and place the departure after survivors', () => {
  assert.deepEqual(order(['A', 'B', 'C'], 'B'), ['A', 'C', 'B']);
  assert.deepEqual(order(['A', 'B', 'C', 'D', 'E'], 'C'), ['A', 'B', 'D', 'E', 'C']);
  assert.deepEqual(order(['A', 'B', 'C', 'D', 'E'], 'B'), ['A', 'C', 'D', 'E', 'B']);
  assert.deepEqual(order(['A', 'B', 'C', 'D', 'E'], 'D'), ['A', 'B', 'C', 'E', 'D']);
});

test('edge departures and a two-person group retain natural order', () => {
  assert.deepEqual(order(['A', 'B', 'C', 'D'], 'A'), ['A', 'B', 'C', 'D']);
  assert.deepEqual(order(['A', 'B', 'C', 'D'], 'D'), ['A', 'B', 'C', 'D']);
  assert.deepEqual(order(['A', 'B'], 'A'), ['A', 'B']);
});

test('unrelated rows and a nearby second group retain their relative order', () => {
  const rows = [
    { id: 'X', group: null, position: 1 },
    { id: 'A', group: 'one', position: 2 },
    { id: 'B', group: 'one', position: 3 },
    { id: 'C', group: 'one', position: 4 },
    { id: 'D', group: 'one', position: 5 },
    { id: 'Y', group: null, position: 6 },
    { id: 'M', group: 'two', position: 7 },
    { id: 'N', group: 'two', position: 8 },
  ];
  assert.deepEqual(detach(rows, 'C'), ['X', 'A', 'B', 'D', 'C', 'Y', 'M', 'N']);
  assert.deepEqual(rows.filter(row => row.group === 'two').map(row => row.id), ['M', 'N']);
  assert.deepEqual(rows.map(row => row.position), [1, 2, 3, 4, 5, 6, 7, 8]);
});

test('sequential interior departures never leave a split group or duplicate positions', () => {
  const rows = grouped(['A', 'B', 'C', 'D', 'E']);
  detach(rows, 'C');
  detach(rows, 'B');
  assert.deepEqual(rows.map(row => row.id), ['A', 'D', 'E', 'B', 'C']);
  assert.deepEqual(rows.filter(row => row.group === 'g').map(row => row.id), ['A', 'D', 'E']);
  assert.equal(new Set(rows.map(row => row.position)).size, rows.length);
});

test('all authoritative leave paths call the shared locked, normalized helper', () => {
  const sql = readFileSync(new URL('../supabase/migrations/20260925123000_preserve_group_queue_contiguity.sql', import.meta.url), 'utf8');
  assert.match(sql, /create or replace function public\.detach_group_member_preserving_queue/i);
  assert.match(sql, /row_number\(\) over\(\s*order by/i);
  assert.match(sql, /queue_position=-1000000-ranked\.new_rank/i);
  assert.match(sql, /queue_position=-queue_position-1000000/i);
  assert.equal((sql.match(/detach_group_member_preserving_queue\(fid,/g) ?? []).length, 3);
  for (const name of ['admin_remove_player_from_group', 'leave_player_group', 'remove_player_from_group']) {
    const start = sql.indexOf(`function public.${name}`);
    const next = sql.indexOf('create or replace function public.', start + 10);
    const body = sql.slice(start, next < 0 ? sql.length : next);
    assert.match(body, /current_facility_id\(\)/);
    assert.match(body, /pg_advisory_xact_lock\(7429102\)/);
  }
  assert.match(sql, /revoke all on function public\.detach_group_member_preserving_queue\(uuid,uuid,uuid\) from public, anon, authenticated/i);
});
