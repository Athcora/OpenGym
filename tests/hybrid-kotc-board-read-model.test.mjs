import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';

const sql=readFileSync(new URL('../supabase/migrations/20260929230203_hybrid_kotc_board_read_model.sql',import.meta.url),'utf8');

test('Stage 4 board read model is authenticated, selected-facility scoped, and read-only',()=>{
  assert.match(sql,/function public\.read_hybrid_kotc_board\(\)[\s\S]*security definer set search_path=public/);
  assert.match(sql,/current_request_user_id\(\) is null/);
  assert.match(sql,/current_facility_id\(\)/);
  assert.match(sql,/revoke all on function public\.read_hybrid_kotc_board\(\) from public,anon/);
  assert.match(sql,/grant execute on function public\.read_hybrid_kotc_board\(\) to authenticated/);
  assert.doesNotMatch(sql,/\b(insert|update|delete)\b/i);
});

test('Stage 4 board contract serializes deterministic court, team, slot, and substitute state',()=>{
  for(const field of ['court_number','game_number','version','initialized_game_number','appearance_game_number','court_side','consecutive_wins','slot_number','player_id','is_substitute','substitutes']) {
    assert.match(sql,new RegExp(`'${field}'`));
  }
  assert.match(sql,/order by c\.court_number/);
  assert.match(sql,/order by t\.court_side/);
  assert.match(sql,/order by s\.slot_number/);
  assert.match(sql,/order by hs\.created_at,hs\.id/);
  assert.match(sql,/'slots',coalesce\(\(select jsonb_agg\(jsonb_build_object/);
});

test('Stage 4 keeps non-KOTC hybrid mode dormant and scopes every lifecycle relation to the selected facility',()=>{
  assert.match(sql,/cfg\.mode<>'hybrid_waitlist' or cfg\.hybrid_rotation_rule<>'kotc'/);
  for(const relation of ['hybrid_kotc_slots','hybrid_kotc_substitutes','hybrid_kotc_teams','hybrid_kotc_court_state']) {
    const index=sql.indexOf(`public.${relation}`);
    assert.notEqual(index,-1,`${relation} must be included`);
  }
  assert.match(sql,/s\.facility_id=fid and s\.team_id=t\.id/);
  assert.match(sql,/hs\.facility_id=fid and hs\.team_id=t\.id/);
  assert.match(sql,/t\.facility_id=fid and t\.court_number=c\.court_number and t\.status='current'/);
  assert.match(sql,/state\.facility_id=fid and state\.court_number=c\.court_number/);
});
