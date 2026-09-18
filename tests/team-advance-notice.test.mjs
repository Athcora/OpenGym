import test from 'node:test';
import assert from 'node:assert/strict';
import {shouldShowRemoteTeamAdvanceNotice} from '../app/teamAdvanceNotice.mjs';

test('the initiating operator keeps the completion notice after a team advancement broadcast',()=>{
  assert.equal(shouldShowRemoteTeamAdvanceNotice({actorUserId:'admin',sessionUserId:'admin',isAdmin:true,isHost:false,player:null,courtNumber:1}),false);
});

test('other affected participants still receive the team-advancement notification',()=>{
  assert.equal(shouldShowRemoteTeamAdvanceNotice({actorUserId:'admin',sessionUserId:'host',isAdmin:false,isHost:true,player:null,courtNumber:1}),true);
  assert.equal(shouldShowRemoteTeamAdvanceNotice({actorUserId:'admin',sessionUserId:'player',isAdmin:false,isHost:false,player:{status:'current',court_number:1},courtNumber:1}),true);
  assert.equal(shouldShowRemoteTeamAdvanceNotice({actorUserId:'admin',sessionUserId:'unaffected',isAdmin:false,isHost:false,player:{status:'current',court_number:2},courtNumber:1}),false);
});
