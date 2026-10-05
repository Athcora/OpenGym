import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';

const sql=readFileSync(new URL('../supabase/migrations/20260930003554_hybrid_kotc_unknown_side_result.sql',import.meta.url),'utf8');

test('Stage 5 keeps unknown-side preflight stateless and retains the known-team public path',()=>{
  assert.match(sql,/function public\.prepare_hybrid_kotc_result\(/);
  assert.match(sql,/selection_required',true/);
  const preflight=sql.slice(sql.indexOf('function public.prepare_hybrid_kotc_result'),sql.indexOf('function public.replace_hybrid_kotc_reversal_before'));
  assert.doesNotMatch(preflight,/\b(insert|update|delete)\b/i);
  assert.match(sql,/preflight:=public\.prepare_hybrid_kotc_result/);
  assert.match(sql,/return public\.end_hybrid_kotc_game\(p_court_number,p_reported_result,p_expected_version\)/);
});

test('Stage 5 confirmation locks authenticated current-court parties and preserves groups',()=>{
  const confirm=sql.slice(sql.indexOf('function public.confirm_hybrid_kotc_unknown_result'),sql.indexOf('-- Existing callers retain'));
  for(const expected of [
    /assert_expected_court_game\(p_facility_id,p_court_number,p_expected_game_number\)/,
    /pg_advisory_xact_lock/,
    /caller\.status<>'current' or caller\.court_number is distinct from p_court_number/,
    /not caller\.id=any\(selected_ids\)/,
    /Selected teammates must be unique current players on this court/,
    /Permanent groups must be selected together/,
    /not between 1 and 6/,
    /create_hybrid_kotc_identified_side/,
    /end_hybrid_kotc_game\(p_court_number,p_reported_result,p_expected_version\)/,
  ]) assert.match(confirm,expected);
  assert.match(sql,/order by u\.priority nulls last,u\.created_at,u\.unit_id,s\.queue_position nulls last/);
  assert.match(sql,/while slot_no<=6/);
});

test('Stage 5 keeps materialization private, scopes it to facility/court, and preserves exact Reverse',()=>{
  assert.match(sql,/replace_hybrid_kotc_reversal_before\(before_state,p_court_number\)/);
  assert.match(sql,/revoke all on function public\.create_hybrid_kotc_identified_side[\s\S]*from public,anon,authenticated/);
  assert.match(sql,/grant execute on function public\.create_hybrid_kotc_identified_side[\s\S]*to opengym_runtime/);
  assert.match(sql,/public\.confirm_hybrid_kotc_unknown_result\(integer,text,uuid,integer,bigint,uuid\[\]\) from public,anon/);
  assert.match(sql,/public\.confirm_hybrid_kotc_unknown_result\(integer,text,uuid,integer,bigint,uuid\[\]\) to authenticated/);
  assert.match(sql,/security definer set search_path=public/g);
});
