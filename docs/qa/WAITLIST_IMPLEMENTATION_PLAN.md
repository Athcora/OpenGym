# Hybrid Waitlist implementation plan

## Status

Stage 1A, Stage 1B, and Stage 2 are complete locally as of 2026-09-29. Stage 1B added a
server-authoritative guarded KOTC result boundary, private lifecycle/packing
helpers, Win/Lose and cap semantics, saved-priority Hybrid Rejoin behavior,
substitute dissolution, exact rollback, and independent multi-court history
identity. A fresh local baseline rebuild applied every migration without manual
repair; behavioral, integrity, and grant audits passed. Tooling passed with the
direct Windows-native Vinext CLI (the pnpm/Git-Bash wrapper was non-terminating
after successful compilation). Production remains untouched.

Stage 2 completed the dormant `hybrid_waitlist` two-on-two-off path through the
existing guarded Rejoin transition. It includes migration-only runtime request
claims authorization without a managed `auth` schema dependency, facility-wide
history allocation with immutable UUID-based Reverse identity, multi-court and
same-court concurrency guards, exact Reverse isolation, Teams/Teams Rejoin
conversion with Undo/Redo, and fresh-local reproducibility. The fresh baseline
replayed all 18 local migrations; behavioral, integrity, security, Node,
TypeScript, ESLint, direct Vinext, and diff validation passed. Hybrid remains
local-only and unexposed.

Stage 0 audit completed on 2026-09-28. No application or database behavior has
been changed by this plan. The current application mode must remain untouched
until the data model and server invariants below are implemented and tested.

## Architecture audit

### Existing Rejoin foundation

- Facility state lives in `waitlist_config`, `waitlist_courts`, and
  `waitlist_players`, all facility scoped. Player-created parties are represented
  by `waitlist_players.group_id`.
- Ordinary Rejoin advancement uses the court-scoped guarded RPC path
  `advance_court_game(court, expected_facility, expected_game)`, which locks the
  selected facility session and court before calling the canonical transition.
- Rejoin prompts/timers, sit-out priority, groups, court filling, facility
  selection, and event/realtime refresh already use the Rejoin path. The new
  top-level mode must delegate to this unchanged path whenever its rotation rule
  is `two_on_two_off`.

### Existing Teams Rejoin / King facilities available for reuse

- `king_teams` supplies a mature six-position visual board, court-side/streak
  display, existing Fill In mechanics (`team_fill_ins`), substitute requests and
  memberships (`team_substitute_requests` / `team_substitutes`), rejoin timers,
  and guarded KOTC result entry (`advance_team_king_game`).
- `WaitlistApp.tsx` already renders multi-court team boards, KOTC rule controls,
  result confirmations, grouped player rows, realtime refresh, desktop drag,
  and mobile long-press drag.
- `reverse_past_game_guarded` and `capture_court_reversal_state` provide the
  exact-one-game, facility/court-scoped reversal boundary. The new result must
  be captured through that same snapshot/history mechanism before mutating.

### Non-reusable Teams-mode data model

- Teams Rejoin associates a player directly with `king_teams` using
  `waitlist_players.team_id`. Those teams are intentionally persistent
  waitlist units and are deleted/rewritten during mode changes.
- Consequently, `king_teams` cannot represent hybrid KOTC appearances: using
  it would turn a Rejoin party/single structure into a permanent six-player
  team and violate the core preservation invariant.
- Hybrid KOTC therefore needs its own temporary, court-scoped team and slot
  records. `group_id` remains the sole representation of a player-created
  waitlist party.

## Target model and invariants

1. Add top-level config mode `hybrid_waitlist` (UI label: **Waitlist**), without
   changing existing `regular`, `rejoin`, `teams`, or `teams_rejoin` meanings.
2. Add hybrid-only config fields: `hybrid_rotation_rule` (`two_on_two_off` or
   `kotc`), `hybrid_auto_kotc_threshold_teams` (3..6 or NULL for Never), and
   `hybrid_auto_kotc_armed`.
3. Add temporary `hybrid_kotc_teams` and ordered `hybrid_kotc_slots`, scoped by
   `facility_id` and `court_number`. A team starts at streak 0, has six slot
   positions, and never changes `group_id` merely by being assembled.
4. Add a per-court hybrid result/version identity. Every result RPC receives
   expected facility, court, and game; it locks them and accepts only the
   current appearance once.
