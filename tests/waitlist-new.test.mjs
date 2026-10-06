import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import test from 'node:test';

const app=readFileSync(new URL('../app/WaitlistApp.tsx',import.meta.url),'utf8');
const css=readFileSync(new URL('../app/admin-player.css',import.meta.url),'utf8');
const sql=readFileSync(new URL('../supabase/migrations/20261006033802_waitlist_new_mode.sql',import.meta.url),'utf8');
const fn=name=>{const start=sql.indexOf(`create or replace function public.${name}(`);assert.ok(start>=0,`missing ${name}`);return sql.slice(start,sql.indexOf('\n$$;',start));};

test('Waitlist (New) keeps the facility in Rejoin mode behind a separate flag',()=>{
  assert.match(fn('wl_is_enabled'),/c\.mode='rejoin'/);
  assert.match(fn('set_waitlist_new_mode'),/perform public\.set_open_gym_mode\('rejoin'\)/);
  assert.match(sql,/create trigger wl_clear_on_mode_change after update of mode on public\.waitlist_config/);
  assert.doesNotMatch(sql,/alter table public\.waitlist_config/);
  assert.doesNotMatch(sql,/alter table public\.waitlist_courts/);
});

test('per-court settings and the win streak live outside the tables that undo rebuilds',()=>{
  assert.match(sql,/create table if not exists public\.wl_court_settings/);
  assert.match(sql,/primary key\(facility_id,court_number,game_number\)/);
  // Substitutes must survive restore_waitlist_state(), which re-inserts players.
  const subs=sql.slice(sql.indexOf('create table if not exists public.wl_party_substitutes'),sql.indexOf('create index if not exists wl_party_substitutes_group_idx'));
  assert.doesNotMatch(subs,/references public\.waitlist_players/);
});

