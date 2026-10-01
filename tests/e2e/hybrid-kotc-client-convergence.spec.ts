import { execFileSync } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { test, expect, type BrowserContext, type Page } from '@playwright/test';

type LocalEnv = Record<string, string>;
type Session = { access_token: string; refresh_token: string; expires_at: number; expires_in: number; token_type: string; user: { id: string } };

function pnpm() { return process.env.OPEN_GYM_PNPM ?? 'pnpm'; }
function localEnv(): LocalEnv {
  const output = execFileSync(pnpm(), ['supabase', 'status', '-o', 'env'], { encoding: 'utf8', shell: process.platform === 'win32' });
  return Object.fromEntries(output.split(/\r?\n/).flatMap(line => {
    const match = line.match(/^([A-Z_]+)=(.*)$/);
    return match ? [[match[1], match[2].replace(/^"|"$/g, '')]] : [];
  }));
}
function psql(sql: string) {
  execFileSync('docker', ['exec', '-i', 'supabase_db_open-gym-sites', 'psql', '-v', 'ON_ERROR_STOP=1', '-U', 'postgres', '-d', 'postgres'], { input: sql, encoding: 'utf8', stdio: ['pipe', 'pipe', 'pipe'] });
}
async function signUp(env: LocalEnv, label: string): Promise<Session> {
  const response = await fetch(`${env.API_URL}/auth/v1/signup`, { method: 'POST', headers: { apikey: env.PUBLISHABLE_KEY, 'Content-Type': 'application/json' }, body: JSON.stringify({ email: `${label}.${randomUUID()}@local.test`, password: 'LocalOnly-E2E-Password-2026' }) });
  const body = await response.json() as { access_token?: string; refresh_token?: string; expires_at?: number; expires_in?: number; token_type?: string; user?: { id?: string }; msg?: string };
  if (!response.ok || !body.access_token || !body.refresh_token || !body.user?.id) throw new Error(`Local Auth signup failed: ${body.msg ?? response.status}`);
  return body as Session;
}
async function openAuthenticated(context: BrowserContext, apiUrl: string, slug: string, session: Session): Promise<Page> {
  const storageKey = `sb-${new URL(apiUrl).hostname.split('.')[0]}-auth-token`;
  // The application creates an anonymous session when no persisted Supabase
  // session exists. Install the real local Auth session before the first app
  // module can run, rather than racing that supported guest fallback.
  await context.addInitScript(({ key, value }) => localStorage.setItem(key, value), { key: storageKey, value: JSON.stringify(session) });
  const page = await context.newPage();
  const rpcResponses: string[] = [];
  page.on('response', async response => {
    if (!response.url().includes('/rest/v1/rpc/')) return;
    const name = response.url().split('/rest/v1/rpc/')[1]?.split(/[?#]/)[0] ?? 'unknown';
    if (response.ok()) { rpcResponses.push(`${name}:${response.status()}`); return; }
    rpcResponses.push(`${name}:${response.status()}:${(await response.text()).slice(0, 500)}`);
  });
  await page.goto(`/g/${slug}`);
  await expect.poll(() => page.evaluate(async ({ url, token }) => {
    const response = await fetch(`${url}/auth/v1/user`, { headers: { Authorization: `Bearer ${token}` } });
    return response.ok ? (await response.json() as { id: string }).id : null;
  }, { url: apiUrl, token: session.access_token })).toBe(session.user.id);
  await expect.poll(() => page.evaluate(() => Boolean((window as Window & { __OPEN_GYM_E2E__?: unknown }).__OPEN_GYM_E2E__))).toBe(true);
  try {
    await expect.poll(() => page.evaluate(() => (window as Window & { __OPEN_GYM_E2E__?: { hybridKOTCBoard: () => unknown } }).__OPEN_GYM_E2E__?.hybridKOTCBoard() ?? null), { timeout: 30_000 }).not.toBeNull();
  } catch (error) {
    const state = await page.evaluate(() => ({
      screen: location.pathname,
      storedSessionKeys: Object.keys(localStorage).filter(key => key.includes('auth-token')),
      visibleText: document.body.innerText.slice(0, 1_000),
    }));
    throw new Error(`Hybrid board did not hydrate. browser=${JSON.stringify(state)} rpc=${JSON.stringify(rpcResponses)}`, { cause: error });
  }
  return page;
}
async function board(page: Page) {
  return page.evaluate(() => (window as Window & { __OPEN_GYM_E2E__?: { hybridKOTCBoard: () => unknown } }).__OPEN_GYM_E2E__?.hybridKOTCBoard() ?? null);
}
async function rpc(page: Page, env: LocalEnv, session: Session, name: string, params: Record<string, unknown>) {
  return page.evaluate(async ({ apiUrl, key, token, rpcName, rpcParams }) => {
    const response = await fetch(`${apiUrl}/rest/v1/rpc/${rpcName}`, { method: 'POST', headers: { apikey: key, Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' }, body: JSON.stringify(rpcParams) });
    return { status: response.status, body: await response.text() };
  }, { apiUrl: env.API_URL, key: env.PUBLISHABLE_KEY, token: session.access_token, rpcName: name, rpcParams: params });
}

test('two independent clients converge after a guarded hybrid result and reject B stale replay', async ({ browser }) => {
  test.setTimeout(180_000);
  const env = localEnv();
  const aSession = await signUp(env, 'stage7-client-a');
  const bSession = await signUp(env, 'stage7-client-b');
  const facility = randomUUID(); const actorPlayer = randomUUID(); const opponent = randomUUID();
  const slug = `stage7-e2e-${facility.slice(0, 8)}`;
  psql(`
    insert into public.facilities(id,name,slug,code) values('${facility}','Stage 7 local E2E','${slug}','${facility.slice(0,8)}');
    insert into public.user_facility_sessions(user_id,facility_id) values('${aSession.user.id}','${facility}'),('${bSession.user.id}','${facility}');
    insert into public.facility_admin_credentials(facility_id,username,display_username,password_hash) values('${facility}','a','A',crypt('local-only-password',gen_salt('bf'))),('${facility}','b','B',crypt('local-only-password',gen_salt('bf')));
    insert into public.admin_sessions(user_id,username,facility_id) values('${aSession.user.id}','a','${facility}'),('${bSession.user.id}','b','${facility}');
    insert into public.waitlist_config(facility_id,id,game_number,max_players,mode,court_count,geofence_enabled,hybrid_rotation_rule) values('${facility}',true,1,12,'hybrid_waitlist',1,false,'kotc');
    insert into public.waitlist_courts(facility_id,court_number,game_number,team_mode) values('${facility}',1,1,'king');
    insert into public.daily_waitlist_reset_state(facility_id,id) values('${facility}',true);
    select set_config('request.jwt.claim.sub','${aSession.user.id}',false);
    insert into public.waitlist_players(id,facility_id,user_id,first_name,last_name,display_name,status,queue_position,court_number) values('${actorPlayer}','${facility}','${aSession.user.id}','Reporter','','Reporter','current',1,1),('${opponent}','${facility}',null,'Opponent','','Opponent','current',2,1);
  `);
  const a = await browser.newContext(); const b = await browser.newContext();
  try {
    const pageA = await openAuthenticated(a, env.API_URL, slug, aSession);
    const pageB = await openAuthenticated(b, env.API_URL, slug, bSession);
    // A first-use player tutorial is unrelated to the Admin bootstrap flow,
    // but it deliberately blocks the page until acknowledged. Dismiss it
    // through its real controls before testing the Admin action.
    const acknowledge = pageA.getByRole('button', { name: 'I acknowledge' });
    if (await acknowledge.isVisible().catch(() => false)) {
      await acknowledge.click();
      const skipTutorial = pageA.getByRole('button', { name: 'Skip tutorial' });
      if (await skipTutorial.isVisible().catch(() => false)) await skipTutorial.click();
    }
    await expect(pageA.getByRole('heading', { name: 'Authoritative court board' })).toBeVisible();
    await expect(pageA.getByRole('button', { name: 'Start KOTC' })).toBeVisible();
    await pageA.setViewportSize({ width: 390, height: 844 });
    await expect(pageA.getByRole('button', { name: 'Start KOTC' })).toBeVisible();
    await pageA.setViewportSize({ width: 1280, height: 844 });
    await pageA.getByRole('button', { name: 'Start KOTC' }).click();
    await expect(pageA.getByRole('button', { name: 'Start KOTC' })).toHaveCount(0);
    await expect(pageA.getByText('Side 1', { exact: true })).toBeVisible();
    await expect(pageA.getByRole('button', { name: 'Win' })).toBeVisible();
    await expect.poll(() => board(pageB)).not.toEqual(null);
    const preA = await board(pageA); const preB = await board(pageB);
    expect(preA).toEqual(preB);
    await b.setOffline(true);
    const result = await rpc(pageA, env, aSession, 'advance_hybrid_kotc_game', { p_court_number: 1, p_reported_result: 'win', p_facility_id: facility, p_expected_game_number: 1, p_expected_version: 1 });
    expect(result.status).toBe(200);
    await expect.poll(() => board(pageA)).not.toEqual(preA);
    const post = await board(pageA);
    expect(await board(pageB)).toEqual(preB);
    await b.setOffline(false); await pageB.reload();
    await expect.poll(() => board(pageB)).toEqual(post);
    await pageA.setViewportSize({ width: 390, height: 844 });
    await expect(pageA.getByRole('heading', { name: 'Authoritative court board' })).toBeVisible();
    await expect(pageA.getByText('Side 1', { exact: true })).toBeVisible();
    const stale = await rpc(pageB, env, bSession, 'advance_hybrid_kotc_game', { p_court_number: 1, p_reported_result: 'win', p_facility_id: facility, p_expected_game_number: 1, p_expected_version: 1 });
    expect(stale.status).toBeGreaterThanOrEqual(400);
    expect(await board(pageA)).toEqual(post); expect(await board(pageB)).toEqual(post);
    const audit = JSON.parse(execFileSync('docker', ['exec', 'supabase_db_open-gym-sites', 'psql', '-At', '-U', 'postgres', '-d', 'postgres', '-c', `
      select json_build_object(
        'history_rows', (select count(*) from public.past_games where facility_id='${facility}'),
        'reversal_rows', (select count(*) from public.court_game_reversals where facility_id='${facility}'),
        'orphan_reversals', (select count(*) from public.court_game_reversals r left join public.past_games g on g.id=r.game_id where r.facility_id='${facility}' and g.id is null),
        'active_player_duplicates', (select count(*) from (select s.player_id from public.hybrid_kotc_slots s join public.hybrid_kotc_teams t on t.id=s.team_id where s.facility_id='${facility}' and t.status='current' and s.player_id is not null group by s.player_id having count(*)>1) duplicate_players),
        'slot_substitute_conflicts', (select count(*) from public.hybrid_kotc_slots s join public.hybrid_kotc_substitutes sub on sub.team_id=s.team_id and sub.player_id=s.player_id join public.hybrid_kotc_teams t on t.id=s.team_id where s.facility_id='${facility}' and t.status='current'),
        'orphan_slots', (select count(*) from public.hybrid_kotc_slots s left join public.hybrid_kotc_teams t on t.id=s.team_id where s.facility_id='${facility}' and t.id is null),
        'orphan_substitutes', (select count(*) from public.hybrid_kotc_substitutes sub left join public.hybrid_kotc_teams t on t.id=sub.team_id where sub.facility_id='${facility}' and t.id is null),
        'teams_over_six_slots', (select count(*) from (select s.team_id from public.hybrid_kotc_slots s where s.facility_id='${facility}' group by s.team_id having count(*)>6) oversized_teams)
      );
    `], { encoding: 'utf8' }).trim());
    expect(audit).toEqual({ history_rows: 1, reversal_rows: 1, orphan_reversals: 0, active_player_duplicates: 0, slot_substitute_conflicts: 0, orphan_slots: 0, orphan_substitutes: 0, teams_over_six_slots: 0 });
  } finally {
    await a.close().catch(()=>{});
    await b.close().catch(()=>{});
    // Exact result history deliberately creates a reversal record, which is
    // FK-protected. Remove only this disposable fixture's dependents first.
    psql(`
      delete from public.court_game_reversals where facility_id='${facility}';
      delete from public.past_games where facility_id='${facility}';
      delete from public.facilities where id='${facility}';
    `);
  }
});
