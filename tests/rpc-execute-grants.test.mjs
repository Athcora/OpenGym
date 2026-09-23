import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';

const app=readFileSync(new URL('../app/WaitlistApp.tsx',import.meta.url),'utf8');
const sql=readFileSync(new URL('../supabase/harden-rpc-execute-grants.sql',import.meta.url),'utf8');

test('the browser RPC surface is explicitly authenticated-only, not PUBLIC or anon',()=>{
  assert.match(sql,/revoke all on all functions in schema public from public, anon, authenticated/);
  assert.match(sql,/alter default privileges for role postgres in schema public[\s\S]*revoke execute on functions from public/);
  assert.match(sql,/alter default privileges for role opengym_runtime in schema public[\s\S]*revoke execute on functions from public/);
  assert.match(sql,/grant execute on function %s to authenticated/);
});

test('every direct browser RPC is represented in the explicit allowlist',()=>{
  const rpcNames=[...app.matchAll(/rpc\(['\"]([^'\"]+)/g)].map(match=>match[1]);
  for(const name of new Set(rpcNames)){
    assert.match(sql,new RegExp(`'${name}'`),`missing authenticated grant for ${name}`);
  }
});

test('RLS support helper remains executable without becoming a client RPC',()=>{
  assert.match(sql,/'current_facility_id'/);
  assert.doesNotMatch(app,/rpc\(['"]current_facility_id/);
});

test('sensitive internal helpers are not in the browser allowlist',()=>{
  for(const name of ['capture_waitlist_state','capture_court_reversal_state','record_court_reversal','repair_facility_court_assignments']){
    assert.doesNotMatch(sql,new RegExp(`'${name}'`));
  }
});
