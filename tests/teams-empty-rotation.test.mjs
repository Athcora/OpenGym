import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';

const sql=readFileSync(new URL('../supabase/preserve-empty-rotation-teams.sql',import.meta.url),'utf8');

test('a regular Teams rotation with no eligible waiting team keeps both current teams',()=>{
  assert.match(sql,/elsif eligible_waiting=0 then[\s\S]*?keep_first:=true; keep_second:=true;/);
  assert.match(sql,/status='waiting'[\s\S]*?not \(\(team_id=first_team\.id and keep_first\) or \(team_id=second_team\.id and keep_second\)\)/);
  assert.match(sql,/set status='current',court_number=p_court_number[\s\S]*?team_id=first_team\.id and keep_first/);
});

test('Teams rejoin retains its existing deficit behavior',()=>{
  assert.match(sql,/if cfg\.mode='teams_rejoin' then[\s\S]*?deficit:=greatest\(2-eligible_waiting,0\); keep_second:=deficit>=1; keep_first:=deficit>=2;/);
});
