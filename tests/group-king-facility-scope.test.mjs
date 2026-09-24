import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const sql = readFileSync(new URL('../supabase/fix-group-and-king-action-facility-scope.sql', import.meta.url), 'utf8').toLowerCase();
const functions = ['admin_group_players','admin_remove_player_from_group','leave_player_group','remove_player_from_group','join_king_team','join_new_king_team','king_prepare_player'];

test('group and King roster replacements preserve browser signatures in one transaction', () => {
  assert.match(sql, /\bbegin;/);
  assert.match(sql, /commit;\s*$/);
  for (const name of functions) assert.ok(sql.includes(`create or replace function public.${name}(`), name);
});

test('all group and King player/team/group reads and mutations use the selected facility', () => {
  for (const name of functions) {
    const start = sql.indexOf(`function public.${name}(`);
    const next = sql.indexOf('create or replace function public.', start + 10);
    const body = sql.slice(start, next < 0 ? sql.length : next);
    assert.match(body, /current_facility_id\(\)/, name);
    for (const table of ['waitlist_players','king_teams','group_notifications']) {
      if (body.includes(`public.${table}`)) assert.match(body, new RegExp(`facility_id=fid[\\s\\S]*public\\.${table}|public\\.${table}[\\s\\S]*facility_id=fid`), `${name}: ${table}`);
    }
  }
  assert.match(sql, /perform public\.king_fill_courts\(\)/);
  assert.match(sql, /perform public\.fill_open_court_slots\(\)/);
});

test('existing authenticated RPC execute boundaries are retained', () => {
  for (const name of ['admin_group_players(uuid[])','admin_remove_player_from_group(uuid)','leave_player_group()','remove_player_from_group(uuid)','join_king_team(uuid,uuid)','join_new_king_team(uuid)','king_prepare_player(uuid)']) {
    const escaped = name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    assert.match(sql, new RegExp(`grant execute on function public\\.${escaped} to authenticated`));
  }
});
