import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const sql = readFileSync(new URL('../supabase/fix-substitute-facility-scope.sql', import.meta.url), 'utf8').toLowerCase();
test('substitute lifecycle replacements are atomic and preserve browser RPC signatures', () => {
  assert.match(sql, /\bbegin;/);
  assert.match(sql, /commit;\s*$/);
  for (const signature of [
    'request_player_substitute(p_target_id uuid)', 'answer_player_substitute(p_request_id uuid,p_accept boolean)',
    'request_team_substitute(p_team_id uuid,p_target_id uuid)', 'answer_team_substitute(p_request_id uuid,p_accept boolean)',
    'admin_remove_team_substitute(p_substitute_id uuid)',
  ]) assert.ok(sql.includes(signature), `missing ${signature}`);
});

test('substitute reads, mutations, requests, events, notifications and cleanup are facility constrained', () => {
  for (const name of ['request_player_substitute','answer_player_substitute','request_team_substitute','answer_team_substitute','admin_remove_team_substitute','cleanup_team_substitute_membership']) {
    const start = sql.indexOf(`function public.${name}(`);
    const next = sql.indexOf('create or replace function public.', start + 10);
    const body = sql.slice(start, next < 0 ? sql.length : next);
    if (name === 'cleanup_team_substitute_membership') assert.match(body, /fid uuid:=new\.facility_id/);
    else assert.match(body, /current_facility_id\(\)/, name);
    for (const table of ['waitlist_players','king_teams','substitute_requests','team_substitute_requests','team_substitutes','waitlist_events','group_notifications']) {
      if (body.includes(`public.${table}`)) assert.match(body, new RegExp(`public\\.${table}[\\s\\S]*?facility_id=fid|facility_id=fid[\\s\\S]*?public\\.${table}`), `${name}: ${table} scope`);
    }
  }
  assert.match(sql, /where facility_id=fid and id=p_substitute_id/);
  assert.match(sql, /perform public\.swap_waitlist_players\(request\.requester_id,request\.target_id\)/);
});

test('browser execute grants remain authenticated', () => {
  for (const name of ['request_player_substitute(uuid)','answer_player_substitute(uuid,boolean)','request_team_substitute(uuid,uuid)','answer_team_substitute(uuid,boolean)','admin_remove_team_substitute(uuid)']) {
    assert.match(sql, new RegExp(`grant execute on function public\\.${name.replace(/[()]/g, '\\$&')} to authenticated`));
  }
});
