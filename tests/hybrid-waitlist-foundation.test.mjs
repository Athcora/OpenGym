import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const migration=readFileSync(new URL('../supabase/migrations/20260929033127_hybrid_waitlist_foundation.sql',import.meta.url),'utf8');
const reverseSnapshotFix=readFileSync(new URL('../supabase/migrations/20260929050229_hybrid_reverse_court_snapshot_fix.sql',import.meta.url),'utf8');
const reverseOwnershipGuard=readFileSync(new URL('../supabase/migrations/20260930193702_hybrid_reverse_current_ownership_guard.sql',import.meta.url),'utf8');
const reverseTerminalPreservation=readFileSync(new URL('../supabase/migrations/20260930194641_hybrid_reverse_later_sitout_preservation.sql',import.meta.url),'utf8');

test('hybrid Waitlist is a new explicit facility mode with separate rotation configuration',()=>{
  assert.match(migration,/mode in \('regular', 'rejoin', 'teams', 'teams_rejoin', 'hybrid_waitlist'\)/);
  assert.match(migration,/hybrid_rotation_rule text not null default 'two_on_two_off'/);
  assert.match(migration,/hybrid_rotation_rule in \('two_on_two_off', 'kotc'\)/);
  assert.match(migration,/hybrid_auto_kotc_threshold_teams integer/);
  assert.match(migration,/hybrid_auto_kotc_armed boolean not null default true/);
});

test('temporary KOTC identity is isolated from permanent Rejoin group membership',()=>{
  assert.match(migration,/create table if not exists public\.hybrid_kotc_teams/);
  assert.match(migration,/create table if not exists public\.hybrid_kotc_slots/);
  assert.match(migration,/original_group_id uuid/);
  assert.match(migration,/original_unit_order integer/);
  assert.match(migration,/original_queue_position bigint/);
  assert.doesNotMatch(migration,/alter table public\.waitlist_players[\s\S]*add column[^;]*hybrid.*team_id/i);
});

test('hybrid teams are court-scoped six-slot appearances with a per-court stale boundary',()=>{
  assert.match(migration,/court_side smallint not null check \(court_side in \(1,2\)\)/);
  assert.match(migration,/appearance_game_number integer not null/);
  assert.match(migration,/consecutive_wins integer not null default 0/);
  assert.match(migration,/slot_number smallint not null check \(slot_number between 1 and 6\)/);
  assert.match(migration,/unique\(team_id,slot_number\)/);
  assert.match(migration,/create table if not exists public\.hybrid_kotc_court_state/);
  assert.match(migration,/primary key\(facility_id,court_number\)/);
});

test('hybrid state is facility-scoped, RLS-enabled, and not directly mutable by browser roles',()=>{
  for(const table of ['hybrid_kotc_teams','hybrid_kotc_slots','hybrid_kotc_substitutes','hybrid_kotc_court_state']){
    assert.match(migration,new RegExp(`alter table public\\.${table} enable row level security`));
  }
  assert.match(migration,/using\(facility_id=public\.current_facility_id\(\)\)/);
  assert.match(migration,/revoke all on public\.hybrid_kotc_teams, public\.hybrid_kotc_slots,[\s\S]*from anon, authenticated/);
});

test('the foundation rejects duplicate active slot assignments and snapshots every hybrid state family by facility',()=>{
  assert.match(migration,/function public\.assert_hybrid_kotc_slot_integrity\(\)/);
  assert.match(migration,/A player may occupy only one active Waitlist KOTC slot/);
  assert.match(migration,/join public\.hybrid_kotc_teams team[\s\S]*team\.status='current'/);
  assert.match(migration,/create trigger hybrid_kotc_slot_integrity/);
  assert.match(migration,/function public\.capture_hybrid_kotc_state\(\)/);
  for(const key of ['hybrid_kotc_teams','hybrid_kotc_slots','hybrid_kotc_substitutes','hybrid_kotc_court_state']){
    assert.match(migration,new RegExp(`'${key}'`));
  }
  assert.match(migration,/where s\.facility_id=scope\.fid/);
  assert.match(migration,/revoke all on function public\.capture_hybrid_kotc_state\(\) from public, anon, authenticated/);
});

test('admin snapshots append hybrid state and restore it in dependency order without touching other facilities',()=>{
  assert.match(migration,/function public\.capture_waitlist_state\(\)[\s\S]*\|\| public\.capture_hybrid_kotc_state\(\)/);
  assert.match(migration,/function public\.restore_hybrid_kotc_state\(p_state jsonb\)/);
  const restore=migration.slice(migration.indexOf('function public.restore_hybrid_kotc_state'));
  assert.ok(restore.indexOf('delete from public.hybrid_kotc_substitutes where facility_id=fid')<restore.indexOf('delete from public.hybrid_kotc_slots where facility_id=fid'));
  assert.ok(restore.indexOf('delete from public.hybrid_kotc_slots where facility_id=fid')<restore.indexOf('delete from public.hybrid_kotc_teams where facility_id=fid'));
  assert.ok(restore.indexOf("'hybrid_kotc_teams'")<restore.indexOf("'hybrid_kotc_slots'"));
  assert.ok(restore.indexOf("'hybrid_kotc_slots'")<restore.indexOf("'hybrid_kotc_substitutes'"));
  assert.match(migration,/revoke all on function public\.restore_hybrid_kotc_state\(jsonb\) from public, anon, authenticated/);
});

