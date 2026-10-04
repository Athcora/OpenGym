import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const config = readFileSync(new URL('../supabase/migrations/20261002204038_fix-schema-lint-reverse-and-per-court-config.sql', import.meta.url), 'utf8');
const perCourt = readFileSync(new URL('../supabase/migrations/20261002032904_hybrid_per_court_configuration.sql', import.meta.url), 'utf8');
const runtime = readFileSync(new URL('./sql/hybrid-mode-transitions-runtime.sql', import.meta.url), 'utf8');

test('court-scoped format changes preserve player state and clear only retired KOTC lifecycle', () => {
  assert.match(perCourt, /create or replace function public\.clear_hybrid_kotc_court_lifecycle\(p_facility_id uuid,p_court_number integer\)/);
  assert.match(perCourt, /delete from public\.hybrid_kotc_teams where facility_id=p_facility_id and court_number=p_court_number/);
  assert.match(config, /if court\.hybrid_rotation_rule='kotc' and p_rotation_rule='two_on_two_off' then perform public\.clear_hybrid_kotc_court_lifecycle\(fid,p_court_number\); end if/);
  assert.match(config, /update public\.waitlist_courts set hybrid_rotation_rule=p_rotation_rule/);
  assert.doesNotMatch(config, /delete from public\.waitlist_players/);
});

test('manual KOTC return is court-local and requires a later below-to-above re-arm crossing', () => {
  assert.match(config, /next_armed:=p_rotation_rule='two_on_two_off' and p_threshold_teams is not null and eligible_count<p_threshold_teams\*6/);
  assert.match(config, /hybrid_rotation_rule='two_on_two_off' and hybrid_auto_kotc_threshold_teams is not null/);
  assert.match(config, /if eligible_count < court\.hybrid_auto_kotc_threshold_teams\*6 then/);
  assert.match(config, /elsif court\.hybrid_auto_kotc_armed then[\s\S]*hybrid_rotation_rule='kotc',hybrid_auto_kotc_armed=false/);
  assert.match(runtime, /above-threshold manual 2on2 immediately retriggered KOTC/);
  assert.match(runtime, /below-threshold observation did not re-arm Court 1/);
});

test('Stage 9 runtime matrix covers transition ownership, freshness, CAS, and isolation', () => {
  for (const marker of [
    'KOTC -> 2on2 did not clear retired Court 1 temporary ownership',
    'KOTC -> 2on2 rewrote permanent player semantics',
    'Court 1 transition changed Court 2',
    'new Court 1 KOTC appearance was not fresh and isolated',
    'non-admin mode transition succeeded',
    'stale pre-transition configuration succeeded',
  ]) assert.match(runtime, new RegExp(marker));
});
