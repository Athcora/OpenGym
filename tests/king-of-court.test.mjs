import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';

const app=readFileSync(new URL('../app/WaitlistApp.tsx',import.meta.url),'utf8');
const sql=readFileSync(new URL('../supabase/king-of-the-court.sql',import.meta.url),'utf8');
const courtRules=readFileSync(new URL('../supabase/teams-court-rules.sql',import.meta.url),'utf8');

assert.match(app,/Did your team win\?/);
assert.match(app,/Which team won(?: on Court \$\{courtNumber\})?\?/);
assert.match(app,/cancelLabel:'Cancel',cancelTone:'danger'/);
assert.match(app,/title:'Advancement complete'/);
assert.match(app,/confirm:'Reverse',actionTone:'danger'/);
assert.match(app,/cancelLabel:'Continue',cancelTone:'success'/);
assert.match(app,/Join \+/);
assert.match(app,/Team full/);
assert.match(app,/2 on, 2 off/);
assert.match(app,/KING OF THE COURT/);
assert.match(app,/Joining another team will remove you from your current team/);
assert.doesNotMatch(app,/Winners stay\. Waiting teams rotate through one shared line\./);

assert.match(sql,/create table if not exists public\.king_teams/);
assert.match(sql,/check\(court_side in\(1,2\)\)/);
assert.match(sql,/member_count>=6/);
assert.match(sql,/winner_stays:=cfg\.king_max_wins is null/);
assert.match(sql,/update public\.king_teams set status='waiting'.*where id=loser\.id/s);
assert.match(sql,/perform public\.king_fill_courts\(\)/);
assert.match(sql,/create or replace function public\.reverse_king_game/);
assert.match(sql,/where reversed_at is null and \(public\.is_waitlist_operator\(\) or actor_user_id=auth\.uid\(\)\)/);
assert.match(courtRules,/create or replace function public\.set_team_court_rules/);
assert.match(courtRules,/create or replace function public\.end_team_rotation/);
assert.match(courtRules,/create or replace function public\.end_team_king_game/);
assert.match(courtRules,/winner_stays:=court\.team_max_wins is null/);

console.log('King of the Court UI and rotation contract checks passed.');
