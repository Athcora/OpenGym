import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';

const sql=readFileSync(new URL('../supabase/fix-team-fill-ins-facility-scope.sql',import.meta.url),'utf8');

test('one-game fill-in RPCs scope every caller-owned lookup and mutation to the active facility',()=>{
  assert.match(sql,/fid uuid:=public\.current_facility_id\(\)/);
  assert.match(sql,/id=p_sitter_id and facility_id=fid and status='sitout'/);
  assert.match(sql,/user_id=auth\.uid\(\) and facility_id=fid and status in\('current','waiting'\)/);
  assert.match(sql,/from public\.king_teams where id=sitter\.team_id and facility_id=fid/);
  assert.match(sql,/from public\.king_teams where id=filler\.team_id and facility_id=fid/);
  assert.match(sql,/public\.team_fill_ins\(facility_id,sitter_id,filler_id/);
  assert.match(sql,/public\.waitlist_events\(facility_id,actor_user_id/);
  assert.match(sql,/assignment\.facility_id=fid/);
  assert.match(sql,/player\.facility_id=fid/);
  assert.match(sql,/where facility_id=fid and sitter_id=player\.id/);
});

test('release and cleanup triggers cannot mutate similarly numbered courts in another facility',()=>{
  assert.match(sql,/p\.facility_id=new\.facility_id/);
  assert.match(sql,/f\.facility_id=new\.facility_id and t\.status='current' and t\.court_number=new\.court_number/);
  assert.match(sql,/f\.facility_id=new\.facility_id and t\.status='current' and t\.court_number=new\.court_number/);
  assert.match(sql,/facility_id=new\.facility_id and sitter_id=new\.id/);
  assert.match(sql,/facility_id=new\.facility_id and \(sitter_id=new\.id or filler_id=new\.id\)/);
});
