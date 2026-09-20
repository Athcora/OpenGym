import assert from 'node:assert/strict';
import fs from 'node:fs';
import test from 'node:test';

const app=fs.readFileSync(new URL('../app/WaitlistApp.tsx',import.meta.url),'utf8');

test('team-substitute invitations refresh pending request state before showing any generic event notice',()=>{
  assert.match(app,/if\(event\.event_type==='team_substitute_invite'\)\{\s*scheduleRefresh\(\);\s*return;/);
  assert.match(app,/const incoming=teamSubstituteRequests\.find\(request=>!handledTeamSubRequestIds\.current\.has\(request\.id\)[\s\S]*title:'Substitute invitation'[\s\S]*confirm:'Accept'[\s\S]*cancelLabel:'Decline'/);
});
