import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const sql = readFileSync(new URL('../supabase/fix-admin-member-directory-facility-scope.sql', import.meta.url), 'utf8').toLowerCase();

test('facility admins see only selected-facility account rows; platform admins retain global directory access', () => {
  assert.match(sql, /begin;[\s\S]*create or replace function public\.admin_list_members\(\)/);
  assert.match(sql, /fid uuid:=public\.current_facility_id\(\)/);
  assert.match(sql, /if not public\.is_waitlist_admin\(\)/);
  assert.match(sql, /auth\.jwt\(\)->'app_metadata'->>'role'\)='admin'/);
  assert.match(sql, /join public\.waitlist_players p on p\.user_id=u\.id and p\.facility_id=fid/);
  assert.match(sql, /where not u\.is_anonymous/);
  assert.match(sql, /left join public\.waitlist_players p on p\.user_id=u\.id/);
  assert.match(sql, /alter function public\.admin_list_members\(\) owner to postgres/);
  assert.match(sql, /grant execute on function public\.admin_list_members\(\) to authenticated/);
  assert.match(sql, /commit;\s*$/);
});
