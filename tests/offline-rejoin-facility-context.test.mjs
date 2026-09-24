import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';

const app=readFileSync(new URL('../app/WaitlistApp.tsx',import.meta.url),'utf8');
const migration=readFileSync(new URL('../supabase/fix-offline-rejoin-expected-facility.sql',import.meta.url),'utf8');
const cliMigration=readFileSync(new URL('../supabase/migrations/20260924061500_offline-rejoin-expected-facility.sql',import.meta.url),'utf8');
const grants=readFileSync(new URL('../supabase/harden-rpc-execute-grants.sql',import.meta.url),'utf8');

test('Accept all offline Rejoins is bound to the facility displayed by the initiating tab',()=>{
  assert.equal(cliMigration,migration);
  assert.match(app,/rpc\('admin_accept_all_offline_rejoins_for_facility',\{p_expected_facility:facilityRef\.current\?\.id\}/);
  assert.match(migration,/function public\.admin_accept_all_offline_rejoins_for_facility\(p_expected_facility uuid\)/);
  assert.match(migration,/p_expected_facility is null or fid is distinct from p_expected_facility[\s\S]*?raise exception 'Facility selection changed/);
  assert.match(migration,/where facility_id=fid and user_id is null and status='rejoin'/);
  assert.match(migration,/perform public\.admin_answer_offline_rejoin\(request\.id,true\)/);
});

test('the old unguarded batch RPC is private and the replacement keeps authenticated-only execution',()=>{
  assert.match(migration,/revoke all on function public\.admin_accept_all_offline_rejoins\(\) from public,anon,authenticated/);
  assert.match(migration,/grant execute on function public\.admin_accept_all_offline_rejoins_for_facility\(uuid\) to authenticated/);
  assert.match(migration,/has_function_privilege\('authenticated','public\.admin_accept_all_offline_rejoins\(\)','execute'\)/);
  assert.match(grants,/'admin_accept_all_offline_rejoins_for_facility'/);
  assert.doesNotMatch(grants,/'admin_accept_all_offline_rejoins'/);
});

test('per-player answers already reject request ids outside the selected facility',()=>{
  const answer=readFileSync(new URL('../supabase/fix-rejoin-facility-scope.sql',import.meta.url),'utf8');
  assert.match(answer,/function public\.admin_answer_offline_rejoin\(p_player_id uuid,p_stay boolean\)[\s\S]*where id=p_player_id and facility_id=fid and user_id is null and status='rejoin'/);
  assert.match(answer,/update public\.waitlist_players[\s\S]*where id=player\.id and facility_id=fid/);
});
