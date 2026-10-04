import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';

const sql=readFileSync(new URL('../supabase/migrations/20261001172013_hybrid_kotc_first_game_bootstrap.sql',import.meta.url),'utf8');
const app=readFileSync(new URL('../app/WaitlistApp.tsx',import.meta.url),'utf8');
const board=readFileSync(new URL('../app/HybridWaitlistBoard.tsx',import.meta.url),'utf8');

test('first-game bootstrap is an authenticated, selected-facility, Admin-only KOTC operation',()=>{
  assert.match(sql,/function public\.bootstrap_hybrid_kotc_games\(p_facility_id uuid\)/);
  assert.match(sql,/assert_expected_facility\(p_facility_id\)/);
  assert.match(sql,/if not public\.is_waitlist_admin\(\) then raise exception 'Admin access required\.'/);
  assert.match(sql,/cfg\.mode<>'hybrid_waitlist' or cfg\.hybrid_rotation_rule<>'kotc'/);
  assert.match(sql,/pg_advisory_xact_lock\(hashtextextended\(fid::text,7429401\)\)/);
  assert.match(sql,/revoke all on function public\.bootstrap_hybrid_kotc_games\(uuid\) from public,anon/);
  assert.match(sql,/grant execute on function public\.bootstrap_hybrid_kotc_games\(uuid\) to authenticated/);
});

test('bootstrap uses six slots, fresh sides, permanent-group packing, and all configured courts',()=>{
  assert.match(sql,/court_number<=cfg\.court_count order by court_number for update/);
  assert.match(sql,/court_side,appearance_game_number,status,consecutive_wins/);
  assert.match(sql,/values\(fid,court\.court_number,1,court\.game_number,'current',0\)/);
  assert.match(sql,/values\(fid,court\.court_number,2,court\.game_number,'current',0\)/);
  assert.match(sql,/while slot_one<=6 loop/);
  assert.match(sql,/while slot_two<=6 loop/);
  assert.match(sql,/coalesce\(p\.group_id,p\.id\)/);
  assert.match(sql,/perform public\.form_hybrid_kotc_side\(court\.court_number,1::smallint,court\.game_number\)/);
  assert.match(sql,/perform public\.form_hybrid_kotc_side\(court\.court_number,2::smallint,court\.game_number\)/);
});

test('the KOTC board exposes Start KOTC only for an Admin on an uninitialized KOTC court',()=>{
  assert.match(board,/const kotcCourts=board\.courts\.filter\(court=>court\.rotation_rule==='kotc'\)/);
  assert.match(board,/admin&&court\.teams\.length===0&&court\.initialized_game_number===null/);
  assert.match(board,/Start KOTC/);
  assert.match(app,/hybridRpc\('bootstrap_hybrid_kotc_game',\{p_facility_id:facility\.id,p_court_number:court\.court_number/);
  assert.match(app,/startGames=\{startHybridKOTCGames\}/);
  assert.match(app,/courts\.find\(court=>court\.court_number===courtNumber\)\?\.hybrid_rotation_rule==='kotc'/);
});
