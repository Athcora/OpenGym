import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';

const sql=readFileSync(new URL('../supabase/fix-geofence-return-teams.sql',import.meta.url),'utf8');

test('Teams geofence return uses the same earliest available roster slot as a normal join',()=>{
  assert.match(sql,/if config\.mode in \('teams','teams_rejoin'\) then/);
  assert.match(sql,/where t\.facility_id=fid and t\.status in \('current','waiting'\)/);
  assert.match(sql,/order by case when t\.status='current' then 0 else 1 end,[\s\S]*t\.court_number asc nulls last,t\.court_side asc nulls last/);
  assert.match(sql,/set team_id=target_team\.id,status=target_team\.status,court_number=target_team\.court_number/);
  assert.match(sql,/resolution='team_first_available'/);
  assert.match(sql,/You joined the first available team spot\./);
});

test('Geofence return cannot use a prompt, player, team, or queue position from another facility',()=>{
  assert.match(sql,/fid uuid:=public\.current_facility_id\(\)/);
  assert.match(sql,/id=p_prompt_id and user_id=auth\.uid\(\) and facility_id=fid/);
  assert.match(sql,/id=prompt\.player_id and facility_id=fid for update/);
  assert.match(sql,/from public\.waitlist_config[\s\S]*where facility_id=fid and id for update/);
  assert.match(sql,/from public\.waitlist_players where facility_id=fid and status in \('current','waiting','sitout'\)/);
});