5. Capture hybrid rows/slots/substitute lifecycle state in the existing
   reversal snapshot and restore them only through the existing three-way merge
   semantics. A Reverse must preserve later unrelated player changes.
6. Hybrid KOTC return is unit-based: restore original current single/group units
   in their recorded order; return non-swapped substitutes as singles directly
   behind that block. A real substitute swap retains the established group-slot
   inheritance semantics.

## Implementation checklist

### Stage 1 — schema, server invariants, and test harness

- [ ] Create the migration with `supabase migration new`; do not hand-name a
  migration. Include new config constraints/defaults, temporary team/slot
  tables, indexes, RLS, and no public execute grants.
- [ ] Extend `capture_waitlist_state`, `restore_waitlist_state`, court reversal
  capture/merge, admin undo, redo, reset, and mode switching for hybrid-only
  state. Existing mode switches must clean temporary hybrid state without
  deleting player groups or players.
- [ ] Add server-authoritative helpers for eligible population, immutable queue
  units, greedy six-slot packing, temporary team creation, dissolution, and
  configuration validation.
- [ ] Add SQL/model regression tests for isolation, party preservation, packing,
  threshold arm/disarm, streak lifecycle, and snapshot restoration before UI.

### Stage 2 — Rejoin-compatible two-on-two-off path — COMPLETE locally

- [x] Permit an admin to select `hybrid_waitlist`; initialize it with
  `two_on_two_off` and no hybrid teams.
- [x] Route advances through the existing guarded Rejoin path while that rule is
  active. Prove singles, parties, sit-out, Rejoin, multi-court, refresh, and
  facility isolation are unchanged.

### Stage 3 — configuration and threshold — COMPLETE locally

- [x] Add Admin-only rule, threshold, and KOTC win-limit controls; all viewers
  see the active rule.
- [x] Implement one-way auto activation after an eligible-population crossing;
  it must arm the next transition rather than rearrange an in-progress game.
- [x] Manual KOTC -> two-on-two-off disarms auto activation until a below-
  threshold observation followed by a new crossing. Test Never and every
  supported threshold.

### Stage 4 — KOTC formation and board read model — COMPLETE locally

- [x] Reuse the Stage 1B authoritative temporary six-slot formation and
  group-safe greedy packing; it preserves permanent `group_id`, skipped-unit
  priority, underfilled explicit slots, substitute ownership, and court/facility
  isolation.
- [x] Expose the authenticated selected-facility KOTC board read contract:
  active rule, court game/version identity, current temporary appearances,
  streaks, ordered occupied/empty slots, and existing substitutes. It remains
  dormant for `two_on_two_off` and never creates or mutates a lifecycle row.
- [x] Validate full/underfilled/empty slots, permanent groups, substitutes,
  retired/replaced appearances, two courts, unknown transitional court,
  KOTC-to-two-on-two-off cleanup, fresh replay, ACLs, and regression tooling.
- [ ] User-facing board, Fill In, substitute controls, result modal, and drag
  interactions are intentionally deferred; this completed stage is server/read
  model only and does not expose hybrid UI.

### Stage 5 — result and first-game identification — COMPLETE (local-only)

- [x] Add Win/Lose then Back-safe result flow. For an unknown converted court,
  select only players on that court; lock reporter and reporter party; select
  other parties atomically; allow an underfilled team.
- [x] Implement one atomic guarded result RPC: validate expected game/team,
  write outcome/streak, rotate/dissolve sides, create incoming sides, preserve
  return timers and Fill In state, and emit one coherent event.
- [x] Enforce 2/3 caps and No Limit; every new court appearance starts at zero.

  Local-only Stage 5 uses a stateless authenticated preflight and a separate
  guarded confirmation; Back creates no row. It passed first-game parties of
  1/2/3/4/5 and full/underfilled six-slot behavior, stale/reporter/facility
  checks, exact Reverse, known-team Win/Lose/cap regression, independent
  same/opposing-side races, fresh 21-migration replay, integrity/grants, Node
  126/126, TypeScript, lint, and direct Windows-native Vinext. No production
  migration, frontend exposure, or deployment occurred.

### Stage 6 — substitutes and lifecycle — COMPLETE (local-only)

- [x] Reuse existing invitation and swap semantics where possible while storing
  hybrid-team ownership separately from permanent Team mode.
