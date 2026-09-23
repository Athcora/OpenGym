import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';

const sql=readFileSync(new URL('../supabase/fix-admin-reset-facility-scope.sql',import.meta.url),'utf8');

test('browser-authorized reset helper is bound to the selected facility',()=>{
  assert.match(sql,/fid uuid:=public\.current_facility_id\(\)/);
  assert.match(sql,/if fid is null then raise exception 'Select a facility first\.'/);
  for(const table of [
    'team_fill_ins','team_substitute_requests','team_substitutes','waitlist_players',
    'king_round_history','king_teams','king_mode_state','past_games','group_requests',
    'rejoin_responses','group_notifications','substitute_requests','geofence_return_prompts',
    'waitlist_events','admin_undo','admin_redo'
  ]){
    assert.match(sql,new RegExp(`(?:delete from public\\.${table}|where facility_id=fid)`),`missing ${table} facility scope`);
  }
  assert.doesNotMatch(sql,/where true/i);
});

test('reset recreates only the selected facility court rows',()=>{
  assert.match(sql,/insert into public\.waitlist_courts\(facility_id,court_number,game_number,started_at\)/);
  assert.match(sql,/on conflict\(facility_id,court_number\)/);
});
