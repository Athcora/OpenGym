import assert from 'node:assert/strict';
import test from 'node:test';
import {readFileSync} from 'node:fs';

const migration=readFileSync(new URL('../supabase/migrations/20260925110000_fix-offline-rejoin-court-allocation.sql',import.meta.url),'utf8');

test('offline rejoin acceptance is serialized and uses the court allocator',()=>{
  assert.match(migration,/pg_advisory_xact_lock\(7429101\)/);
  assert.match(migration,/status=case when p_stay then 'waiting' else 'left' end/);
  assert.match(migration,/court_number=null/);
  assert.match(migration,/perform public\.fill_open_court_slots\(\)/);
  assert.match(migration,/restored\.status='current'/);
});

test('offline rejoin remains facility-bound and preserves its execute boundary',()=>{
  assert.match(migration,/fid uuid:=public\.current_facility_id\(\)/);
  assert.match(migration,/id=p_player_id and facility_id=fid and user_id is null and status='rejoin'/);
  assert.match(migration,/where id=player\.id and facility_id=fid/);
  assert.match(migration,/revoke all on function public\.admin_answer_offline_rejoin\(uuid,boolean\) from public,anon/);
  assert.match(migration,/grant execute on function public\.admin_answer_offline_rejoin\(uuid,boolean\) to authenticated/);
});
