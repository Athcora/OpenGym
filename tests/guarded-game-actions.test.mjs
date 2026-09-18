import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';

const sql=readFileSync(new URL('../supabase/guarded-game-actions.sql',import.meta.url),'utf8');
const app=readFileSync(new URL('../app/WaitlistApp.tsx',import.meta.url),'utf8');

test('server-side guards lock the shared facility session and reject stale court games',()=>{
  assert.match(sql,/from public\.user_facility_sessions[\s\S]*?for share/);
  assert.match(sql,/selected is distinct from p_facility_id/);
  assert.match(sql,/where facility_id=p_facility_id and court_number=p_court_number for update/);
  assert.match(sql,/current_game is distinct from p_game_number/);
});

test('all Next Game paths and past-game reversal carry the facility and observed game',()=>{
  assert.match(app,/rpc\('advance_court_game',\{p_court_number:courtNumber,p_facility_id:activeFacility\.id,p_expected_game_number:expectedGame\}\)/);
  assert.match(app,/rpc\('advance_team_rotation',\{p_court_number:courtNumber,p_facility_id:activeFacility\.id,p_expected_game_number:expectedGame\}\)/);
  assert.match(app,/rpc\('advance_team_king_game',\{p_court_number:courtNumber,p_winning_team_id:winnerId,p_facility_id:activeFacility\.id,p_expected_game_number:expectedGame\}\)/);
  assert.match(app,/rpc\('reverse_past_game_guarded',\{p_game_id:game\.id,p_facility_id:facilityRef\.current\?\.id\}\)/);
});

test('every standard confirmation captures the displayed court and game before realtime can refresh it',()=>{
  assert.doesNotMatch(app,/action===advanceGame/);
  assert.match(app,/const courtNumber=me\.court_number\?\?courts\[0\]\?\.court_number\?\?1;const gameNumber=courts\.find/);
  assert.match(app,/\(\)=>advanceGame\(courtNumber,gameNumber\)/);
  assert.match(app,/const courtNumber=court\.court_number;const gameNumber=court\.game_number;ask\(`Start next game on Court/);
  assert.match(app,/const expectedGame=confirmedGame\?\?courts\.find/);
});

test('direct vulnerable advancement and reversal RPCs are unavailable to authenticated clients',()=>{
  for(const signature of ['end_court_game(integer)','end_team_rotation(integer)','end_team_king_game(integer,uuid)','reverse_past_game(uuid)']){
    assert.match(sql,new RegExp(`revoke execute on function public\\.${signature.replace(/[()]/g,'\\$&')} from authenticated`));
  }
});
