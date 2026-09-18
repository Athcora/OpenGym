# OpenGym high-risk game-state QA progress

## Run metadata

- Branch / starting HEAD: `main` / `ef829c9e305bedfba9667d1c09b11e510ef759e9`
- Phase: Run 2 concurrency hardening; live multi-client tests remain
- Scope: Next Game, Reverse Past Game, court/team/group/rejoin integrity, concurrency and facility context
- Exact current task: deploy and browser-verify expected-facility/game guards, then exercise them from isolated clients.

## Completed

- Created durable QA specification and progress memory.
- Confirmed the full test command is `node --test tests/*.test.mjs`; `npm test` is only a build plus rendered HTML test.
- Identified current source candidates for advancement: `supabase/fix-next-game-facility-scope.sql` and historical predecessor migrations.
- Prior production repair verified PHR Court 1 at 12 current players and 13 waiting players; the live advancement functions were verified to contain a facility context variable.
- Audited the deployed `reverse_past_game(uuid)` body statement by statement. It was a confirmed facility-isolation defect: the SECURITY DEFINER function selected and mutated configuration, courts, history, snapshots, and queue ranks without a facility predicate.
- Deployed `supabase/fix-reverse-game-facility-scope.sql` to production. The replacement scopes every snapshot, lookup, merge, delete, update, queue normalization, and reversal-history mutation to `current_facility_id()`.
- Live SQL verification confirms `reverse_past_game(uuid)` and `record_court_reversal(jsonb,integer)` now use the facility context and no longer contain the prior unscoped config/court locking patterns. Snapshot capture scopes through the active-facility CTE.

## Remaining scenario families

- Audit live definitions of `end_court_game`, team rotation, King of the Court, reverse, queue filling, repair, and reversal snapshot helpers statement by statement.
- Establish an isolated facility fixture and test regular/rejoin Next Game, rotation, King, and reverse three-way-merge sequences against real RPCs.
- Browser-test important workflows, including refresh persistence and console/network errors.
- Add behavioral regression coverage for every confirmed defect.
- Run complete test/build/lint/test commands; publish and push any fixes.

## Known findings / risks

- Historical SQL files are not canonical runtime evidence.
- Many tests are source-contract assertions or simplified models and cannot replace live RPC testing.
- Legacy reversal records created before this migration may contain globally captured snapshots. The new reversal function filters every snapshot item by the active facility before merging, so those records cannot introduce another facility's row.
- Confirmed Run-2 defect: `user_facility_sessions` is shared across a user's browser tabs. Existing client `ensureFacilityContext()` calls could race with another tab's `select_facility()`, and global advisory locks serialized requests but did not make a repeated Next Game request idempotent.

## Run 2 concurrency work completed

- Added `supabase/guarded-game-actions.sql` and deployed it to production.
- New public guarded RPCs require the client-visible facility UUID and current court game number for all Next Game paths. They lock the shared facility-session row, verify the expected facility, lock the intended court, and reject a stale game before invoking the canonical state transition.
- Reversal now has an expected-facility guarded entrypoint for the same multi-tab protection.
- The direct, unguarded Next/Reverse RPC grants were revoked from `authenticated`; the guarded entrypoints are the only browser-callable variants.
- Updated all standard, team rotation, King, and Past Game UI call paths to use these guarded RPCs.
- Added `tests/guarded-game-actions.test.mjs`; full static regression suite currently passes 32/32.

## Files changed this run

- `docs/qa/PLAYOPENGYM_QA_SPEC.md`
- `docs/qa/PLAYOPENGYM_QA_PROGRESS.md`
- `supabase/fix-reverse-game-facility-scope.sql`
- `tests/reverse-facility-scope.test.mjs`
- `supabase/guarded-game-actions.sql`
- `tests/guarded-game-actions.test.mjs`
- `app/WaitlistApp.tsx`
- `tests/court-reversal.test.mjs`

## Tests and browser verification

- `node --test tests/reverse-facility-scope.test.mjs`: 3/3 passed.
- `node --test tests/*.test.mjs`: 29/29 passed.
- `pnpm exec eslint . --ignore-pattern dist --ignore-pattern .next`: passed.
- Production SQL editor: migration completed successfully with no rows returned; subsequent function-definition audit confirmed the scoped replacement is deployed.
- Public browser: reloaded the live entry flow and checked browser warnings/errors; the page rendered normally and the captured console had no warnings or errors.
- The Windows shell does not expose `npm`; `pnpm run build` also exposes a Windows-incompatible POSIX environment assignment in `package.json` (`WRANGLER_LOG_PATH=...`). A direct Vinext invocation started its build analysis but the wrapped process returned after the first transform line without a conclusive completion code. This environmental build-wrapper issue is recorded rather than reported as a product build pass.

## Exact next action

Publish the guarded browser client, then create a disposable active two-facility fixture (not PHR/Ocean) and run simultaneous/double-submit Next and Reverse tests with state assertions. Test multi-tab facility switching explicitly before proceeding to roster-mutation races.
