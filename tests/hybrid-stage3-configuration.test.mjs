import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';

const sql=readFileSync(new URL('../supabase/migrations/20260929201653_stage3_hybrid_configuration.sql',import.meta.url),'utf8');

test('Stage 3 uses one canonical versioned Admin configuration RPC',()=>{
  assert.match(sql,/hybrid_config_version bigint not null default 1/);
  assert.match(sql,/function public\.configure_hybrid_waitlist\([\s\S]*p_expected_config_version bigint/);
  assert.match(sql,/p_rotation_rule not in \('two_on_two_off','kotc'\)/);
  assert.match(sql,/p_threshold_teams not in \(3,4,5,6\)/);
  assert.match(sql,/p_king_max_wins not in \(2,3\)/);
  assert.match(sql,/if not public\.is_waitlist_admin\(\) then raise exception 'Admin access required\.'/);
  assert.match(sql,/assert_expected_facility\(p_facility_id\)/);
  assert.match(sql,/hybrid_config_version is distinct from p_expected_config_version/);
});

test('Stage 3 auto-switches only after a deferred eligible-population crossing',()=>{
  assert.match(sql,/status in \('current','waiting'\)/);
  assert.match(sql,/create constraint trigger waitlist_players_hybrid_auto_kotc_transition/);
  assert.match(sql,/deferrable initially deferred/);
  assert.match(sql,/eligible_count<threshold_players/);
  assert.match(sql,/set hybrid_rotation_rule='kotc',hybrid_auto_kotc_armed=false/);
  assert.match(sql,/next_armed:=p_rotation_rule='two_on_two_off'[\s\S]*eligible_count<p_threshold_teams\*6/);
});

test('manual KOTC return removes only temporary lifecycle records and cap remains in the existing result source',()=>{
  assert.match(sql,/delete from public\.hybrid_kotc_slots where facility_id=p_facility_id/);
  assert.match(sql,/delete from public\.hybrid_kotc_substitutes where facility_id=p_facility_id/);
  assert.match(sql,/delete from public\.hybrid_kotc_teams where facility_id=p_facility_id/);
  assert.match(sql,/update public\.waitlist_courts set team_max_wins=p_king_max_wins/);
  assert.doesNotMatch(sql.slice(sql.indexOf('function public.clear_hybrid_kotc_lifecycle'),sql.indexOf('function public.hybrid_eligible_player_count')),/waitlist_players/);
});

test('Stage 3 grants only the guarded public mutation to authenticated callers',()=>{
  assert.match(sql,/revoke all on function public\.configure_hybrid_waitlist\(uuid,bigint,text,integer,integer\) from public,anon/);
  assert.match(sql,/grant execute on function public\.configure_hybrid_waitlist\(uuid,bigint,text,integer,integer\) to authenticated/);
  for(const name of ['bump_hybrid_config_version','clear_hybrid_kotc_lifecycle','hybrid_eligible_player_count','evaluate_hybrid_auto_kotc_transition','schedule_hybrid_auto_kotc_transition']) {
    assert.match(sql,new RegExp(`revoke all on function public\\.${name}`));
  }
});
