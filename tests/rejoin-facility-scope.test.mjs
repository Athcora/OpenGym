import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';

const sql=readFileSync(new URL('../supabase/fix-rejoin-facility-scope.sql',import.meta.url),'utf8');
const app=readFileSync(new URL('../app/WaitlistApp.tsx',import.meta.url),'utf8');

test('player Rejoin answers bind prompt, player, team, config, and queue fill to the selected facility',()=>{
  assert.match(sql,/fid uuid:=public\.current_facility_id\(\)/);
  assert.match(sql,/where id=p_response_id and user_id=auth\.uid\(\) and facility_id=fid/);
  assert.match(sql,/where facility_id=fid and user_id=auth\.uid\(\)/);
  assert.match(sql,/where id=player\.team_id and facility_id=fid for update/);
  assert.match(sql,/where facility_id=fid and id for update/);
  assert.match(sql,/from public\.waitlist_players where facility_id=fid and status='current'/);
  assert.match(sql,/where facility_id=fid and status='waiting'/);
});

test('expiration cleanup and client prompt lookup cannot mutate or surface another facility',()=>{
  assert.match(sql,/where facility_id=fid and choice is null and expires_at<=now\(\)/);
  assert.match(sql,/where facility_id=fid and status='rejoin' and rejoin_expires_at<=now\(\)/);
  assert.match(sql,/where t\.facility_id=fid/);
  assert.match(app,/from\('rejoin_responses'\)[\s\S]*\.eq\('facility_id',expectedFacility\?\.id/);
  assert.match(app,/from\('waitlist_players'\)\.select\('\*'\)\.eq\('facility_id',expectedFacility\?\.id/);
});

test('timeout, leave, and operator offline-Rejoin helpers are facility-scoped too',()=>{
  assert.match(sql,/function public\.leave_waitlist\(\)[\s\S]*where facility_id=fid and user_id=auth\.uid\(\) for update/);
  assert.match(sql,/function public\.leave_waitlist\(\)[\s\S]*where facility_id=fid and status='waiting'/);
  assert.match(sql,/function public\.admin_list_offline_rejoins\(\)[\s\S]*where facility_id=fid and user_id is null and status='rejoin'/);
  assert.match(sql,/function public\.admin_answer_offline_rejoin\(p_player_id uuid,p_stay boolean\)[\s\S]*id=p_player_id and facility_id=fid and user_id is null and status='rejoin'/);
  assert.match(sql,/from public\.waitlist_config c[\s\S]*where c\.facility_id=fid and c\.id/);
  assert.match(app,/async function expireRejoinSession\(\)[\s\S]*ensureFacilityContext\(targetFacility\)[\s\S]*from\('waitlist_players'\)\.select\('status'\)\.eq\('facility_id',targetFacility\.id\)\.eq\('user_id',session\.user\.id\)/);
});
