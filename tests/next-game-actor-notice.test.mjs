import assert from 'node:assert/strict';
import fs from 'node:fs';
import test from 'node:test';

const app=fs.readFileSync(new URL('../app/WaitlistApp.tsx',import.meta.url),'utf8');

test('team advancements identify their initiator to affected players',()=>{
  assert.match(app,/event\.event_type==='team_rotation'\|\|event\.event_type==='king_game'/);
  assert.match(app,/event\.actor_user_id!==session\?\.user\.id/);
  assert.match(app,/`\$\{event\.actor_name\} has advanced the next game\. If you think this is a mistake, let an admin or host know\.`/);
  // A malformed current row with no court must not receive Court 1's update.
  assert.match(app,/player\.status!=='current'\|\|player\.court_number===courtNumber/);
});

test('rejoin players receive the advancement as a dismissible modal',()=>{
  assert.match(app,/if\(me\?\.status==='rejoin'&&rejoinResponse\)[\s\S]*setNotice\(\{title:'Next game advanced',message:pendingNextGameEvent\.message\}\)/);
});
