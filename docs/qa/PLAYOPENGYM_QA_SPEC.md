# OpenGym high-risk game-state QA specification

This document is the durable test contract for production game-state work. It covers only Next Game, Reverse Past Game, and the state models directly coupled to them.

## Canonical runtime functions

The current deployed definitions must be inspected from Supabase before every QA run. Source migration files are historical records; the latest facility-scoped definitions are in `supabase/fix-next-game-facility-scope.sql` for advancement and `supabase/reverse-latest-court-game.sql` plus later follow-up migrations for reversal.

## Invariants

- Every read and mutation performed by a SECURITY DEFINER gameplay RPC is constrained to the active facility.
- A `current` player has exactly one valid active court; `court_number` must never default to Court 1 when null.
- A court has no more than `waitlist_config.max_players` current players.
- Advancing one court changes only that court's membership, game number, history, and eligible queue fill.
- Queue order is deterministic; unrelated players retain relative order unless an explicit product rule changes it.
- Groups move atomically; a valid group is never partially filled into a court.
- In Teams modes, active team state agrees with every active member's status, court, and side. Fill-ins and substitutes remain internally coherent.
- Rotation and King of the Court modify only the selected court and facility.
- Reverse Past Game is a three-way merge: restore the advancement while retaining legitimate later joins, leaves, group actions, sit-outs, moves, swaps, fill-ins, and substitutes.
- A reverse can operate only on the latest reversible game of its selected court and only for an operator.

## Required scenario families

1. Regular/rejoin Next Game: 1, 2, and 3+ courts; no/few/exact/many waiting players; groups, sit-outs, rejoins, joins/leaves/moves immediately before advancement.
2. Teams rotation: replacement-team shortages, multiple courts, Teams and Teams Rejoin, fill-ins and substitutes.
3. King of the Court: each winner, streak threshold, shortage, multiple courts, Teams Rejoin, fill-ins and substitutes.
4. Reverse: the three-way merge examples in `PLAYOPENGYM_QA_PROGRESS.md`, repeated sequences, and per-court reversal in a two-facility fixture.
5. Browser verification: record state before action, perform the action, verify visible state, query authoritative state, refresh, and verify persistence. Mutation-heavy tests belong in an isolated QA facility.

## Commands

Run all of these before reporting the run clean:

```powershell
node --test tests/*.test.mjs
npm run build
npm run lint
npm test
```

Static source-contract tests are useful but are not proof of the live RPC behavior. Database and browser checks remain required.