test('full admin restore preserves player groups and restores hybrid children after players',()=>{
  const restore=migration.slice(migration.lastIndexOf('function public.restore_waitlist_state'));
  assert.ok(restore.indexOf('insert into public.waitlist_players')<restore.indexOf('perform public.restore_hybrid_kotc_state(p_state)'));
  assert.match(restore,/group_id/);
  assert.match(restore,/hybrid_rotation_rule=coalesce/);
  assert.match(restore,/hybrid_auto_kotc_threshold_teams=/);
  assert.match(restore,/hybrid_auto_kotc_armed=coalesce/);
});

test('exact Reverse snapshot helper is limited to the requested court and selected facility',()=>{
  assert.match(migration,/function public\.capture_hybrid_kotc_court_state\(p_court_number integer\)/);
  const helper=migration.slice(migration.indexOf('function public.capture_hybrid_kotc_court_state'));
  assert.match(helper,/t\.facility_id=scope\.fid and t\.court_number=p_court_number/);
  assert.match(helper,/join teams t on t\.id=s\.team_id/);
  assert.match(helper,/s\.court_number=p_court_number/);
  assert.match(helper,/revoke all on function public\.capture_hybrid_kotc_court_state\(integer\) from public, anon, authenticated/);
});

test('exact Reverse compares hybrid rows semantically without erasing group/origin or streak state',()=>{
  assert.match(migration,/function public\.hybrid_court_reversal_fields\(p_kind text,p_row jsonb\)/);
  const compare=migration.slice(migration.indexOf('function public.hybrid_court_reversal_fields')).split('$$;')[0];
  assert.match(compare,/when 'hybrid_slots' then coalesce\(p_row,'\{\}'::jsonb\)-array\['created_at','updated_at'\]/);
  assert.match(compare,/when 'hybrid_teams' then coalesce\(p_row,'\{\}'::jsonb\)-array\['created_at','updated_at'\]/);
  assert.doesNotMatch(compare,/group_id|original_group_id|consecutive_wins.*-/);
  assert.match(migration,/revoke all on function public\.hybrid_court_reversal_fields\(text,jsonb\) from public, anon, authenticated/);
});

test('exact Reverse executes the hybrid merge in the legacy reversal transaction and CAS-advances version',()=>{
  assert.match(reverseTerminalPreservation,/result:=public\.reverse_past_game_legacy\(p_game_id\);[\s\S]*assert_hybrid_reverse_current_ownership[\s\S]*apply_hybrid_court_reverse\(saved\.before_state,saved\.after_state,game\.court_number\)/);
  assert.match(reverseOwnershipGuard,/create or replace function public\.reverse_past_game\(p_game_id uuid\)/);
  assert.match(migration,/update public\.hybrid_kotc_court_state set version=version\+1[\s\S]*and version=live/);
  assert.match(migration,/alter function public\.capture_court_reversal_state\(\) rename to capture_court_reversal_state_legacy/);
  assert.match(migration,/select public\.capture_court_reversal_state_legacy\(\) \|\| public\.capture_hybrid_kotc_state\(\)/);
  assert.match(migration,/revoke all on function public\.apply_hybrid_court_reverse\(jsonb,jsonb,integer\) from public, anon, authenticated/);
});

test('exact Reverse stores only the authoritative court hybrid snapshot and grants helpers only to the internal runtime role',()=>{
  assert.match(reverseSnapshotFix,/function public\.filter_hybrid_court_snapshot\(p_state jsonb,p_court integer\)/);
  assert.match(reverseSnapshotFix,/where \(value->>'court_number'\)::integer=p_court/);
  assert.match(reverseSnapshotFix,/where value->>'team_id' in \(select id from team_ids\)/);
  assert.match(reverseSnapshotFix,/before_state:=p_before \|\| public\.filter_hybrid_court_snapshot\(p_before,p_court\)/);
  assert.match(reverseSnapshotFix,/after_state:=captured_after \|\| public\.filter_hybrid_court_snapshot\(captured_after,p_court\)/);
  for(const helper of ['capture_hybrid_kotc_state\\(\\)','restore_hybrid_kotc_state\\(jsonb\\)','capture_hybrid_kotc_court_state\\(integer\\)','hybrid_court_reversal_fields\\(text,jsonb\\)','apply_hybrid_court_reverse\\(jsonb,jsonb,integer\\)']){
    assert.match(migration,new RegExp(`grant execute on function public\\.${helper} to opengym_runtime`));
  }
  assert.match(reverseSnapshotFix,/grant execute on function public\.filter_hybrid_court_snapshot\(jsonb,integer\) to opengym_runtime/);
});
