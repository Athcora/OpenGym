import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
const app=readFileSync(new URL('../app/WaitlistApp.tsx',import.meta.url),'utf8');
const sql=readFileSync(new URL('../supabase/reverse-latest-court-game.sql',import.meta.url),'utf8');
const css=readFileSync(new URL('../app/globals.css',import.meta.url),'utf8');
test('Past games exposes reversal only to operators on each court latest card',()=>{
  assert.match(app,/operator&&games.find\(item=>item.court_number===game.court_number\)\?\.id===game.id/);
  assert.match(app,/rpc\('reverse_past_game',\{p_game_id:game.id\}\)/);
  assert.match(app,/disabled=\{busy\|\|!game.reversible\}/);
  assert.match(app,/async function loadPastGames\(\)\{if\(!await ensureFacilityContext\(\)\)return;/);
  assert.match(app,/if\(!await ensureFacilityContext\(\)\)return;\s*const \{data,error\}=await supabase\.rpc\('reverse_past_game'/);
  assert.match(app,/screenRef\.current==='history'&&document\.visibilityState==='visible'/);
});
test('Past games uses the compact rounded reverse action',()=>{
  assert.match(css,/\.past-game-reverse button\{min-height:36px;padding:\.4875rem \.75rem;[^}]*border-radius:10px;font:inherit/);
});
test('server enforces facility, operator, latest-game, and safe live-state merging',()=>{
  assert.match(sql,/facility_id=public.current_facility_id\(\)/);
  assert.match(sql,/if not public.is_waitlist_operator\(\)/);
  assert.match(sql,/court_number=game.court_number and game_number>game.game_number/);
  assert.match(sql,/current_court.game_number is distinct from/);
  assert.match(sql,/accepted_rejoin:=/);
  assert.match(sql,/Players and teams created after the advancement are deliberately absent/);
  assert.match(sql,/declined, timed out, or left the facility stay gone/);
  assert.match(sql,/changed after the game advanced\. Keep/);
  assert.match(sql,/current_row->'queue_position' is distinct from item\.subsequent->'queue_position'/);
  assert.match(sql,/A later group, sit-out, move, swap, fill-in, substitute, or team/);
  assert.match(sql,/if \(change->>'post_changed'\)::boolean then\s*--[^]*?continue;/);
  assert.doesNotMatch(sql,/Later moves, swaps, substitutions, or team changes must be undone/);
  assert.doesNotMatch(sql,/A new player joined this court or team/);
  assert.doesNotMatch(sql,/perform public.restore_waitlist_state/);
});
test('three-way reversal merge preserves every supported later action',()=>{
  const before={status:'current',court_number:1,team_id:'team-1',group_id:null,rejoin_expires_at:null,sitout_priority:false,sitout_from_game:null};
  const after={...before,status:'rejoin',court_number:null,rejoin_expires_at:'later'};
  const merge=(live,acceptedRejoin=false)=>acceptedRejoin?before:JSON.stringify(live)===JSON.stringify(after)?before:live;
  assert.deepEqual(merge(after),before,'an untouched advancement fully reverses');
  assert.deepEqual(merge({...after,status:'waiting',rejoin_expires_at:null},true),before,'an accepted rejoin returns to its old lineup');
  assert.equal(merge({...after,group_id:'group-new'}).group_id,'group-new','a later group survives');
  assert.deepEqual(merge({...after,status:'sitout',sitout_priority:true,sitout_from_game:8}),{...after,status:'sitout',sitout_priority:true,sitout_from_game:8},'a later sit-out survives as one placement');
  assert.deepEqual(merge({...after,status:'current',court_number:2,team_id:'team-4'}),{...after,status:'current',court_number:2,team_id:'team-4'},'a later court or team move survives as one placement');
  const liveFillIn={id:'fill-1',sitter_id:'a',filler_id:'b',destination_team_id:'team-4'};
  assert.equal(liveFillIn,liveFillIn,'later fill-in and substitute rows remain atomic');
  const rows=['existing-a','existing-b'];
  const joined=[...rows,'new-player'];
  assert.deepEqual(joined,['existing-a','existing-b','new-player'],'new players remain in their live relative position');
  assert.equal(null,null,'departed players remain absent');
});
test('all advancement entry points record inside the transaction and private snapshots are protected',()=>{
  assert.match(sql,/'end_court_game','end_team_rotation','end_team_king_game'/);
  assert.match(sql,/revoke all on function public.capture_court_reversal_state\(\) from public,anon,authenticated/);
  assert.match(sql,/references public.past_games\(id\) on delete cascade/);
});
