import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';

const sql=readFileSync(new URL('../supabase/fix-facility-scoped-role-helpers.sql',import.meta.url),'utf8');

test('facility admin sessions cannot authorize another selected facility',()=>{
  const admin=sql.match(/create or replace function public\.is_waitlist_admin\(\)[\s\S]*?\n\$\$;/i)?.[0] ?? '';
  assert.match(admin,/from public\.admin_sessions/i);
  assert.match(admin,/user_id\s*=\s*auth\.uid\(\)/i);
  assert.match(admin,/facility_id\s*=\s*public\.current_facility_id\(\)/i);
});

test('host and operator authorization is bound to the selected facility',()=>{
  const host=sql.match(/create or replace function public\.is_waitlist_host\(\)[\s\S]*?\n\$\$;/i)?.[0] ?? '';
  const operator=sql.match(/create or replace function public\.is_waitlist_operator\(\)[\s\S]*?\n\$\$;/i)?.[0] ?? '';
  assert.match(host,/user_id\s*=\s*auth\.uid\(\)/i);
  assert.match(host,/facility_id\s*=\s*public\.current_facility_id\(\)/i);
  assert.match(host,/is_host/i);
  assert.match(operator,/public\.is_waitlist_admin\(\)\s+or\s+public\.is_waitlist_host\(\)/i);
});
