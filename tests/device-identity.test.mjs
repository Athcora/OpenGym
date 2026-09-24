import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';

const app=readFileSync(new URL('../app/WaitlistApp.tsx',import.meta.url),'utf8');
const sql=readFileSync(new URL('../supabase/prevent-duplicate-device-players.sql',import.meta.url),'utf8');
const tenancy=readFileSync(new URL('../supabase/multi-facility-tenancy.sql',import.meta.url),'utf8');

test('a browser has one persisted device identity and sends it when joining',()=>{
  assert.match(app,/const DEVICE_ID_KEY='opengym-device-id'/);
  assert.match(app,/localStorage\.getItem\(DEVICE_ID_KEY\)/);
  assert.match(app,/crypto\.randomUUID\(\)/);
  assert.match(app,/localStorage\.setItem\(DEVICE_ID_KEY,value\)/);
  assert.match(app,/join_waitlist_for_device'.*p_device_id:getDeviceId\(\)/);
});

test('the duplicate-device guard is facility-scoped, serialized, and permits reattachment',()=>{
  assert.match(tenancy,/on public\.waitlist_players\(facility_id,device_id\)/);
  assert.match(tenancy,/where device_id is not null and status<>?'left'/);
  assert.match(sql,/pg_advisory_xact_lock\(hashtext\(p_device_id\)\)/g);
  assert.match(sql,/where facility_id=fid and device_id=p_device_id and status<>?'left'/g);
  assert.match(sql,/This browser is already joined as/);
  assert.match(sql,/update public\.waitlist_players set user_id=auth\.uid\(\).*where facility_id=fid and id=player\.id/);
});
