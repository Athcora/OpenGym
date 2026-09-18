import assert from 'node:assert/strict';
import fs from 'node:fs';
import test from 'node:test';

const app=fs.readFileSync(new URL('../app/WaitlistApp.tsx',import.meta.url),'utf8');
const css=fs.readFileSync(new URL('../app/admin-player.css',import.meta.url),'utf8');
const sql=fs.readFileSync(new URL('../supabase/operator-accept-all-offline-rejoins.sql',import.meta.url),'utf8');

test('operators can confirm one facility-scoped bulk rejoin action',()=>{
  assert.match(app,/className="accept-all-rejoins next"/);
  assert.match(app,/Accept all rejoin requests\?','This will accept all rejoin requests\. Do you want to continue\?','Continue',acceptAllOfflineRejoins,'success','danger'/);
  assert.match(sql,/fid uuid:=public\.current_facility_id\(\)/);
  assert.match(sql,/where facility_id=fid and user_id is null and status='rejoin'/);
  assert.match(sql,/if not public\.is_waitlist_operator\(\)/);
  assert.match(css,/\.accept-all-rejoins[\s\S]*width: 100%/);
});

test('the standard player Next game confirmation uses the green success action',()=>{
  assert.match(app,/ask\('Start the next game\?',`This will notify all players that \$\{me\.display_name\} advanced the queue\. This cannot be quietly undone\.`,`?'Next game'|,'Next game'/);
  assert.match(app,/\(\)=>advanceGame\(courtNumber,gameNumber\),'success'/);
});
