import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const sql=readFileSync(new URL('../supabase/fix-player-actions-facility-scope.sql',import.meta.url),'utf8');
const functions=[
  'normalize_active_waitlist','log_waitlist_operator_action','notify_waitlist_operator_player',
  'admin_add_player','admin_set_player_sitout','admin_unsit_player','admin_leave_player',
  'sit_out_one_game','sit_out_and_leave_group','remove_self_for_geofence'
];

const bodyFor=name=>{
  const start=sql.indexOf(`function public.${name}`);
  assert.ok(start>=0,`${name} replacement is present`);
  return sql.slice(start,sql.indexOf('$$;',start)+3);
};

test('walk-in, sit-out, leave, geofence, and shared helper chain capture the selected facility',()=>{
  for(const name of functions) {
    const body=bodyFor(name);
    assert.match(body,/fid uuid:=public\.current_facility_id\(\)/,`${name} captures selected facility`);
    assert.doesNotMatch(body,/where true/i,`${name} has no global mutation predicate`);
  }
});

test('all player and operator mutations are facility-bound',()=>{
  for(const fragment of [
    'where facility_id=fid and id=p_player_id',
    'where facility_id=fid and user_id=auth.uid()',
    'insert into public.waitlist_players(facility_id,user_id',
    'insert into public.waitlist_events(facility_id,actor_user_id',
    'insert into public.group_notifications(facility_id,user_id',
    'insert into public.geofence_return_prompts(facility_id,player_id,user_id',
    'where facility_id=fid and status in (\'current\',\'waiting\',\'sitout\')'
  ]) assert.ok(sql.includes(fragment),`missing ${fragment}`);
});

test('the complete migration is atomic and retains the app-facing RPC signatures',()=>{
  assert.match(sql,/^begin;/m);
  assert.match(sql,/notify pgrst, 'reload schema';\s*commit;/);
  for(const signature of [
    'admin_add_player(p_first_name text,p_last_name text default \'\')',
    'admin_set_player_sitout(p_player_id uuid,p_skip_game integer default null)',
    'admin_unsit_player(p_player_id uuid)',
    'admin_leave_player(p_player_id uuid)',
    'sit_out_one_game(p_skip_game integer default null)',
    'sit_out_and_leave_group(p_skip_game integer default null)',
    'remove_self_for_geofence()'
  ]) assert.ok(sql.includes(signature),`missing ${signature}`);
});
