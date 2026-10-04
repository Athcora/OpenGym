import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';

const migration=readFileSync(new URL('../supabase/migrations/20261004233000_skip_kotc_courts_in_standard_slot_fill.sql',import.meta.url),'utf8');

test('standard slot allocation skips only target courts whose authoritative rule is KOTC',()=>{
  assert.match(migration,/for c in[\s\S]*from public\.waitlist_courts[\s\S]*where facility_id=fid[\s\S]*order by court_number/);
  assert.match(migration,/if public\.is_hybrid_kotc_court\(fid,c\.court_number\) then[\s\S]*continue;/);
  assert.match(migration,/p\.court_number=c\.court_number/);
  assert.doesNotMatch(migration,/cfg\.hybrid_rotation_rule/);
});

test('standard slot allocation retains the existing facility-local group and queue invariants',()=>{
  assert.match(migration,/p\.facility_id=fid\s+and p\.status='waiting'/);
  assert.match(migration,/status='waiting' and group_id=candidate\.group_id/);
  assert.match(migration,/where p\.facility_id=fid and p\.id=ranked\.id/);
  assert.match(migration,/security definer[\s\S]*set search_path=public/);
});

test('the allocation guard preserves a narrow authenticated execution boundary',()=>{
  assert.match(migration,/revoke all on function public\.fill_open_court_slots\(\) from public, anon/);
  assert.match(migration,/grant execute on function public\.fill_open_court_slots\(\) to authenticated/);
  assert.match(migration,/grant execute on function public\.is_hybrid_kotc_court\(uuid,integer\) to opengym_runtime/);
  assert.match(migration,/has_function_privilege\('authenticated','public\.is_hybrid_kotc_court\(uuid,integer\)','EXECUTE'\)/);
});
