import assert from 'node:assert/strict';
import fs from 'node:fs';
import test from 'node:test';

const app=fs.readFileSync(new URL('../app/WaitlistApp.tsx',import.meta.url),'utf8');
const sql=fs.readFileSync(new URL('../supabase/facility-host-appointment-rules.sql',import.meta.url),'utf8');

test('host permission controls are rendered in standard and teams modes',()=>{
  assert.match(app,/!isTeamsMode\(config\.mode\).*permissions=\{setPermissionPlayer\}/s);
  assert.match(app,/isTeamsMode\(config\.mode\).*permissions=\{setPermissionPlayer\}/s);
  assert.match(app,/admin\|\|\(operator&&!own&&!player\.is_host&&Boolean\(player\.user_id\)\)/);
  assert.match(app,/host&&item\.user_id!==me\?\.user_id&&!item\.is_host&&Boolean\(item\.user_id\)/);
  assert.match(app,/className="admin-player-actions" onPointerDown=\{event=>event\.stopPropagation\(\)\}/);
});

test('host cap is facility scoped and does not restrict admins',()=>{
  assert.match(sql,/fid uuid:=public\.current_facility_id\(\)/);
  assert.match(sql,/if p_is_host and not caller_is_admin then/);
  assert.match(sql,/where facility_id=fid and is_host/);
  assert.match(sql,/if host_count>=2 then raise exception 'A session can have no more than two hosts\.'/);
  assert.match(sql,/if not caller_is_admin and not p_is_host then/);
});