test('2 on 2 off switches to King of the Court at the team count and back below it; KOTC only has a games cap',()=>{
  const rules=readFileSync(new URL('../supabase/migrations/20261006050000_waitlist_new_kotc_rules.sql',import.meta.url),'utf8');
  assert.match(rules,/if s\.format='kotc' then desired:='kotc';/);
  assert.match(rules,/case when public\.wl_team_count\(p_facility_id\)>=s\.threshold_teams then 'kotc' else 'two_on_two_off' end/);
  assert.match(rules,/threshold:=case when p_format='kotc' then null else p_threshold_teams end;/);
  assert.match(rules,/delete from public\.wl_kotc_state/);
  assert.match(fn('wl_team_count'),/count\(\*\)\/6/);
  assert.match(app,/\{format==='two_on_two_off'&&<><span>until there are<\/span>/);
});

test('King of the Court results are guarded, validated and capped like Teams mode',()=>{
  const body=fn('advance_waitlist_kotc_game');
  assert.match(body,/perform public\.assert_expected_court_game\(p_facility_id,p_court_number,p_expected_game_number\)/);
  assert.match(body,/There''s no one on the waitlist yet\. Try again once more people show up\./);
  assert.match(body,/You need to select your team of 6\./);
  assert.match(body,/Parties must be selected together\./);
  assert.match(body,/winner_stays:=settings\.max_wins is null or prev_streak\+1<settings\.max_wins/);
  assert.match(body,/else staying:='\{\}'; new_streak:=0;/);
  assert.match(body,/There weren''t enough players to make a full team\. '\|\|short_by\|\|' more player'/);
  assert.match(body,/perform public\.save_admin_undo\('start next game'\)/);
  assert.match(body,/perform public\.record_court_reversal\(reversal_before,p_court_number\)/);
  // A party that does not fit is skipped and keeps its place.
  assert.match(body,/if blk\.block_size<=open_spots then/);
});

test('active party substitutes never take a spot in a game',()=>{
  assert.match(sql,/replace\(def,'p\.status=''waiting''','p\.status=''waiting''\s+and p\.id not in \(select public\.wl_active_substitute_ids\(fid\)\)'\)/);
  assert.match(fn('advance_waitlist_kotc_game'),/p\.id not in \(select public\.wl_active_substitute_ids\(fid\)\)/);
  assert.match(fn('request_waitlist_substitute'),/if party_size<>6 then raise exception/);
  assert.match(fn('request_waitlist_substitute'),/if sub_count>=6 then raise exception/);
});

test('every new browser RPC is authenticated-only',()=>{
  for(const name of ['set_waitlist_new_mode','configure_waitlist_court','advance_waitlist_court_game','advance_waitlist_kotc_game','request_waitlist_substitute','answer_waitlist_substitute','remove_waitlist_substitute']){
    assert.match(sql,new RegExp(`revoke all on function public\\.${name}\\([^)]*\\) from public,anon;`));
    assert.match(sql,new RegExp(`grant execute on function public\\.${name}\\([^)]*\\) to authenticated;`));
    assert.match(app,new RegExp(`rpc\\('${name}'`));
  }
  for(const helper of ['wl_active_substitute_ids','wl_team_count','wl_is_enabled','wl_apply_auto_format']){
    assert.match(sql,new RegExp(`revoke all on function public\\.${helper}\\([^)]*\\) from public,anon,authenticated;`));
  }
});

test('the app routes King of the Court courts through Win/Lose, team selection and Continue/Reverse',()=>{
  assert.match(app,/title:'Did you win or lose\?'[\s\S]*?showBack:true,confirm:'Win',actionTone:'success'[\s\S]*?cancelLabel:'Lose',cancelTone:'danger'/);
  assert.match(app,/title:'Select the teammates you were playing with'[\s\S]*?cancelLabel:'OK'/);
  assert.match(app,/kotc-team-toolbar"><span>\{adminGroupIds\.length\}\/6 selected<\/span><button className="group-cancel"[\s\S]*?>Cancel<\/button><button className="group-done"[\s\S]*?>Continue<\/button>/);
  assert.match(app,/message:'You need to select your team of 6\.'/);
  assert.match(app,/title:'Already recorded'/);
  assert.match(app,/There’s no one on the waitlist yet\. Try again once more people show up\./);
  assert.match(app,/if\(wlIsKotc\(court\.court_number\)\)\{startKotcNext\(court\.court_number,court\.game_number\);return;\}/);
  assert.match(app,/confirm:'Continue',actionTone:'success',action:async\(\)=>\{\},cancelLabel:'Reverse',cancelTone:'danger',cancelAction:reverseNextGame,blocking:wlEnabledRef\.current\|\|undefined/);
});

test('the court header shows the admin format controls, read-only rules for players and the win streak',()=>{
  assert.match(app,/<span>until there are<\/span>/);
  assert.match(app,/\[3,4,5,6,7\]\.map\(count=>/);
  assert.match(app,/<span>consecutive games MAX<\/span>/);
  // The streak sits above each team on the court, not in the header.
  assert.match(app,/<span key="king" className="wl-team-streak">Win Streak: \{teams\.streak\}<\/span>/);
  assert.match(app,/groupOverride=\{teamGroups\} groupLabels=\{teamLabels\}/);
  assert.match(app,/headerExtra=\{waitlistNew\?<WlCourtRule/);
});

test('substitutes appear under a full party and are hidden from the waiting list',()=>{
  assert.match(app,/\+ Substitutes<\/button>/);
  assert.match(app,/Substitutes <span>\{expanded\?'▴':'▾'\}<\/span>/);
  assert.match(app,/canInvite=\{ownParty&&subs\.length<6\}/);
  assert.match(app,/const expanded=wlExpandedSubs\.get\(groupId\)\?\?ownSub;/);
  assert.match(app,/\(p\.status==='waiting'\|\|p\.status==='sitout'\)&&!wlActiveSubIds\.has\(p\.id\)/);
});

test('known King of the Court sides report without picking teammates, and selection focuses one court',()=>{
  assert.match(app,/if\(teams\)\{const side=teams\.kings\.some\(player=>player\.id===reporter\.id\)\?teams\.kings:teams\.challengers;await submitKotcResult/);
  assert.match(app,/scrollIntoView\(\{block:'center',behavior:'smooth'\}\)/);
  assert.match(css,/\.kotc-team-selecting \.court-section:not\(\.kotc-selecting-court\)/);
});

test('selection modes act on a tap, so scrolling never selects a player',()=>{
  assert.match(app,/function listenForRowTaps\(/);
  assert.match(app,/Math\.hypot\(event\.clientX-tap\.x,event\.clientY-tap\.y\)>TAP_MOVE_TOLERANCE\|\|Math\.abs\(window\.scrollY-tap\.scrollY\)>4/);
  assert.doesNotMatch(app,/document\.addEventListener\('pointerdown',selectPlayer,true\)/);
});

test('the drop slot is measured from the rows themselves, not from the card header',()=>{
  assert.match(app,/const naturalMiddles=rows\.map/);
  assert.doesNotMatch(app,/Math\.round\(\(point\.y-contentTop\)\/rowHeight-\.5\)/);
});
