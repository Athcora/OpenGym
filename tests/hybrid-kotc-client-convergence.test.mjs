import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';

const source=readFileSync('app/WaitlistApp.tsx','utf8');
const boardSource=readFileSync('app/HybridWaitlistBoard.tsx','utf8');
const e2eSource=readFileSync('tests/e2e/hybrid-kotc-client-convergence.spec.ts','utf8');

test('hybrid KOTC refresh replaces stale client state from the authoritative board',()=>{
  assert.match(source,/currentConfig\?\.mode==='hybrid_waitlist'/);
  assert.match(source,/supabase\.rpc\('read_hybrid_kotc_board'\)/);
  assert.match(source,/hybridRequest===hybridBoardRequest\.current/);
  assert.match(source,/setHybridKOTCBoard\(board\)/);
  assert.match(source,/setHybridKOTCBoard\(null\)/);
  assert.match(source,/type HybridCourt = \{court_number:number;game_number:number;rotation_rule:'kotc'\|'two_on_two_off'/);
  assert.match(source,/const hybridKotcCourts=\(hybridKOTCBoard as HybridBoard\|null\)\?\.courts\.filter\(court=>court\.rotation_rule==='kotc'\)\?\?\[\]/);
  assert.match(source,/p_expected_config_version:court\.config_version/);
  assert.match(source,/courts\.filter\(court=>!isHybridWaitlist\|\|court\.hybrid_rotation_rule!=='kotc'\)\.map/);
});

test('hydrated board courts select renderers from rotation_rule while configuration rows retain hybrid_rotation_rule',()=>{
  assert.match(boardSource,/type Court=\{court_number:number;rotation_rule:'kotc'\|'two_on_two_off'/);
  assert.match(boardSource,/const kotcCourts=board\.courts\.filter\(court=>court\.rotation_rule==='kotc'\)/);
  assert.doesNotMatch(boardSource,/board\.courts\.filter\(court=>court\.hybrid_rotation_rule/);
  assert.match(source,/courts\.filter\(court=>!isHybridWaitlist\|\|court\.hybrid_rotation_rule!=='kotc'\)\.map/);
});

test('hybrid mutations invalidate through realtime and reconnect',()=>{
  for(const table of ['hybrid_kotc_teams','hybrid_kotc_slots','hybrid_kotc_substitutes','hybrid_kotc_court_state']){
    assert.match(source,new RegExp(`table:'${table}'\\},scheduleRefresh`));
  }
  assert.match(source,/status==='SUBSCRIBED';if\(realtimeConnected\.current\)scheduleRefresh\(\)/);
});

test('the hybrid board observer is development-only, explicitly enabled, and read-only',()=>{
  assert.match(source,/import\.meta\.env\.DEV\|\|import\.meta\.env\.VITE_OPEN_GYM_E2E!=='1'/);
  assert.match(source,/const hybridKOTCBoardRef=useRef<unknown\|null>\(null\)/);
  assert.match(source,/hybridKOTCBoardRef\.current=hybridKOTCBoard/);
  assert.match(source,/__OPEN_GYM_E2E__=\{hybridKOTCBoard:\(\)=>hybridKOTCBoardRef\.current===null\?null:structuredClone\(hybridKOTCBoardRef\.current\)\}/);
  assert.match(source,/delete target\.__OPEN_GYM_E2E__/);
});

test('the local browser harness optionally resolves routes through its runtime-only base URL',()=>{
  assert.match(e2eSource,/const baseUrl = process\.env\.OPEN_GYM_E2E_BASE_URL;/);
  assert.match(e2eSource,/return baseUrl \? new URL\(path, baseUrl\)\.toString\(\) : path;/);
  assert.ok(e2eSource.includes('page.goto(e2eUrl(`/g/${slug}`))'));
});

test('the disposable browser fixture explicitly creates mixed per-court formats',()=>{
  assert.ok(e2eSource.includes("'${facility}',1,1,'king','kotc',1,null,3"));
  assert.ok(e2eSource.includes("'${facility}',2,1,'regular','two_on_two_off',1,null,3"));
  assert.ok(e2eSource.includes("'${facility}',true,1,24,'hybrid_waitlist',2,false,'kotc'"));
});

test('the browser harness enters the existing Admin UI before asserting Admin-only controls',()=>{
  assert.match(e2eSource,/async function enterAdminManagement\(page: Page, credential: AdminCredential\)/);
  assert.match(e2eSource,/const managementContext = page\.locator\('\.facility-admin-context'\);/);
  assert.match(e2eSource,/if \(!await managementContext\.isVisible\(\)\.catch\(\(\) => false\)\) \{/);
  assert.match(e2eSource,/const dismissTutorial = async \(\) => \{/);
  assert.match(e2eSource,/await dismissTutorial\(\);/);
  assert.match(e2eSource,/const adminButton = page\.getByRole\('button', \{ name: 'Admin' \}\);/);
  assert.match(e2eSource,/await adminButton\.click\(\)/);
  assert.match(e2eSource,/getByRole\('heading', \{ name: 'Manage OpenGym' \}\)/);
  assert.match(e2eSource,/getByLabel\('Username'\)\.fill\(credential\.username\)/);
  assert.match(e2eSource,/getByLabel\('Password'\)\.fill\(credential\.password\)/);
  assert.match(e2eSource,/getByRole\('button', \{ name: 'Sign in' \}\)\.click\(\)/);
  assert.match(e2eSource,/expect\(managementContext\)\.toBeVisible\(\)/);
  assert.match(e2eSource,/enterAdminManagement\(pageA, \{ username: 'a', password: 'local-only-password' \}\)/);
  assert.match(e2eSource,/enterAdminManagement\(pageB, \{ username: 'b', password: 'local-only-password' \}\)/);
});
