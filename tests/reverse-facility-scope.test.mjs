import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';

const sql=readFileSync(new URL('../supabase/fix-reverse-game-facility-scope.sql',import.meta.url),'utf8');

test('reversal snapshots are isolated to the active facility',()=>{
  assert.match(sql,/with f as \(select public\.current_facility_id\(\) as id\)/);
  for(const table of ['waitlist_players','waitlist_config','waitlist_courts','king_teams','past_games','team_fill_ins','team_substitutes','rejoin_responses']){
    assert.match(sql,new RegExp(`public\\.${table}[^\\n]*facility_id=f\\.id`),`${table} snapshot is facility scoped`);
  }
});

test('reverse lookup, merge, deletion, and queue normalization all constrain facility_id',()=>{
  assert.match(sql,/from public\.past_games where facility_id=fid and id=p_game_id for update/);
  assert.match(sql,/from public\.waitlist_courts where facility_id=fid and court_number=game\.court_number for update/);
  assert.match(sql,/select to_jsonb\(t\) from public\.%I t where id=\$1 and facility_id=\$2 for update/);
  assert.match(sql,/delete from public\.past_games where facility_id=fid and id=game\.id/);
  assert.match(sql,/where facility_id=\$1 and queue_position is not null/);
  assert.match(sql,/delete from public\.rejoin_responses r where r\.facility_id=fid/);
  assert.match(sql,/update public\.king_round_history set reversed_at=now\(\) where facility_id=fid/);
});

test('old globally-captured snapshots cannot introduce another facility into a reversal',()=>{
  assert.match(sql,/where \(coalesce\(b\.value,a\.value\)->>'facility_id'\)::uuid=fid/);
  assert.match(sql,/and \(previous->>'facility_id'\)::uuid=fid/);
  assert.match(sql,/where \(value->>'facility_id'\)::uuid=fid and \(value->>'id'\)::uuid=any\(touched\)/);
});
