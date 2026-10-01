import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';

const source=readFileSync('app/WaitlistApp.tsx','utf8');

test('hybrid KOTC refresh replaces stale client state from the authoritative board',()=>{
  assert.match(source,/mode==='hybrid_waitlist'&&currentConfig\.hybrid_rotation_rule==='kotc'/);
  assert.match(source,/supabase\.rpc\('read_hybrid_kotc_board'\)/);
  assert.match(source,/hybridRequest===hybridBoardRequest\.current/);
  assert.match(source,/setHybridKOTCBoard\(board\)/);
  assert.match(source,/setHybridKOTCBoard\(null\)/);
});

test('hybrid mutations invalidate through realtime and reconnect',()=>{
  for(const table of ['hybrid_kotc_teams','hybrid_kotc_slots','hybrid_kotc_substitutes','hybrid_kotc_court_state']){
    assert.match(source,new RegExp(`table:'${table}'\\},scheduleRefresh`));
  }
  assert.match(source,/status==='SUBSCRIBED';if\(realtimeConnected\.current\)scheduleRefresh\(\)/);
});

test('the hybrid board observer is development-only, explicitly enabled, and read-only',()=>{
  assert.match(source,/import\.meta\.env\.DEV\|\|import\.meta\.env\.VITE_OPEN_GYM_E2E!=='1'/);
  assert.match(source,/__OPEN_GYM_E2E__=\{hybridKOTCBoard:\(\)=>hybridKOTCBoard===null\?null:structuredClone\(hybridKOTCBoard\)\}/);
  assert.match(source,/delete target\.__OPEN_GYM_E2E__/);
});
