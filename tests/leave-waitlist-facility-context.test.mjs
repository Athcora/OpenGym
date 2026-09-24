import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const app = readFileSync(new URL('../app/WaitlistApp.tsx', import.meta.url), 'utf8');
const migration = readFileSync(new URL('../supabase/fix-leave-waitlist-expected-facility.sql', import.meta.url), 'utf8');
const cliMigration = readFileSync(new URL('../supabase/migrations/20260924060000_leave-waitlist-expected-facility.sql', import.meta.url), 'utf8');
const grants = readFileSync(new URL('../supabase/harden-rpc-execute-grants.sql', import.meta.url), 'utf8');

test('leave RPC checks the initiating facility before reading or mutating player state', () => {
  assert.equal(cliMigration, migration);
  assert.match(migration, /function public\.leave_waitlist_for_facility\(p_expected_facility uuid\)/);
  assert.match(migration, /p_expected_facility is null or fid is distinct from p_expected_facility[\s\S]*?raise exception/);
  assert.match(migration, /where facility_id=fid and user_id=auth\.uid\(\) for update/);
  assert.match(migration, /update public\.rejoin_responses[\s\S]*where facility_id=fid and user_id=auth\.uid\(\) and choice is null/);
  assert.match(migration, /revoke all on function public\.leave_waitlist\(\) from public,anon,authenticated/);
  assert.match(migration, /grant execute on function public\.leave_waitlist_for_facility\(uuid\) to authenticated/);
});

test('all browser leave, timeout, and logout paths supply their rendered facility', () => {
  assert.match(app, /async function leaveWaitlistForFacility\(target=facilityRef\.current\)[\s\S]*ensureFacilityContext\(target\)[\s\S]*leave_waitlist_for_facility[\s\S]*p_expected_facility:target\.id/);
  assert.match(app, /async function expireRejoinSession\(\)[\s\S]*leaveWaitlistForFacility\(targetFacility\)/);
  assert.match(app, /async function leaveOwnWaitlist\(\)[\s\S]*leaveWaitlistForFacility\(facilityRef\.current\)/);
  assert.match(app, /leaveWaitlistForFacility\(facilityRef\.current\)[\s\S]*await logout\(\)/);
  assert.doesNotMatch(app, /(?:supabase\.)?rpc\(['"]leave_waitlist['"]/);
  assert.match(grants, /'leave_waitlist_for_facility'/);
  assert.doesNotMatch(grants, /'leave_waitlist'/);
});
