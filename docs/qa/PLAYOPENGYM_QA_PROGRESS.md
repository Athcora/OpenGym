# OpenGym high-risk game-state QA progress

## Run metadata

- Branch / starting HEAD: `main` / `ef829c9e305bedfba9667d1c09b11e510ef759e9`
- Phase: Run 2 concurrency hardening; standard Next Game race is live-verified, with team/reverse/facility-switch races remaining
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
- Created two disposable active fixtures: `qa-concurrency-20260917-a` and `qa-concurrency-20260917-b`. They are separate from PHR and Ocean Air.
- Browser reproduction on fixture A with two independent administrator sessions: both opened the Game 1 confirmation, then confirmed simultaneously. The queue advanced from Game 1 to Game 3. Root cause: the modal passed `advanceGame` by reference, so the second confirmation read a realtime-refreshed Game 2 rather than the Game 1 it displayed.
- Fixed the modal-time race by capturing the displayed court game in the confirmation action. Team rotation and King confirmation paths now carry their displayed game explicitly as well.
- `node --test tests/*.test.mjs` after the modal fix: 33/33 passed.
- First browser retest of that implementation still reproduced the issue (two Game 1 confirmations advanced the QA fixture to Game 3). The `ask()` helper's function-identity capture was not a reliable boundary for the rendered action.
- Replaced the helper-level special case with explicit value capture at every regular Next Game confirmation entrypoint: the player action, single-court admin/host action, and per-court action now store both the displayed court number and game number before opening the modal.
- Added a regression assertion that all of those entrypoints pass the captured values to `advanceGame`, and updated the pre-existing green-confirmation assertion for the wrapped action.
- Published the fix to the live app and GitHub in commit `bf438f90bf9bdf2df6aead2d95b1fcb65b6bf12e`.
- Live browser verification used disposable fixture `qa-concurrency-20260917-b`, never PHR or Ocean Air. Two isolated administrator sessions opened the same Game 3 confirmation and confirmed concurrently. The fixture advanced exactly once to Game 4; both sessions synchronized to Game 4, and the losing request visibly showed `This game has already changed. Refresh and try again.` A refresh also showed the persisted Game 4 state before the unauthenticated entry screen loaded.
- Live two-court verification used that same disposable fixture after enabling Court 2. Two isolated administrator sessions opened the Court 2 Game 5 confirmation and confirmed concurrently. Court 2 advanced exactly once to Game 6; the losing session showed the stale-game rejection, and Court 1 remained on Game 4. This confirms the expected-game precondition is per-court rather than incorrectly shared across courts.

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
- `node --test tests/*.test.mjs`: 33/33 passed after the explicit-value capture correction.
- `pnpm exec eslint . --ignore-pattern dist --ignore-pattern .next`: passed.
- Production SQL editor: migration completed successfully with no rows returned; subsequent function-definition audit confirmed the scoped replacement is deployed.
- Public browser: reloaded the live entry flow and checked browser warnings/errors; the page rendered normally and the captured console had no warnings or errors.
- The Windows shell does not expose `npm`; `pnpm run build` also exposes a Windows-incompatible POSIX environment assignment in `package.json` (`WRANGLER_LOG_PATH=...`). A direct Vinext invocation started its build analysis but the wrapped process returned after the first transform line without a conclusive completion code. This environmental build-wrapper issue is recorded rather than reported as a product build pass.

## NEXT SESSION — START HERE

Continue Run 2 from the next unresolved concurrency family; do not repeat either verified regular-mode stale-confirmation race. At deployed version 460 on disposable fixture `qa-concurrency-20260917-b`, the single-court Game 3 race advanced once to Game 4, and the two-court Court 2 Game 5 race advanced once to Game 6 while Court 1 stayed on Game 4; both losing requests visibly received the stale-game rejection. Next, use only a disposable QA facility to browser-test Teams rotation and King of the Court stale confirmations, then a guarded Next-vs-Reverse/facility-switch interleaving. Preserve PHR and Ocean Air. For any confirmed defect, add a behavioral regression test, deploy it, browser-test it, and update this file before stopping.
