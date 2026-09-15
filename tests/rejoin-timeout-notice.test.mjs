import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';

const app=readFileSync(new URL('../app/WaitlistApp.tsx',import.meta.url),'utf8');

test('both rejoin modes automatically remove an expired player and explain why',()=>{
  assert.match(app,/config\.mode!==\'rejoin\'&&config\.mode!==\'teams_rejoin\'/);
  assert.match(app,/new Date\(rejoinResponse\.expires_at\)\.getTime\(\)>returnClock/);
  assert.match(app,/await supabase\.rpc\('leave_waitlist'\)[\s\S]*await logout\(\)[\s\S]*setNotice\(REJOIN_TIMEOUT_NOTICE\)/);
});

test('the timeout dialog uses the requested message and a neutral OK dismissal',()=>{
  assert.match(app,/title:'Rejoin time expired'/);
  assert.match(app,/You did not rejoin in time, so you were removed from the waitlist\. If you want to rejoin, sign up again\./);
  assert.match(app,/cancelLabel:'OK'/);
});
