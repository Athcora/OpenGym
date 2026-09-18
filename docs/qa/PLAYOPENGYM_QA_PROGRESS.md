# OpenGym high-risk game-state QA progress

## Run metadata

- Branch / starting HEAD: `main` / `ef829c9e305bedfba9667d1c09b11e510ef759e9`
- Phase: reversal facility-isolation repair, then isolated behavioral QA
- Scope: Next Game, Reverse Past Game, court/team/group/rejoin integrity only
- Exact current task: inspect the deployed RPC bodies and build an isolated multi-facility behavioral test plan before making changes.

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

## Files changed this run

- `docs/qa/PLAYOPENGYM_QA_SPEC.md`
- `docs/qa/PLAYOPENGYM_QA_PROGRESS.md`
- `supabase/fix-reverse-game-facility-scope.sql`
- `tests/reverse-facility-scope.test.mjs`

## Tests and browser verification

- `node --test tests/reverse-facility-scope.test.mjs`: 3/3 passed.
- `node --test tests/*.test.mjs`: 29/29 passed.
- `pnpm exec eslint . --ignore-pattern dist --ignore-pattern .next`: passed.
- Production SQL editor: migration completed successfully with no rows returned; subsequent function-definition audit confirmed the scoped replacement is deployed.
- Public browser: reloaded the live entry flow and checked browser warnings/errors; the page rendered normally and the captured console had no warnings or errors.
- The Windows shell does not expose `npm`; `pnpm run build` also exposes a Windows-incompatible POSIX environment assignment in `package.json` (`WRANGLER_LOG_PATH=...`). A direct Vinext invocation started its build analysis but the wrapped process returned after the first transform line without a conclusive completion code. This environmental build-wrapper issue is recorded rather than reported as a product build pass.

## Exact next action

Create a disposable two-facility fixture (not PHR/Ocean), test real regular/rejoin/team rotation/King Next Game and three-way Reverse sequences against the deployed RPCs, then update this log with the exact state assertions and any additional fixes.
