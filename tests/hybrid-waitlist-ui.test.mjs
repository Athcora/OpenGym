import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';

const envSource=readFileSync('app/env.ts','utf8');
const app=readFileSync('app/WaitlistApp.tsx','utf8');
const board=readFileSync('app/HybridWaitlistBoard.tsx','utf8');

test('Waitlist is an explicit admin-selectable mode and KOTC is selected per court',()=>{
  assert.match(app,/<option value="hybrid_waitlist">Waitlist<\/option>/);
  assert.match(app,/const isHybridKotc=isHybridWaitlist&&hybridKotcCourts\.length>0/);
  assert.match(app,/court\.rotation_rule==='kotc'/);
  assert.match(app,/courts\.filter\(court=>!isHybridWaitlist\|\|court\.hybrid_rotation_rule!=='kotc'\)\.map/);
  assert.match(app,/King of the Court results must be recorded through the guarded court result flow/);
  assert.match(app,/hybrid-kotc-mode/);
});

test('production KOTC rendering is independent of the development E2E observer',()=>{
  assert.match(app,/<HybridKOTCBoard board=\{hybridKOTCBoard as HybridBoard\|null\}/);
  assert.match(app,/if\(!IS_LOCAL_E2E\)return;/);
  assert.match(envSource,/export const IS_LOCAL_E2E = viteEnv\.DEV === true && viteEnv\.VITE_OPEN_GYM_E2E === '1';/);
  assert.match(board,/Authoritative court board/);
  assert.match(board,/\[1,2,3,4,5,6\]\.map/);
  assert.match(board,/Temporary KOTC side — permanent groups are unchanged/);
});

test('KOTC UI uses only guarded hybrid RPC helpers and refresh-boundary actions',()=>{
  for(const rpc of ['advance_hybrid_kotc_game','confirm_hybrid_kotc_unknown_result','fill_hybrid_kotc_empty_slot','request_hybrid_kotc_substitute','answer_hybrid_kotc_substitute','cancel_hybrid_kotc_substitute_request','swap_hybrid_kotc_slot','sit_out_hybrid_kotc_player']) assert.match(app,new RegExp(`hybridRpc\\('${rpc}'`));
  assert.match(app,/await broadcastQueueRefresh\(\);\s*await refresh\(undefined,activeFacility,true\)/);
});

test('only admins receive mutable per-court Waitlist configuration controls, while hosts get view-only state',()=>{
  assert.match(board,/HybridCourtConfiguration/);
  assert.match(board,/\{admin\?<><label>Format<select/);
  assert.match(board,/hybrid-config-readonly/);
  assert.match(app,/hybrid-court-settings/);
  assert.match(app,/CURRENT GAME - Team 1 vs\. Team 2/);
  assert.match(app,/configure_hybrid_waitlist/);
});
