import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const sql=readFileSync('supabase/migrations/20260930011518_hybrid_kotc_substitute_lifecycle.sql','utf8');
const adminBoundary=readFileSync('supabase/migrations/20260930034905_hybrid_kotc_substitute_admin_boundary.sql','utf8');

assert.match(sql,/num_nonnulls\(team_id,hybrid_team_id\)=1/);
assert.match(sql,/request_hybrid_kotc_substitute/);
assert.match(sql,/answer_hybrid_kotc_substitute/);
assert.match(sql,/fill_hybrid_kotc_empty_slot/);
assert.match(sql,/swap_hybrid_kotc_slot/);
assert.match(sql,/assert_expected_court_game/);
assert.match(sql,/version=version\+1/);
assert.match(adminBoundary,/cfg\.mode<>'hybrid_waitlist' or cfg\.hybrid_rotation_rule<>'kotc'/);
assert.match(adminBoundary,/save_admin_undo\('replace Waitlist KOTC player'\)/);
assert.match(sql,/revoke all on function public\.assert_hybrid_kotc_substitute_integrity\(\) from public,anon,authenticated/);
assert.match(sql,/grant execute on function public\.request_hybrid_kotc_substitute[\s\S]* to authenticated/);
assert.match(sql,/security definer set search_path=public/g);
console.log('Stage 6 hybrid substitute lifecycle source contract passed.');
