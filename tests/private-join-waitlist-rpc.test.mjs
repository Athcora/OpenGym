import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const migration = readFileSync(new URL('../supabase/fix-private-join-waitlist-rpc.sql', import.meta.url), 'utf8').toLowerCase();
const allowlist = readFileSync(new URL('../supabase/harden-rpc-execute-grants.sql', import.meta.url), 'utf8').toLowerCase();
const waitlistFix = readFileSync(new URL('../supabase/fix-waitlist-read-join-geofence-facility-scope.sql', import.meta.url), 'utf8').toLowerCase();

test('direct join helper is revoked atomically while guarded device join remains authenticated', () => {
  assert.match(migration, /begin;[\s\S]*revoke all on function public\.join_waitlist\(text,text\) from public, anon, authenticated/);
  assert.match(migration, /has_function_privilege\('authenticated','public\.join_waitlist_for_device\(text,text,text\)','execute'\)/);
  assert.match(migration, /notify pgrst, 'reload schema';\s*commit;\s*$/);
});

test('the historical scope source and browser allowlist no longer expose the inner helper', () => {
  assert.doesNotMatch(waitlistFix, /grant execute on function public\.join_waitlist\(text,text\) to authenticated/);
  const allowlistBody = allowlist.slice(allowlist.indexOf('allowed_names text[]'), allowlist.indexOf('found_names text[]'));
  assert.match(allowlistBody, /'join_waitlist_for_device'/);
  assert.doesNotMatch(allowlistBody, /'join_waitlist'/);
});