- [x] Test intentional groups, automatic teams, filled teams, swaps into a real
  party, outgoing substitute-as-single behavior, ordering, and timer return.

  Local-only completion: invitation ownership, accepted-substitute and
  direct-slot Sit Out, guarded swaps, Fill In, stale/retired rejection,
  concurrency, successor-aware exact Reverse, Leave preservation, Admin
  Undo/Redo, dormancy, legacy regressions, and final multi-court isolation all
  passed. A fresh schema-only replay aligned eight historical ledger entries
  and applied all 28 Stage 1A–6 migrations without manual repairs. Final
  integrity/grant audits, 127/127 Node tests, TypeScript, intended-scope ESLint
  (0 errors, 33 warnings), and the direct Windows-native five-stage Vinext
  build passed. No migration was deployed and no hybrid UI was exposed.

### Stage 7 — reverse, concurrency, realtime, and multi-court — COMPLETE (local-only)

- [x] Exact KOTC snapshot/restore coverage for normal win, forced-off, empty
  slot, skipped party, Fill In, substitute, and later legitimate change merge.
- [x] Independent clients prove duplicate/stale reports reject without a second
  advance; two courts retain isolated teams, streaks, results, history, and
  reversals.
- [x] Independent authenticated browser clients converge after a hybrid result
  and reconnect through the authoritative read model.

  The local Stage 7 browser fixture uses two distinct Auth/browser contexts.
  Client B records PRE while offline; Client A performs the guarded public
  result; B remains PRE until it reloads the real application; and B then
  hydrates the authoritative POST board through `read_hybrid_kotc_board()`.
  Its retained old game/version replay rejects without a second history or
  reversal record. The fixture also verifies zero duplicate active ownership,
  slot/substitute conflicts, orphan hybrid children, and teams over six slots.
  The read-only observer exists only in development when
  `VITE_OPEN_GYM_E2E=1`; it renders no hybrid UI and has no write path.

### Stage 8 — release validation and QA cleanup

- [x] Run focused tests, full Node suite, lint, TypeScript, production build,
  rendered integrity tests, `git diff --check`, local schema-only replay, and
  grants / search-path audit.

  Local-only completion: focused grants contract 5/5 and full Node 130/130;
  TypeScript exit 0; intended 72-file ESLint scope, 0 errors/33 warnings with
  deterministic exit 0; and a normal five-stage Vinext production build, exit
  0. Rendered output contains no E2E observer or local-Supabase marker. A clean
  schema-only baseline replay aligned eight historical ledger rows and applied
  all 28 post-baseline migrations, with final integrity and ACL/search-path
  audits passing. No deployment or frontend exposure occurred.
- [x] Implement and locally release-validate the authorized deferred hybrid
  Waitlist client without crossing the deployment boundary.

  The local client adds the explicit Admin Waitlist mode entry, KOTC
  configuration controls, a court/side/six-slot authoritative board, and only
  existing guarded hybrid lifecycle actions. Two On / Two Off remains on the
  existing Rejoin presentation. Local browser convergence includes rendered
  desktop and 390px-mobile board coverage. Focused contracts passed 7/7; the
  tracked Node suite passed 134/134; TypeScript exited 0; direct ESLint covered
  70 intended files with 0 errors and 33 warnings in naturally exiting chunks;
  and a normal direct Windows-native five-stage Vinext build exited 0 with
  `VITE_OPEN_GYM_E2E` disabled. The rendered bundle contains no E2E observer,
  local Supabase URL, or fixture marker. `git diff --check` passes and
  `supabase/config.toml` has zero diff. This remains local only: no production
  deployment, migration, facility action, or public exposure.
- [x] Deploy database before frontend, publish the exact source, and inspect
  the served custom-domain bundle. The 2026-10-01 inspection found the
  `WaitlistApp-DbJk86Rs.js` asset served by `playopengym.com` byte-identical to
  the preserved release-494 artifact (SHA-256
  `379814D1C5CD728839E38FDBEAAB491AE5074E57CBFA3D291570A3073C7906A1`). It
  contains the hybrid mode/board/guarded-result integrations and no active E2E
  observer, local-Supabase target, fixture marker, or hybrid debug surface.
