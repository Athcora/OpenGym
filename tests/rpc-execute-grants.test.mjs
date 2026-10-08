import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync,readdirSync} from 'node:fs';

const app=readFileSync(new URL('../app/WaitlistApp.tsx',import.meta.url),'utf8');
const sql=readFileSync(new URL('../supabase/harden-rpc-execute-grants.sql',import.meta.url),'utf8');
const hybridBoardGrant=readFileSync(new URL('../supabase/migrations/20260929230203_hybrid_kotc_board_read_model.sql',import.meta.url),'utf8');
const waitlistNewGrants=readFileSync(new URL('../supabase/migrations/20261006033802_waitlist_new_mode.sql',import.meta.url),'utf8');
const migrationsDir=new URL('../supabase/migrations/',import.meta.url);
const allMigrationGrants=readdirSync(migrationsDir).filter(name=>name.endsWith('.sql')).map(name=>readFileSync(new URL(name,migrationsDir),'utf8')).join('\n');

test('the browser RPC surface is explicitly authenticated-only, not PUBLIC or anon',()=>{
  assert.match(sql,/revoke all on all functions in schema public from public, anon, authenticated/);
  assert.match(sql,/alter default privileges for role postgres in schema public[\s\S]*revoke execute on functions from public/);
  assert.match(sql,/alter default privileges for role opengym_runtime in schema public[\s\S]*revoke execute on functions from public/);
  assert.match(sql,/grant execute on function %s to authenticated/);
});

test('every direct browser RPC is represented in the explicit allowlist',()=>{
  const rpcNames=[...app.matchAll(/rpc\(['\"]([^'\"]+)/g)].map(match=>match[1]);
  for(const name of new Set(rpcNames)){
    const authorizedByFinalMigration=name==='read_hybrid_kotc_board'
      && new RegExp(`grant execute on function public\\.${name}\\(\\) to authenticated`).test(hybridBoardGrant);
    const authorizedByWaitlistNew=new RegExp(`grant execute on function public\\.${name}\\([^)]*\\) to authenticated`).test(waitlistNewGrants);
    const authorizedByLaterMigration=new RegExp(`grant execute on function public\\.${name}\\([^)]*\\) to authenticated`).test(allMigrationGrants);
    assert.ok(authorizedByFinalMigration||authorizedByWaitlistNew||authorizedByLaterMigration||new RegExp(`'${name}'`).test(sql),`missing authenticated grant for ${name}`);
  }
});

test('the inner join helper stays private while the device-guarded entrypoint remains public to authenticated clients',()=>{
  const allowlist=sql.slice(sql.indexOf('allowed_names text[]'),sql.indexOf('found_names text[]'));
  assert.match(allowlist,/'join_waitlist_for_device'/);
  assert.doesNotMatch(allowlist,/'join_waitlist'/);
  assert.doesNotMatch(app,/rpc\(['"]join_waitlist['"]/);
});

test('RLS support helpers remain executable without becoming client RPCs',()=>{
  for(const name of ['current_facility_id','is_waitlist_admin']){
    assert.match(sql,new RegExp(`'${name}'`));
    assert.doesNotMatch(app,new RegExp(`rpc\\(['\"]${name}`));
  }
});

test('sensitive internal helpers are not in the browser allowlist',()=>{
  for(const name of ['capture_waitlist_state','capture_court_reversal_state','record_court_reversal','repair_facility_court_assignments']){
    assert.doesNotMatch(sql,new RegExp(`'${name}'`));
  }
});
