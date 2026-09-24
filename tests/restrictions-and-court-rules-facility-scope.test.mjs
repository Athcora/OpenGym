import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const sql=readFileSync(new URL('../supabase/fix-restrictions-and-court-rules-facility-scope.sql',import.meta.url),'utf8');

const bodyFor=name=>{
  const start=sql.indexOf(`function public.${name}`);
  assert.ok(start>=0,`${name} replacement is present`);
  return sql.slice(start,sql.indexOf('$$;',start)+3);
};

test('court-rule and restriction RPCs bind mutations to the selected facility',()=>{
  for(const name of ['set_team_court_rules','admin_restrict_player']) {
    const body=bodyFor(name);
    assert.match(body,/fid uuid:=public\.current_facility_id\(\)/,`${name} captures the selected facility`);
    assert.doesNotMatch(body,/where true/i,`${name} has no global mutation predicate`);
  }
  assert.match(bodyFor('set_team_court_rules'),/where facility_id=fid and court_number=p_court_number/);
  assert.match(bodyFor('admin_restrict_player'),/where facility_id=fid and id=p_player_id/);
  assert.match(bodyFor('admin_restrict_player'),/where facility_id=fid and id=player\.id/);
});

test('restriction validates the selected-facility player before recording undo state',()=>{
  const body=bodyFor('admin_restrict_player');
  assert.ok(body.indexOf('if player.id is null') < body.indexOf('perform public.save_admin_undo'),
    'a cross-facility id cannot create an undo snapshot');
});

test('the replacement is atomic and retains browser RPC signatures',()=>{
  assert.match(sql,/^begin;/m);
  assert.match(sql,/notify pgrst, 'reload schema';\s*commit;/);
  assert.match(sql,/set_team_court_rules\(\s*p_court_number integer,/);
  assert.match(sql,/admin_restrict_player\(p_player_id uuid,p_restricted boolean\)/);
});
