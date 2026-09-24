import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const migration = readFileSync(new URL('../supabase/fix-king-player-null-owner-authorization.sql', import.meta.url), 'utf8');
const cliMigration = readFileSync(new URL('../supabase/migrations/20260924052000_fix-king-player-null-owner-authorization.sql', import.meta.url), 'utf8');
const app = readFileSync(new URL('../app/WaitlistApp.tsx', import.meta.url), 'utf8');

test('King player ownership repair atomically null-hardens every reachable roster RPC', () => {
  assert.equal(cliMigration, migration);
  assert.match(migration, /\bbegin;/i);
  assert.match(migration, /join_king_team\(uuid,uuid\)/);
  assert.match(migration, /join_new_king_team\(uuid\)/);
  assert.match(migration, /king_prepare_player\(uuid\)/);
  assert.equal((migration.match(/player\.user_id<>auth\.uid\(\)/g) ?? []).length, 1);
  assert.match(migration, /player\.user_id is distinct from auth\.uid\(\)/);
  assert.match(migration, /Expected exactly one null-sensitive ownership guard/);
  assert.match(migration, /commit;/i);
});

test('King player preparation is reached after admin add and preserves browser RPC signatures', () => {
  assert.match(app, /supabase\.rpc\('admin_add_player'/);
  assert.match(app, /supabase\.rpc\('king_prepare_player',\{p_player_id:data\.player_id\}\)/);
  assert.match(app, /rpc\('join_king_team'/);
  assert.match(app, /rpc\('join_new_king_team'/);
  assert.match(migration, /join_king_team\(uuid,uuid\)/);
  assert.match(migration, /join_new_king_team\(uuid\)/);
  assert.match(migration, /king_prepare_player\(uuid\)/);
});
