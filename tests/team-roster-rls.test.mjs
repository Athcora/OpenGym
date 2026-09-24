import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import test from 'node:test';

const sql=readFileSync(new URL('../supabase/harden-team-roster-read-rls.sql',import.meta.url),'utf8');
const tables=['team_fill_ins','team_substitutes','team_substitute_requests'];

test('team roster reads remain available only within the selected facility',()=>{
  for(const table of tables){
    const policy=`${table}_read`;
    assert.match(sql,new RegExp(`drop policy if exists ${policy} on public\\.${table}`));
    assert.match(sql,new RegExp(`create policy ${policy} on public\\.${table}[\\s\\S]*?for select to authenticated[\\s\\S]*?using \\(facility_id = public\\.current_facility_id\\(\\)\\)`));
  }
});

test('the migration cannot reintroduce an unrestricted authenticated roster read',()=>{
  assert.doesNotMatch(sql,/for select to authenticated\s+using\s*\(true\)/i);
});
