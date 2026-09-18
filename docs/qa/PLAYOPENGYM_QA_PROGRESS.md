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
- Confirmed and repaired a P0 Teams Mode rotation defect on the same disposable fixture. With two full active teams and no eligible waiting team, the original `end_team_rotation` path could temporarily render both active rosters empty even though the completion message said the teams would replay. The normal-mode implementation moved both teams to waiting and relied on a subsequent fill to recover them.
- Added and deployed `supabase/preserve-empty-rotation-teams.sql`. For normal Teams Mode with zero eligible waiting teams it now keeps both current teams on the current court and explicitly keeps all eligible members `current`; Teams Mode (Rejoin) retains its prior deficit/rejoin behavior.
- Added `tests/teams-empty-rotation.test.mjs`, which asserts the no-replacement preservation path and guards the separate rejoin-mode behavior.
- Live browser retest after deployment, using QA Concurrency B only: a single Court 1 advance moved Game 7 to Game 8 and retained all 12 players in Teams 1 and 2; Court 2 stayed unchanged.
- Live stale-confirmation retest after deployment: two isolated QA administrators confirmed the Court 1 Game 8 Teams Mode rotation simultaneously. The fixture advanced exactly once to Game 9; the losing session showed `This game has already changed. Refresh and try again.`; all 12 players remained in Teams 1 and 2; Court 2 remained unchanged.
- Live King of the Court stale-result verification: two isolated QA administrators chose Team 1 as winner for Court 1 Game 9 simultaneously. The fixture advanced exactly once to Game 10, Team 1's streak became 1, all 12 members remained visible, and the losing session received `This game has already changed. Refresh and try again.`
- Live Teams Mode (Rejoin) stale-result verification: two isolated QA administrators chose Team 1 as winner for Court 1 Game 10 simultaneously. The fixture advanced exactly once to Game 11; the losing session received the same stale-game rejection; precisely one rejoin workflow was produced for Team 1 (six visible 4:59 rejoin timers and six pending requests), while Team 2 remained on court.
- Resumed fixture B after the rejoin window expired and browser-verified the latest Court 1 Game 10 guarded reversal. It returned Court 1 from Game 11 to Game 10 without resurrecting Team 1's six expired players; Team 2 remained as the only active Court 1 team and Court 2 was unchanged. This is the intended timeout merge behavior, but it means the original fixture can no longer supply a valid concurrent Next-versus-Reverse race because Court 1 Next Game is disabled.
- Created a fresh disposable regular-mode fixture, `qa-interleaving-20260917`, with one full 12-player Court 1 and a dedicated QA-only administrator. It is separate from PHR and Ocean Air.
- Browser-tested the guarded Next-versus-Reverse interleaving from two independent administrator clients. First advanced Game 1 to Game 2 to produce the latest reversible Game 1. Held the Game 1 reverse confirmation in one client and the displayed Game 2 Next Game confirmation in the other, then confirmed both concurrently. The displayed client state moved once to Game 3 and Reverse was rejected with `Only the most recent game on this court can be reversed.` Both clients displayed QA1 through QA12 on Court 1 with no waiters. **This browser result is not yet authoritative proof:** while trying to query it afterward, the Supabase editor re-ran the earlier destructive seed query behind its stale warning and reset this fixture to Game 1. The current fixture database state is therefore Game 1 / 12 current / 0 past games. Re-seed in a fresh SQL-editor query, then repeat and immediately query the state from a separate read-only query tab before relying on this result.
- Restarted that verification safely: signed into the reset fixture in a fresh browser client, advanced Game 1 to Game 2, and queried it from a brand-new read-only Supabase SQL tab. Authoritative state was Game 2, 12 current, 0 waiting, and 1 past game.
- **Authoritative guarded Next-versus-Reverse interleaving passed:** two independently authenticated QA administrators held the Game 1 Reverse and displayed Game 2 Next Game confirmations open, then confirmed them concurrently. Next Game won exactly once; both browser clients synchronized to Game 3, all QA1–QA12 remained current, and Reverse was rejected with `Only the most recent game on this court can be reversed.` A fresh, read-only SQL query immediately confirmed **Game 3 / 12 current / 0 waiting / 2 past games**. This used only the disposable `qa-interleaving-20260917` fixture.
- Refresh/reconnect observation: the in-app QA browser initially showed the persisted Game 3 admin state, but its reload then discarded the anonymous Supabase browser session and returned to the facility chooser. This is a limitation of this isolated in-app-browser harness, not evidence of a product state loss; the authoritative database read remains intact. The only available automation browser is that isolated in-app profile, so a same-auth-storage facility-switch interleaving cannot be honestly run here. It remains a manual production-browser validation item.
- Run 3 inventory found a P0 gap in the immediate Teams/KOC completion-modal Reverse path: the client called the deployed legacy `reverse_king_game()` RPC, whose production definition lacked both facility and observed-game guards. Replaced it with a lookup for the displayed Court/Game Past Game record followed by `reverse_past_game_guarded`; the completion modal now captures the observed court/game. Added `supabase/retire-unguarded-team-reverse.sql`, deployed its authenticated-role revokes in production, and added a regression test. Full suite passes 36/36.
- Published the guarded client as Sites version 461 from commit `e704d481d24100689a118b7330174d469924c200` and verified that the built client bundle contains `reverse_past_game_guarded` rather than the legacy immediate-reverse call.
- Live browser continuation on disposable fixture `qa-interleaving-20260917`: after signing in afresh, a Teams Mode Court 1 advance moved Game 4 to Game 5 and retained QA1–QA12. Contrary to the intended immediate-reversal flow, no `Advancement complete` / `Reverse` modal was displayed after this normal Teams advance. This is an unresolved P0 UI-flow defect; do not claim the new immediate reverse path is browser-verified yet.
- Follow-up `a37471b` changes the completion-modal condition so an operator always retains the immediate Reverse action even if their account has a rejoin prompt. Targeted regression coverage passes 6/6 and full suite passes 37/37. It is published as Sites version 462; live browser retest remains next.
- **v462 live retest failed:** a freshly authenticated QA administrator on the disposable fixture advanced Teams Court 1 from Game 5 to Game 6. QA1–QA12 remained current, but no `Advancement complete` dialog or immediate Reverse action rendered. The source proves `operator` is `admin || host`, so the new condition should have applied. Treat this as unresolved; the next investigation must establish whether the custom-domain client is serving the v462 asset or whether the post-advance state update is clearing the notice.
- Root cause proved: `rotateTeamCourt` broadcasts `team_game_advanced`; the initiating admin's own asynchronous broadcast handler could subsequently replace `Advancement complete` with `Next game advanced`. Added `app/teamAdvanceNotice.mjs`; the handler now ignores self-originated team-advance broadcasts while preserving remote operator/affected-player notifications. `tests/team-advance-notice.test.mjs` is an executable regression test for that behavior.
- Published commit `2e6b420a13d7d6eb9fdab5d012d3d36a3cf28ca0` as Sites version 463. Targeted test passed 2/2; full suite passed 39/39; direct Vinext build completed successfully.
- Live browser verification on disposable `qa-interleaving-20260917` passed for Teams rotation: a fresh QA admin advanced Game 6 to Game 7, saw `Advancement complete` with immediate Reverse, then clicked Reverse and restored Game 6 with QA1–QA12 still intact. A stale-action check also passed: kept that Game 7 Reverse open, advanced once more from a second QA admin tab, then invoked the old Reverse; it rejected with `Only the most recent game on this court can be reversed.`

