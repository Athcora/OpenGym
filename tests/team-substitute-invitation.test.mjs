import assert from 'node:assert/strict';
import fs from 'node:fs';
import test from 'node:test';

const app=fs.readFileSync(new URL('../app/WaitlistApp.tsx',import.meta.url),'utf8');

test('team-substitute invitations refresh pending request state before showing any generic event notice',()=>{
  assert.match(app,/if\(event\.event_type==='team_substitute_invite'\)\{\s*scheduleRefresh\(\);\s*return;/);
  assert.match(app,/const incoming=teamSubstituteRequests\.find\(request=>!handledTeamSubRequestIds\.current\.has\(request\.id\)[\s\S]*title:'Substitute invitation'[\s\S]*confirm:'Accept'[\s\S]*cancelLabel:'Decline'/);
});

test('accepting a team-substitute invitation confirms the team number instead of roster names',()=>{
  assert.match(app,/async function answerTeamSubstitute\(id:string,accept:boolean\)\{[\s\S]*rpc\('answer_team_substitute',\{p_request_id:id,p_accept:accept\},false\)[\s\S]*You are now a substitute for \$\{team\?\.name\?\?'your team'\}\./);
});
