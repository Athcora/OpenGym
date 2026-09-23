import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const sql=readFileSync(new URL('../supabase/fix-mode-switch-facility-scope.sql',import.meta.url),'utf8');

test('mode switching is bound to the selected facility',()=>{
  assert.match(sql,/fid uuid:=public\.current_facility_id\(\)/);
  assert.match(sql,/not public\.is_waitlist_admin\(\)/);
  for(const table of ['waitlist_config','waitlist_courts','rejoin_responses','waitlist_players','team_fill_ins','team_substitute_requests','team_substitutes','king_teams','king_mode_state']) {
    assert.match(sql,new RegExp(`${table}[\\s\\S]{0,180}facility_id=fid`),`${table} must be scoped`);
  }
  assert.doesNotMatch(sql,/where true/i);
});

test('team initialization uses the selected facility for every roster mutation',()=>{
  assert.match(sql,/insert into public\.king_teams\(facility_id,name,queue_position\)/);
  assert.match(sql,/where facility_id=fid and status<>'left' and team_id is null/);
  assert.match(sql,/where facility_id=fid and id=player_row\.id/);
});
