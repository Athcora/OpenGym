import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const sql=readFileSync(new URL('../supabase/fix-admin-rpc-facility-scope.sql',import.meta.url),'utf8');

const wrappers=[
  'admin_move_player','admin_move_king_player','admin_move_king_player_to_empty',
  'swap_waitlist_players','admin_substitute_players','save_operator_undo','admin_set_court_count'
];

test('high-risk admin RPC wrappers capture the selected facility',()=>{
  for(const name of wrappers) {
    const start=sql.indexOf(`function public.${name}`);
    assert.ok(start>=0,`${name} replacement is present`);
    const body=sql.slice(start,sql.indexOf('$$;',start)+3);
    assert.match(body,/fid uuid:=public\.current_facility_id\(\)|public\.current_facility_id\(\) is null/,`${name} selects a facility`);
    assert.doesNotMatch(body,/where true/i,`${name} has no global mutation predicate`);
  }
});

test('admin player and team movement reject cross-facility identifiers before mutation',()=>{
  for(const fragment of [
    'where facility_id=fid and id=p_player_id for update',
    'where facility_id=fid and id=p_target_team_id for update',
    'where facility_id=fid and id=p_first_id and status in',
    'where facility_id=fid and id=p_second_id and status in',
  ]) assert.ok(sql.includes(fragment),`missing ${fragment}`);
});

test('court count and queue maintenance operate only on the selected facility',()=>{
  const start=sql.indexOf('function public.admin_set_court_count');
  const body=sql.slice(start,sql.indexOf('$$;',start)+3);
  for(const table of ['waitlist_config','waitlist_courts','waitlist_players','king_teams','past_games']) {
    assert.match(body,new RegExp(`${table}[\\s\\S]{0,200}facility_id=fid`),`${table} is scoped`);
  }
  assert.match(body,/on conflict\(facility_id,court_number\)/);
});
