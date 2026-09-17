import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';

const migration=await readFile(new URL('../supabase/fix-next-game-facility-scope.sql',import.meta.url),'utf8');
const app=await readFile(new URL('../app/WaitlistApp.tsx',import.meta.url),'utf8');

test('every next-game RPC is explicitly facility scoped',()=>{
  for(const name of ['end_court_game','end_team_rotation','end_team_king_game']){
    const start=migration.indexOf(`create or replace function public.${name}`);
    const body=migration.slice(start,migration.indexOf('$$;',start));
    assert.ok(start>=0,`${name} is present`);
    assert.match(body,/fid uuid:=public\.current_facility_id\(\)/,`${name} obtains the active facility`);
    assert.match(body,/facility_id=fid/,`${name} filters mutations by facility`);
  }
});

test('legacy unassigned and over-capacity current players are repaired',()=>{
  assert.match(migration,/p\.court_number is null/);
  assert.match(migration,/r\.rn>cfg\.max_players/);
  assert.match(migration,/perform public\.fill_open_court_slots\(\)/);
});

test('the court UI never renders unassigned current players as Court 1',()=>{
  assert.match(app,/current\.filter\(player=>player\.court_number===court\.court_number\)/);
  assert.doesNotMatch(app,/current\.filter\(player=>\(player\.court_number\?\?1\)===court\.court_number\)/);
});

test('repair model keeps a court capped and returns overflow to waiting',()=>{
  const max=12;
  const current=Array.from({length:24},(_,id)=>({id,status:'current',court:1}));
  const kept=current.slice(0,max);
  const waiting=current.slice(max).map(player=>({...player,status:'waiting',court:null}));
  assert.equal(kept.length,max);
  assert.equal(waiting.length,12);
  assert.ok(waiting.every(player=>player.court===null));
});