- [ ] Verify live PHR/Ocean Air workflows only under the user-granted QA policy.
- [ ] Exercise desktop and 390x844 mobile interactions, then query authoritative
  state and restore the documented clean facility baseline by exact IDs.

  2026-10-01 restoration checkpoint: Ocean Air's post-bootstrap Teams Rejoin
  allocation was restored only through the deployed Admin team's normal
  `save_operator_undo` + `admin_move_king_player` action sequence. Two moves
  produced U alone and G/B/Y/H/R/S together; authoritative state retains all
  seven as current on Court 1 Game 3 with unchanged mode/court/history
  semantics. The isolated browser reload dropped the transient Admin view, so
  post-reload Admin rendering and the remaining desktop/mobile/guard/convergence
  evidence are still pending. Do not alter PHR or use a direct data repair.

  Follow-up signed-in Ocean Air evidence: the restored Teams Rejoin baseline
  rendered correctly after a real reload and at 390×844 (`375px` document width,
  no off-screen controls). A controlled hybrid KOTC render showed the expected
  Version 1 sides/open slots and no Win/Lose controls for the non-participant
  Admin at both desktop and mobile. Returning app-mediated to Teams Rejoin
  restored U alone and G/B/Y/H/R/S together, all current on Court 1 Game 3;
  the final server read also restored the dormant hybrid rotation to Two On /
  Two Off. Participant-side guard, independent-client convergence, and final
  reload/reconnect proof remain pending; deletion confirmation will be needed
  before any disposable participant can be removed.

### Per-court configuration correction — PAUSED FOR PRODUCT DECISION (2026-10-01)

The user superseded the remaining Stage 8 live QA with a required architecture
correction. The current hybrid configuration is facility-scoped in
`waitlist_config`; its rule, automatic-threshold state, version, and cap gate
every court, and the bootstrap RPC intentionally initializes all courts.
Consequently, simply moving or duplicating selectors would falsely imply
independent court control. The correction must move court-affecting state and
guards into a court-owned model, retain one facility mode selector under
Managing, remove the standalone global configuration card, and render only
each court's own configuration/board.

Before implementation, the product owner must resolve Auto KOTC: the present
threshold uses facility-wide eligible population, but independent court rules
need a defined court-local population or an explicit facility-wide targeting
policy. The implementation must not retain the old global switch implicitly.

## Primary implementation risks

- The live mode-switch and reversal helpers are broad state snapshots. Hybrid
  rows must be included in snapshots and excluded only when the selected
  facility/mode warrants it; an unscoped delete would risk cross-facility data.
- The current client and existing `king_teams` UI assume a persistent
  `player.team_id`. The hybrid adapter must be explicit so KOTC membership never
  overwrites a player-created group.
- The existing test suite is mostly source-contract coverage; live database and
  browser verification remain mandatory after each stateful stage.
- The current durable QA checkpoint records an unrelated pending Run 5 matrix.
  Hybrid work must not claim that work complete or erase its fixtures/notes.

## Stage 1A reversal mapping (2026-09-28)

- `capture_waitlist_state()` is the facility-wide admin Undo/Redo serializer. It
  currently includes players (and therefore `group_id`, queue/court/status and
  Rejoin fields), config, courts, permanent Teams-mode teams, and past games.
  Its restore is a full facility restore and must gain hybrid rows in FK-safe
  order: temporary teams, slots, substitutes, court state; it must clear those
  rows only for the selected facility.
- `capture_court_reversal_state()` is the pre/post snapshot persisted in
  `court_game_reversals`. `reverse_past_game()` does not wholesale restore: it
  compares pre/post/current rows, skips rows legitimately changed after the
  game, and re-normalizes only touched queue rows. Hybrid exact reversal must
  use this same pre/post/current merge architecture.
- Existing direct merge families are `teams`, `players`, `fill_ins`, and
  `substitutes`. Hybrid needs equivalent families for team lifecycle/appearance,
  slots, substitutes, and court versions, plus a court-only filter so reversing
  Court 1 cannot rewrite Court 2. Config is a reversal precondition rather than
  an unconditional replacement.

## First unfinished action

Start Stage 1 by auditing the current deployed schema/function versions and
creating a migration skeleton plus executable server/model tests. Do not expose
the mode in the UI or modify facility state until the schema invariants and
snapshot contract are in place.

## Stage 8 local release evidence (2026-10-04)

- Mixed-court local browser convergence passed: Court 1 KOTC and Court 2 Two On / Two Off remained isolated; the sole facility selector included Waitlist.
- Node: 167/167; TypeScript and intended ESLint: pass; schema/grants/search-path gates: pass.
- Production Vinext build: 5/5 stages, exit 0; artifact scan: pass. No deployment occurred.
- Browser UI proof: desktop mixed-court, 390px mixed-court, and single-court layouts passed. The one Managing selector exposed Waitlist (`hybrid_waitlist`); court-specific configuration stayed under its court, with KOTC on Court 1 and Two On / Two Off on Court 2.