## Files changed this run

- `docs/qa/PLAYOPENGYM_QA_SPEC.md`
- `docs/qa/PLAYOPENGYM_QA_PROGRESS.md`
- `supabase/fix-reverse-game-facility-scope.sql`
- `tests/reverse-facility-scope.test.mjs`
- `supabase/guarded-game-actions.sql`
- `tests/guarded-game-actions.test.mjs`
- `app/WaitlistApp.tsx`
- `tests/court-reversal.test.mjs`
- `supabase/preserve-empty-rotation-teams.sql`
- `supabase/retire-unguarded-team-reverse.sql`
- `tests/teams-empty-rotation.test.mjs`
- `tests/guarded-game-actions.test.mjs`

## Tests and browser verification

- `node --test tests/reverse-facility-scope.test.mjs`: 3/3 passed.
- `node --test tests/teams-empty-rotation.test.mjs`: 2/2 passed.
- `node --test tests/*.test.mjs`: 35/35 passed after the Teams Mode preservation repair.
- `node --test tests/*.test.mjs`: 35/35 passed again after the authoritative guarded Next-versus-Reverse browser/database verification (no source changes were required by that verification).
- `node --test tests/*.test.mjs`: 36/36 passed after retiring the unguarded immediate Teams/KOC reverse RPC path.
- `pnpm exec eslint . --ignore-pattern dist --ignore-pattern .next`: started with no emitted diagnostics but did not return a conclusive completion status before the prior session ended; it is not a confirmed lint pass.
- Production SQL editor: migration completed successfully with no rows returned; subsequent function-definition audit confirmed the scoped replacement is deployed.
- Public browser: reloaded the live entry flow and checked browser warnings/errors; the page rendered normally and the captured console had no warnings or errors.
- The Windows shell does not expose `npm`; `pnpm run build` also exposes a Windows-incompatible POSIX environment assignment in `package.json` (`WRANGLER_LOG_PATH=...`). A direct Vinext invocation started its build analysis but the wrapped process returned after the first transform line without a conclusive completion code. This environmental build-wrapper issue is recorded rather than reported as a product build pass.

## NEXT SESSION — START HERE

Do not redo the completed guarded Next-versus-Reverse interleaving. It passed authoritatively on disposable fixture `qa-interleaving-20260917`: Game 3 / 12 current / 0 waiting / 2 past games after concurrent Next Game and stale Reverse, with no player loss. First investigate the unresolved immediate Teams/KOC reverse UI flow on that disposable fixture: a freshly deployed v461 client advanced Teams Court 1 from Game 4 to Game 5 without displaying the `Advancement complete` modal, so there was no immediate Reverse control to test. Inspect the `rejoin_prompts` return value and the `if (!prompts.some(...)) setNotice(...)` branch in `rotateTeamCourt`; reproduce with a behavioral regression test, then fix, publish, and browser-test (1) immediate reverse returns the exact observed game/lineup and (2) an older open reverse rejects after a further advance. Also inspect production function ACLs before saying the legacy RPCs are completely inaccessible: the deployed SQL has revoked `authenticated` only, and any `PUBLIC` execute grant must be explicitly accounted for. A same-auth-storage facility-switch race has **not** been browser-tested because the only available IAB profile discards the anonymous session on reload and exposes no shared-profile browser; retain it as a manual production-browser validation item. Preserve PHR and Ocean Air. After immediate reverse verification, continue Run 3’s player/host/admin action inventory. For every confirmed defect, add a behavioral regression test, deploy it, browser-test it, run `node --test tests/*.test.mjs`, and update this file before stopping.
