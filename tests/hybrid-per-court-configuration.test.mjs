import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const sql=readFileSync(new URL('../supabase/migrations/20261002032904_hybrid_per_court_configuration.sql',import.meta.url),'utf8');
const app=readFileSync(new URL('../app/WaitlistApp.tsx',import.meta.url),'utf8');
const board=readFileSync(new URL('../app/HybridWaitlistBoard.tsx',import.meta.url),'utf8');
const guards=readFileSync(new URL('../supabase/migrations/20261002193541_hybrid_kotc_target_court_guards.sql',import.meta.url),'utf8');
const confirmation=readFileSync(new URL('../supabase/migrations/20261002200617_hybrid_kotc_unknown_side_confirmation_target_court.sql',import.meta.url),'utf8');

test('Waitlist configuration is court-owned and stale guarded',()=>{
  for(const column of ['hybrid_rotation_rule','hybrid_auto_kotc_threshold_teams','hybrid_auto_kotc_armed','hybrid_config_version'])assert.match(sql,new RegExp(`add column if not exists ${column}`));
  const configure=sql.slice(sql.indexOf('function public.configure_hybrid_waitlist'),sql.indexOf('function public.read_hybrid_kotc_board'));
  assert.match(configure,/p_court_number integer/);
  assert.match(configure,/court\.hybrid_config_version is distinct from p_expected_config_version/);
  assert.match(configure,/where facility_id=fid and court_number=p_court_number/);
  assert.doesNotMatch(configure,/update public\.waitlist_courts set team_max_wins/);
});

test('facility population arms and transitions only opted-in courts',()=>{
  const transition=sql.slice(sql.indexOf('function public.evaluate_hybrid_auto_kotc_transition'),sql.indexOf('function public.configure_hybrid_waitlist'));
  assert.match(transition,/public\.hybrid_eligible_player_count\(p_facility_id\)/);
  assert.match(transition,/hybrid_rotation_rule='two_on_two_off'/);
  assert.match(transition,/court\.hybrid_auto_kotc_threshold_teams\*6/);
  assert.match(transition,/court_number=court\.court_number/);
  assert.doesNotMatch(transition,/update public\.waitlist_config\s+set hybrid_rotation_rule/);
});

test('court-targeted KOTC authorization has a server-side court predicate',()=>{
  assert.match(sql,/function public\.is_hybrid_kotc_court\(p_facility_id uuid,p_court_number integer\)/);
  const predicate=sql.slice(sql.indexOf('function public.is_hybrid_kotc_court'),sql.indexOf('-- Population is facility-wide'));
  assert.match(predicate,/court\.court_number=p_court_number/);
  assert.match(predicate,/court\.hybrid_rotation_rule='kotc'/);
  assert.match(predicate,/cfg\.mode='hybrid_waitlist'/);
});

test('final KOTC sit-out guard is selected-court scoped and keeps browser grants narrow',()=>{
  assert.match(guards,/not public\.is_hybrid_kotc_court\(fid,p_court_number\)/);
  assert.doesNotMatch(guards,/cfg\.hybrid_rotation_rule/);
  assert.match(guards,/court_number=p_court_number and version=p_expected_version/);
  assert.match(guards,/from public,anon/);
  assert.match(guards,/to authenticated/);
});

test('final KOTC Fill In validates its target court before touching an explicit slot',()=>{
  const fill=guards.slice(guards.indexOf('function public.fill_hybrid_kotc_empty_slot'));
  assert.match(fill,/not public\.is_hybrid_kotc_court\(fid,p_court_number\)/);
  assert.doesNotMatch(fill,/cfg\.hybrid_rotation_rule/);
  assert.match(fill,/team_id=team\.id and player_id is null/);
  assert.match(fill,/court_number=p_court_number and version=p_expected_version/);
});

test('final unknown-side confirmation replaces only its final global KOTC guard and fails closed',()=>{
  assert.match(confirmation,/E'cfg\\\\\.mode\\\\s\*<>\\\\s\*''hybrid_waitlist''/);
  assert.match(confirmation,/cfg\\\\\.hybrid_rotation_rule/);
  assert.match(confirmation,/not public\.is_hybrid_kotc_court\(fid,p_court_number\) or court\.court_number is null/);
  assert.match(confirmation,/position\('is_hybrid_kotc_court\(fid,p_court_number\)' in definition\)=0/);
});

test('per-court bootstrap retains a current roster without touching another court',()=>{
  const bootstrap=sql.slice(sql.indexOf('function public.bootstrap_hybrid_kotc_game'),sql.indexOf('-- KOTC results'));
  assert.match(bootstrap,/p_court_number integer/);
  assert.match(bootstrap,/status='current' and court_number=p_court_number/);
  assert.match(bootstrap,/insert into public\.hybrid_kotc_teams/);
  assert.match(bootstrap,/insert into public\.hybrid_kotc_slots/);
  assert.match(bootstrap,/while slot_one<=6 loop/);
  assert.match(bootstrap,/while slot_two<=6 loop/);
  assert.doesNotMatch(bootstrap,/where facility_id=fid and court_number<=/);
});

test('read model and client use court-specific format rather than global Waitlist format',()=>{
  assert.match(sql,/'court_number',c\.court_number,'game_number',c\.game_number,'rotation_rule',c\.hybrid_rotation_rule/);
  assert.match(board,/board\.courts\.filter\(court=>court\.rotation_rule==='kotc'\)/);
  assert.match(app,/currentConfig\?\.mode==='hybrid_waitlist'\)/);
  assert.match(app,/courts\.find\(court=>court\.court_number===courtNumber\)\?\.hybrid_rotation_rule==='kotc'/);
  assert.doesNotMatch(app,/currentConfig\?\.mode==='hybrid_waitlist'&&currentConfig\.hybrid_rotation_rule==='kotc'/);
});

test('mixed courts render KOTC only for KOTC rows and preserve the legacy court renderer for 2on2 rows',()=>{
  assert.match(app,/courts\.filter\(court=>!isHybridWaitlist\|\|court\.hybrid_rotation_rule!=='kotc'\)\.map/);
  assert.match(board,/const kotcCourts=board\.courts\.filter\(court=>court\.rotation_rule==='kotc'\)/);
  assert.match(app,/HybridCourtConfiguration court=\{\{court_number:court\.court_number/);
  assert.doesNotMatch(app,/hybrid-mode-entry/);
  assert.doesNotMatch(board,/Waitlist configuration/);
});
