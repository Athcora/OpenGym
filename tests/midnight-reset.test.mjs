import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';

const sql=await readFile(new URL('../supabase/midnight-reset-all-facilities.sql',import.meta.url),'utf8');

assert.match(sql,/America\/Los_Angeles/);
assert.match(sql,/extract\(hour from local_now\) <> 0/);
assert.match(sql,/from public\.facilities f\s+where f\.active/);
assert.match(sql,/on conflict\(facility_id,id\) do nothing/);
assert.match(sql,/where facility_id=facility\.id/g);
assert.match(sql,/delete from public\.team_fill_ins/);
assert.match(sql,/delete from public\.team_substitutes/);
assert.match(sql,/delete from public\.king_teams/);
assert.match(sql,/update public\.waitlist_players[\s\S]*status='left'/);
assert.match(sql,/update public\.waitlist_config[\s\S]*game_number=1/);
assert.match(sql,/update public\.waitlist_courts[\s\S]*game_number=court_number/);
assert.match(sql,/alter function public\.run_midnight_pacific_waitlist_reset\(\) owner to postgres/);
assert.match(sql,/'\* \* \* \* \*'/);
console.log('midnight reset covers every active facility and waitlist mode');
