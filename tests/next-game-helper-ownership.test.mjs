import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';

const source=readFileSync(new URL('../supabase/fix-next-game-repair-helper-ownership.sql',import.meta.url),'utf8');
const migration=readFileSync(new URL('../supabase/migrations/20260925010000_fix-next-game-repair-helper-ownership.sql',import.meta.url),'utf8');

for(const [label,sql] of [['source',source],['cli',migration]]){
  test(`repair helper ownership migration is atomic and keeps browser roles out (${label})`,()=>{
    assert.match(sql,/^begin;/m);
    assert.match(sql,/alter function public\.repair_facility_court_assignments\(uuid\) owner to opengym_runtime;/);
    assert.match(sql,/revoke all on function public\.repair_facility_court_assignments\(uuid\) from public, anon, authenticated;/);
    assert.doesNotMatch(sql,/grant execute on function public\.repair_facility_court_assignments\(uuid\) to authenticated/);
    assert.match(sql,/grant execute on function public\.repair_facility_court_assignments\(uuid\) to opengym_runtime;/);
    assert.match(sql,/commit;\s*$/m);
  });
}

test('source and CLI migration remain byte-identical',()=>assert.equal(source,migration));
