import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';

const app=readFileSync(new URL('../app/WaitlistApp.tsx',import.meta.url),'utf8');
const conversion=readFileSync(new URL('../supabase/fix-team-mode-conversion.sql',import.meta.url),'utf8');
const undo=readFileSync(new URL('../supabase/fix-operator-undo-safe-update.sql',import.meta.url),'utf8');
const substitute=readFileSync(new URL('../supabase/team-substitute-next-game.sql',import.meta.url),'utf8');
const courts=readFileSync(new URL('../supabase/fix-team-court-count.sql',import.meta.url),'utf8');

assert.match(conversion,/\(player_no-1\)%6=0/);
assert.match(conversion,/queue_position=\(\(player_no-1\)%6\)\+1/);
assert.match(conversion,/order by case when status='current' then 0 else 1 end/);
assert.match(undo,/update public\.king_teams set name='Repair '\|\|id::text where true/);
assert.match(substitute,/team_substitutes/);
assert.match(substitute,/end_team_rotation/);
assert.match(substitute,/end_team_king_game/);
assert.match(courts,/cfg\.mode in\('teams','teams_rejoin'\)/);
assert.match(courts,/update public\.king_teams set status='waiting'/);
assert.match(courts,/perform public\.king_fill_courts\(\)/);
assert.doesNotMatch(app,/â|Ã|Â|ï¿½|�/);

console.log('waitlist integrity regression checks passed');
