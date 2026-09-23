import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import test from 'node:test';

const tenancy=readFileSync(new URL('../supabase/multi-facility-tenancy.sql',import.meta.url),'utf8');
const migration=readFileSync(new URL('../supabase/require-facility-session.sql',import.meta.url),'utf8');

for(const [name,sql] of [['baseline tenancy',tenancy],['session-required migration',migration]]){
  test(`${name} denies queue scope until a facility is selected`,()=>{
    const body=sql.match(/create or replace function public\.current_facility_id\(\)[\s\S]*?as \$\$([\s\S]*?)\$\$;/)?.[1] ?? '';
    assert.match(body,/select facility_id[\s\S]*?from public\.user_facility_sessions[\s\S]*?where user_id=auth\.uid\(\)/);
    assert.doesNotMatch(body,/slug\s*=\s*'pacific-highlands-ranch'/i);
    assert.doesNotMatch(body,/coalesce\s*\(/i);
  });
}

test('authenticated RLS evaluation retains only the selected-facility helper grant',()=>{
  assert.match(migration,/grant execute on function public\.current_facility_id\(\) to authenticated/);
  assert.doesNotMatch(migration,/to\s+(?:public|anon)\b/i);
});
