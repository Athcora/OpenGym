# OpenGym code audit — 2026-09-30

Scope: the full `opengym-main` repository as of commit `14a1476` (branch `claude/opengym-main-audit-l75k26`).
Method: complete read of `app/WaitlistApp.tsx` and all other `app/`, `worker/`, `public/` files; read of all `supabase/*.sql` and `supabase/migrations/*.sql`; `tsc --noEmit`; `eslint`; `node --test` on the suite; targeted reproduction scripts for suspected logic bugs. No application code was changed.

Baseline: TypeScript is clean. ESLint reports 11 errors / 35 warnings, all in `WaitlistApp.tsx` (matches the baseline recorded in `docs/qa`). The 47 unit-test files pass (119 tests), but only `rendered-html.test.mjs` runs from `npm test`.

Severity key: **Critical** = data loss, cross-tenant access, or auth bypass. **High** = user-facing breakage in a common path. **Medium** = incorrect behaviour in an edge case or a maintainability trap likely to cause a bug. **Low** = hygiene.

---

## 1. Frontend — `app/WaitlistApp.tsx`

### F1. HIGH — Tapping outside the "Next game started" dialog reverses the game
`WaitlistApp.tsx:451` (rejoin mode, the player who pressed Next Game) shows a notice whose *cancel* slot is wired to `reverseNextGame` (`cancelLabel:'Reverse', cancelAction:reverseNextGame`) and is not `blocking`. `Modal` (`WaitlistApp.tsx:1606`) treats a backdrop `mousedown` as a dismiss whenever the notice is neither `blocking` nor has `onClose`, and `dismiss()` runs `cancelAction`. So a player who taps anywhere outside the card to close the popup silently reverses the game they just advanced, for everyone. The same pattern (cancelAction doing real work on a non-blocking notice) exists in `showLocationPermissionNotice` (`cancelAction` navigates to welcome).
**Fix:** treat backdrop dismissal as `close()` only, never `cancelAction`; or mark every notice whose cancel button performs an action as `blocking:true`.

### F2. HIGH — Name filter blocks many real names (client and server)
`isInappropriateName` (`WaitlistApp.tsx:97`) does substring matching on the space-stripped name plus a one-edit fuzzy match. Reproduced with a script: **Mitch**, **Ben Dickson**, **Emily Dickinson**, **Ken Fukuda**, **Nazir Ahmed**, **Kikelomo**, **Sam Spicer**, **Pat Fagan**, **Nadia Draper**, **Niger Diallo**, **Hitch**, **Titch**, **Nigar Hasan** and **Al Fukui** are all rejected with "This name is not allowed". The server-side `is_inappropriate_player_name` (`supabase/rename-player-validation.sql:2`) has the same `like '%token%'` substring rule (minus the fuzzy match), so it cannot be fixed on the client alone.
**Fix:** match blocked terms only as whole tokens (after leet-normalisation), keep substring matching only for the handful of terms that are never part of a legitimate name, and drop the one-edit fuzzy rule for 5-letter terms (that is what blocks Mitch/Hitch/Titch/Ditch).

### F3. HIGH — A blocking request dialog can be overwritten and is then lost
Group requests, swap requests and team-substitute invitations are surfaced once: the effect at `WaitlistApp.tsx:990` adds the id to `handledGroupRequestIds` **before** calling `setNotice`. Any later `setNotice` (a "Waitlist update" from the `waitlist_events` feed, a host notice, a geofence prompt) replaces the modal, and because the id is already marked handled it never re-appears. The player cannot answer until they reload. Same for `handledSwapRequestIds` and `handledTeamSubRequestIds`.
**Fix:** keep a small notice queue (blocking notices are never replaced, non-blocking ones wait), or re-derive the pending-request dialog from `groupRequests` state on every render instead of a fire-once effect.

### F4. MEDIUM — Concurrent `refresh()` calls can write stale state
`refresh()` (`WaitlistApp.tsx:552`) is invoked from the 1-second poller, `scheduleRefresh`, visibility/focus/online handlers, and after every RPC, with no in-flight guard or sequence number. Two overlapping calls resolve in arbitrary order; the older response can overwrite newer `players`/`kingTeams`/`courts` state, producing the "queue jumps back" flicker operators have reported during drags. `adminMoveInProgress` suppresses realtime-triggered refreshes but not the poller.
**Fix:** a monotonically increasing request id; ignore results from any call that is not the latest.

### F5. MEDIUM — Polling load: every visible client hits the database once per second
`WaitlistApp.tsx:271-289` runs `sync()` every 1000 ms; each cycle is at least one `waitlist_events` query, and any change triggers `refresh()` which issues a `select_facility` RPC plus ~13 table reads (two `Promise.all` batches). With 30 phones open this is 30+ requests/s idle and hundreds per second while a game is being advanced. The `waitlist_events` revision query has no facility filter; the revision string only *prefixes* `facility.id`, so an event in any facility the RLS lets the user see triggers a full reload.
**Fix:** poll at 5–10 s only when `realtimeConnected` is false, filter by `facility_id`, and let realtime carry the normal path. Consider a single `get_queue_snapshot` RPC returning everything `refresh` needs in one round-trip.

### F6. MEDIUM — Teams-mode join can silently skip team placement
`finishJoin` (`WaitlistApp.tsx:625`) looks up the new player via `players.find` on the **stale** closure (the state captured before the RPC), then falls back to `from('waitlist_players').select('id').eq('user_id', …).single()` with no `facility_id` or status filter. A user who has a `left` row in another facility gets a `.single()` multiple-rows error; `fresh` is `undefined`, and `king_prepare_player` is skipped without any message. The player is in the waitlist but on no team, which also makes them `rejoinOnly` and starts the 10-minute auto-removal timer (F7).
**Fix:** have `join_waitlist_for_device` return the player id (or perform team placement server-side in teams mode), and filter the fallback query by facility and active status.

### F7. MEDIUM — 10-minute auto-logout fires on players who are still waiting
`rejoinOnly` (`WaitlistApp.tsx:193`) is true whenever `meIsVisibleInQueue` is false. In teams mode that includes any active player who is not currently rendered inside a `kingTeams` member list (team not yet assigned, team row temporarily missing after a mode switch, or realtime delivered the player row before the team row). The effect at `WaitlistApp.tsx:243` then persists a start time in `localStorage` and after 10 minutes calls `leave_waitlist_for_facility` and signs the user out.
**Fix:** base the timer strictly on `me.status === 'rejoin' | 'left'` from the server, not on render visibility.

### F8. MEDIUM — Push notifications are sent from the browser of whoever pressed Next Game
`advanceGame`, `rotateTeamCourt`, `recordKingWinner` (`WaitlistApp.tsx:1086-1152`) invoke the `send-push` edge function once per recipient, sequentially, after the RPC. If that phone loses connectivity or the tab is backgrounded mid-loop, the remaining players never receive their "Rejoin within five minutes" push, yet the server-side timer is already running. The edge function's source is not in the repository, so it could not be verified that it checks the caller is allowed to notify those `userIds` with arbitrary title/body.
**Fix:** move sending into the database (trigger → `pg_net`/webhook → edge function) or have the RPC enqueue rows the function drains; at minimum make the function derive recipients server-side from the game/prompt id instead of trusting `userIds` and text from the client.

### F9. MEDIUM — Undo snapshot is taken even when the following move fails
`moveKingPlayer` and `setTeamCourtRules` (`WaitlistApp.tsx:1043,1113`) call `save_operator_undo` and then the mutating RPC in two separate requests. If the second fails, a no-op snapshot stays on the undo stack, so the operator's next "Undo" appears to do nothing (it restores the current state) and the real previous action needs two undos.
**Fix:** take the snapshot inside the mutating RPC (one transaction), as `advance_*` already appear to do.

### F10. MEDIUM — Two global `MutationObserver`s rewrite the DOM under React
The translation layer (`WaitlistApp.tsx:302-320`) and `Shell`'s icon cleaner (`WaitlistApp.tsx:1316`) both observe `document.body` with `subtree:true` and mutate text nodes/attributes. This translates **player names** and any dynamic text that happens to equal a dictionary key (a player named "Live", "You", "Reverse"), re-runs on every render, and makes the `translateUiText` cost proportional to the whole DOM. It also means English-string regexes elsewhere (`/Court (\d+)/` at line 436, `/(Go back|Back to .*)$/`, `/ wants to group with you/`) break as soon as the text they parse has been translated.
**Fix:** move to a `t()` function at the call sites (the dictionary already exists), mark user-generated text with `translate="no"`, and pass structured data (court number, event kind) in `waitlist_events` instead of parsing English messages.

### F11. LOW — Realtime channel cleanup leak on facility change / logout
`boot()` returns a cleanup that only the mount effect keeps. `chooseActiveFacility`, `logout` and `startGuestFlow` call `boot()` again and discard the new cleanup; on unmount only the first channel is removed. Harmless in a single-page session, wrong if the component is ever remounted.

### F12. LOW — Dead code and stale ESLint errors
`openEmailAuth` is never called, so the `screen==='email'` OTP sign-in flow (`WaitlistApp.tsx:1204`) and the Members list it feeds are unreachable. `MOBILE_SCROLL_CANCEL_DISTANCE`, `forceRejoin`, `projectQueueGames`, `teamLabel`, `cancelSubInvite` prop and several `_x/_y` params are unused. The 7 `react-hooks/set-state-in-effect` errors (lines 299, 301, 366, 1022, 1315, 1379, 1380) and the `Date.now()`-in-render purity error at 1598 will become real bugs if the React Compiler is enabled.

### F13. LOW — Small correctness nits
- `useEffect` at line 175 depends on `notice?.title` but reads `notice?.confirm`: two consecutive notices with the same title but different buttons keep a stale body class.
- `saveName` runs on both Enter and blur; a fast Enter-then-tap sends `rename_waitlist_player` twice.
- `createFacility` succeeds then `setScreen('queue')` while `facility` state still points at the *old* facility.
- `FACILITY_COORDINATE_FALLBACKS` hardcodes one production facility's coordinates into the bundle.
- `getDeviceId` uses `localStorage`/`crypto.randomUUID` without try/catch; storage-blocked browsers throw inside `join`.
- Every "Continue as guest" and every logout creates a brand-new anonymous auth user; nothing prunes them.

---

## 2. Service worker, push, PWA shell

### P1. HIGH — Deep-link entry never registers the service worker; "Enable alerts" then freezes the UI
Only `app/page.tsx` registers `/sw.js`. The QR-code path and every reload land on `/g/<slug>` (`app/g/[slug]/page.tsx`), which does not. On a browser that has never loaded `/`, `enablePush()` awaits `navigator.serviceWorker.ready` (`app/push.ts:25`), which by spec never resolves without a registration. `turnOnNotifications` (`WaitlistApp.tsx:752`) sets `busy=true` before the await and only clears it afterwards, so every `disabled={busy}` control on the page stays disabled until reload.
**Fix:** register the SW inside `WaitlistApp` (or a shared client component), and in `push.ts` register before awaiting `ready` or race it with a timeout.

### P2. HIGH — Notification "Stay"/"Leave" buttons do nothing
`public/sw.js` adds those actions and opens `/?response=<id>&choice=stay|leave`, but nothing in `app/` reads `response` or `choice`. A player tapping "Leave" from the lock screen just opens the app; the rejoin timer keeps running and they are auto-removed.
**Fix:** consume the params in `boot()` (call `answer_rejoin_prompt`, then `history.replaceState`), or remove the actions.

### P3. MEDIUM — `notificationclick` can fail silently
`sw.js:35` awaits `existing.navigate()` on a client found with `includeUncontrolled:true`; `WindowClient.navigate()` rejects for uncontrolled clients (exactly the P1 case) and the rejection aborts the handler before `focus()`/`openWindow()`. Wrap in try/catch and fall back.

### P4. MEDIUM — Service worker lifecycle gaps
No `install`/`activate` with `skipWaiting`/`clients.claim` (first install never controls the open page), no `pushsubscriptionchange` handler (browser-rotated subscriptions go stale silently), `event.data?.json()` unguarded (a non-JSON payload throws and Chrome shows a generic "updated in background" toast). No `fetch` handler, so the app is not offline-capable despite the manifest.

### P5. MEDIUM — Subscription lifecycle in `app/push.ts`
Reuses an existing subscription without checking its `applicationServerKey` matches the current VAPID key (breaks after key rotation); the `push_subscriptions` table DDL/RLS is not in the repo so the `onConflict:'endpoint'` upsert cannot be verified; the "Enable alerts" button is hidden on `Notification.permission==='granted'` rather than on "row exists for this user", so a second account on the same device can never subscribe; rows are never removed on logout, so the device keeps receiving the previous user's pushes.

### P6. MEDIUM — Recovery scripts can loop and are not storage-safe
`app/layout.tsx:19` and `app/AppErrorBoundary.tsx:14` both use `sessionStorage` without try/catch (a `SecurityError` inside an error handler kills recovery) and both *throttle* (10 s / 15 s) rather than *cap* reloads, so a persistently missing asset or a deterministic mount crash reloads the page forever. The error boundary also reloads on the very first crash before ever showing its fallback.

### P7. LOW — Manifest and icons
`sizes:"any"` is only valid for SVG; PNG needs explicit 192/512 entries. `purpose:"any maskable"` on one bitmap means one of the two renderings is wrong. The 1254×1254, 1.17 MB PNG is also the favicon and apple-touch-icon; `public/favicon.svg` exists and is unused.

---

## 3. Configuration, build, repo hygiene

### C1. MEDIUM — Production credentials as fallbacks
`app/supabase.ts:6-7` and `app/push.ts:19` fall back to the production Supabase URL, publishable key and VAPID key when env vars are missing. These are public keys, not secrets, but every dev/preview/test build without a `.env` silently talks to **production**, and the `if(!url||!key) throw` is dead code. `environment.d.ts` still declares an unused `VITE_SUPABASE_ANON_KEY`.

### C2. MEDIUM — `npm test` runs one test file
`package.json` `test` builds and runs only `tests/rendered-html.test.mjs`; the other 46 files run only if someone types `node --test tests/`. There is no CI workflow. Around 40 of the 47 files are regex assertions against source text (they pass on a broken-but-textually-similar implementation and fail on harmless refactors); two re-implement the algorithm inside the test; three genuinely execute app code.

### C3. LOW — Template residue and stale docs
`README.md` is the untouched vinext-starter README (no mention of OpenGym, Supabase, env vars, push, or the SQL deployment story). Dead template code: `app/chatgpt-auth.ts` (unused; its `safeRelativeReturnPath` also lets `/\evil.com` through as `//evil.com`), `db/`, `drizzle/`, `examples/d1/`, `app/_sites-preview/`, `next.config.ts`, unused SVGs, Tailwind (one utility class used). Both `package-lock.json` and `pnpm-lock.yaml` are committed. `tsconfig.tsbuildinfo` is not gitignored. `eslint.config.mjs` ignores `build/**`, which is where `build/sites-vite-plugin.ts` lives. `supabase/migrations/README.md` and `docs/qa/SUPABASE_CLI_MIGRATIONS.md` both say the migrations directory is empty; it holds 11 files.

### C4. LOW — Worker
`worker/index.ts` exposes `/_vinext/image` although the app never uses `next/image`; `IMAGES.input` throws (500) if the binding is absent. `Env` types `DB` and `IMAGES` as required while `.openai/hosting.json` sets `d1:null`. No explicit `Cache-Control` for `sw.js` or the manifest.

---

## 4. Internationalisation — `app/i18n.ts`

### I1. MEDIUM — Conflicting duplicate keys
Five keys are defined twice with different translations; the later `Object.assign` block wins and the earlier is dead. Notably `Reverse` is 撤回 (line 91) and 撤销 (line 190) in zh-CN while the confirmation copy uses 撤回, so button and dialog disagree.

### I2. MEDIUM — Copy drift leaves strings untranslated
Verified present in `WaitlistApp.tsx` and absent from the dictionary: the four "Use Swap…" tutorial lines (keys still say "Use Substitute…"), "Rejoin Requests are usually…return to you…", "Your name is added…press “Join waitlist”", "Restricted members", the short "When your team is playing…" line, the entire facility picker/creation screen, and roughly 60 error/notice titles including "Connection needed", "Location is * REQUIRED * to join", "Two teams required", "Unable to fill in". Two dynamic patterns (`^(.+) started Game (\d+)\.$`, `^Rejoin requests \((\d+)\)$`) match text the app never emits.
**Fix:** a test that extracts JSX string literals and asserts es/zh coverage; dedupe the `Object.assign` blocks.

---

## 5. Database layer — `supabase/*.sql`

Context: 111 SQL files, ~9,100 lines. The root `supabase/*.sql` files were applied by hand in the SQL editor in the order recorded in `docs/qa/PLAYOPENGYM_QA_PROGRESS.md`; the 11 files in `supabase/migrations/` were applied by CLI and are the most recent definitions. The **base schema** (tables `waitlist_players`, `waitlist_config`, `waitlist_events`, `past_games`, `admin_sessions`, `admin_undo`, `rejoin_responses`, `group_requests`, `push_subscriptions`) is **not in the repository**, so its permissive RLS policies and function ownership can only be inferred. Items marked *verify live* should be checked with `select proname, proowner::regrole, prosecdef from pg_proc where pronamespace='public'::regnamespace` and `select * from pg_policies where schemaname='public'`.

### Security

**S1. HIGH — Any player can take over another player's identity via `device_id`.**
`supabase/prevent-duplicate-device-players.sql:42-45` (`join_waitlist_for_device`, the only browser join entry point):
```sql
select * into player from public.waitlist_players
  where facility_id=fid and device_id=p_device_id and status<>'left' for update;
if player.id is not null then
  update public.waitlist_players set user_id=null where facility_id=fid and user_id=auth.uid() and id<>player.id;
  update public.waitlist_players set user_id=auth.uid(),updated_at=now() where facility_id=fid and id=player.id;
```
Whoever supplies a matching `device_id` becomes the owner of that row; there is no check that the existing `user_id` is null or equals `auth.uid()`. `device_id` is not secret: every facility member can `select *` on `waitlist_players` (the app itself does at `WaitlistApp.tsx:589`) and the realtime subscription delivers full rows including `device_id` to every client. An attacker reads a victim's `device_id`, calls the RPC with it, and can then leave, rename, sit out, or answer rejoin/swap prompts as the victim, whose own app now shows them as not joined.
**Fix:** only re-own when `player.user_id is null or player.user_id = auth.uid()`, otherwise raise; revoke column-level select on `device_id` (grant the explicit column list the app uses) and exclude it from the realtime publication; consider storing a salted hash.

**S2. MEDIUM — `device_id` is a client-generated string, so the duplicate-device guard is bypassable by design.** `prevent-duplicate-device-players.sql:38-40` only checks length 16–100; clearing `localStorage` (or calling the RPC with any fresh string) yields a second active player. Treat it as a convenience, not a control; a server-issued signed token or join throttling would be needed for real enforcement.

**S3. MEDIUM — Facility isolation relies on function ownership, and several later functions were never re-owned or scoped** (*verify live*). `multi-facility-tenancy.sql:112-120` re-owns SECURITY DEFINER functions to `opengym_runtime` so the restrictive `facility_isolation` policy applies to them. Functions created afterwards default to owner `postgres` (bypasses RLS) unless the file re-owns them. Three trigger bodies have no `facility_id` predicate and would write across facilities if postgres-owned: `restore_advanced_team_memberships` (`preserve-teams-on-next-game.sql:4-33`, applies the latest `king_round_history` snapshot from *any* facility), `capture_past_game_team_rosters` (`past-game-team-rosters.sql:4-35`, reads `king_teams` by court number only), `notify_group_request` (`group-request-notifications.sql:3-16`, reads `waitlist_config` without facility). **Fix:** add `where facility_id = new.facility_id` to all three and `alter function … owner to opengym_runtime`; reconcile `pg_proc.proowner` for every `prosecdef` function.

**S4. MEDIUM — `reverse_next_game` was retired, then re-exposed without the guards every other reverse has.** `retire-unguarded-team-reverse.sql:6` revoked it; `harden-rpc-execute-grants.sql:45` allowlists it again and the app calls it (`WaitlistApp.tsx:1193`) from the "Next game started" notices, including for non-operators reversing their own advance. It takes no facility/expected-game argument (the multi-tab facility-switch race the QA doc rated P0 for `reverse_king_game`) and restores a whole-facility snapshot (see L5). **Fix:** route regular-mode reverse through `reverse_past_game_guarded` and revoke `reverse_next_game`.

**S5. MEDIUM — Replaying `multi-facility-tenancy.sql` breaks login.** Lines 190-206 textually rewrite every function body, turning `on conflict(user_id)` into `on conflict(facility_id,user_id)`. That hits `select_facility` and `sign_in_waitlist_admin`, whose tables have no such unique index, so the rewritten functions fail with `42P10`. Production works only because the live bodies differ from this file. Delete the blanket rewrite block.

**S6. MEDIUM — Undo/redo/reverse restores drop `device_id` and corrupt history.** `restore_waitlist_state` (`fix-mode-switch-facility-scope.sql:74-88`) deletes all facility players and re-inserts from the snapshot; the insert column list omits `device_id` (every undo erases the duplicate-device bindings), the delete cascades `geofence_return_prompts`, `team_fill_ins`, `team_substitutes` and pending requests, the re-insert fires `waitlist_player_history` (a fake "joined the waitlist" event per player), and re-inserting `past_games` fires `capture_past_game_team_rosters` which overwrites historical rosters with the current teams. **Fix:** restore all columns, gate history/roster triggers with a GUC during restores, or switch to the diff-merge model `reverse_past_game` already uses.

**S7. LOW — Admin sign-in has no brute-force protection and sessions never expire.** `sign_in_waitlist_admin` (`multi-facility-tenancy.sql:147-161`) allows unlimited attempts from any anonymous session; `admin_sessions` rows are never expired and `is_waitlist_admin()` ignores `created_at`.

**S8. LOW — `admin_move_king_player_to_empty` accepts `court_side = null`.** `fix-admin-rpc-facility-scope.sql:73`: `p_court_side not in (1,2)` is NULL for NULL input, so a third `current` team with `court_side=null` can be inserted on a court; the function also skips the 6-member cap. Use `coalesce(p_court_side,0) not in (1,2)`, add the cap, and add a partial unique index on `(facility_id, court_number, court_side) where status='current'`.

**S9. INFO (*verify live*) — `push_subscriptions`.** The tenancy file adds `facility_id` and a restrictive policy but no permissive policy is in the repo; `push.ts` upserts on `endpoint` without `facility_id`. Depending on the live policy, re-enabling push after changing facility either fails RLS or enrolment fails entirely.

**S10. INFO — Every `waitlist_events` row (including geofence departures and host changes) is broadcast to every facility member via realtime;** "Your history" filtering is client-side only.

Not found: SQL injection (dynamic SQL uses `%I`/`regprocedure`), missing `search_path` on SECURITY DEFINER functions, grants to `anon`, or function-overload ambiguity.

### Logic

**L1. HIGH — Sit-out, leave, and geofence paths use a single-court allocator that destroys multi-court games.**
`normalize_active_waitlist` (`fix-player-actions-facility-scope.sql:24-45`, final version) demotes every `current` player to `waiting`, then promotes the lowest `max_players` positions back to `current` **without setting `court_number`** and without reading `waitlist_courts`. It is called from `admin_set_player_sitout`, `admin_unsit_player`, `admin_leave_player`, `sit_out_one_game`, `sit_out_and_leave_group`, `remove_self_for_geofence` and `return_after_geofence`. With two courts and 24 players in play, one player tapping Sit out leaves 12 in `current` (spanning both courts with stale court numbers, promoted players with `court_number=null`) and dumps the other 12 to the waitlist. Every join/move/add path already uses the court-aware `fill_open_court_slots()`. **Fix:** make `normalize_active_waitlist` a thin wrapper over `fill_open_court_slots()` with no demotion step, or delete it.

**L2. HIGH — Court seating race: three different advisory-lock keys plus `FOR UPDATE SKIP LOCKED`.** `king_fill_courts` (`fix-next-game-facility-scope.sql:125-128`) checks "side empty" then picks the head team with `skip locked`. Its callers serialize on *different* global keys: `7429101` (`end_court_game`, `answer_rejoin_prompt`, `admin_set_court_count`, `reverse_past_game`), `7429201` (`join_king_team`, `king_prepare_player`, `admin_move_king_player*`, `set_open_gym_mode`), `7429202` (`end_team_rotation`, `end_team_king_game`), and none for `cleanup_king_rejoin_expirations` (called by every client every 60 s). Nothing prevents two `current` teams on one `(facility_id, court_number, court_side)`. **Fix:** one per-facility lock (`pg_advisory_xact_lock(hashtext('opengym:'||fid::text))`) in every mutating RPC, drop `skip locked`, add the partial unique index from S8. Per-facility keys also stop all facilities serialising on one global key.

**L3. MEDIUM — Lock-order deadlock between the guard wrappers and everything else.** `assert_expected_court_game` (`guarded-game-actions.sql:26-27`) locks the `waitlist_courts` row `for update` and *then* `end_court_game` takes the advisory lock; `reverse_past_game` and `admin_set_court_count` take the advisory lock first and then touch court rows. Concurrent Next Game vs Reverse on one court deadlocks (`40P01`). Take the advisory lock before the row lock in the wrapper.

**L4. MEDIUM — Regular-mode rejoin and leave still use single-court capacity and drop `court_number`.** `answer_rejoin_prompt` (`fix-rejoin-facility-scope.sql:57-65`) computes `open_slots := max_players − count(current)` across *all* courts and promotes without a court; `leave_waitlist_for_facility` (`fix-leave-waitlist-expected-facility.sql:25-32`) promotes exactly one player, ignoring groups. With two courts of 12, a vacated seat is never refilled by a rejoin. Replace both with `perform public.fill_open_court_slots()` (as migration `20260925110000` already did for the offline path).

**L5. MEDIUM — Whole-facility snapshot undo/redo/reverse erases later joins and interleaves operators.** Undoing "sit out player" ten minutes later deletes everyone who joined in between; undo stacks are per operator, so a host undo can roll back an admin's later actions. `reverse_next_game` inherits this.

**L6. MEDIUM — Teams mode never releases an emptied team, so a court side can be permanently dead.** All leave paths set `status='left'` but keep `team_id`; no path deletes a `current` team whose last member left, and `king_fill_courts` only fills sides with no current team. Both members of a two-person team leaving blocks that side until an operator drags someone in, and `end_team_rotation` will rotate the empty team. **Fix:** delete member-less `king_teams` rows in each leave path (or an AFTER UPDATE trigger on status) and call `king_fill_courts()`.

**L7. MEDIUM — Midnight reset is Pacific-only and has no catch-up.** `midnight-reset-all-facilities.sql:10-16` uses `America/Los_Angeles` for every facility and returns unless the local hour is 0; there is no `facilities.timezone`, and a missed 00:xx run skips that day. Add a per-facility timezone and reset whenever `local_date > last_reset_date`.

**L8. MEDIUM — Rejoin expiry is enforced only by clients.** Expired `rejoin` rows are finalised only when a browser calls `cleanup_king_rejoin_expirations` (once per minute per client) or an operator opens the offline list. With no app open, expired players hold positions indefinitely. Schedule it in `pg_cron` per facility.

**L9. LOW — Contradictory teams-rejoin rotation rule.** `team-rotation-preserve-first.sql:29` keeps side 1 when one team is waiting; `preserve-empty-rotation-teams.sql:35` and `fix-next-game-facility-scope.sql:170` keep side 2. Pick one and delete the other file.

**L10. LOW — `fill_open_court_slots` head-of-queue group blocks a court.** `harden-player-grouping.sql:20` exits the loop when the first waiting group does not fit, even if singles behind it would; its final ranking excludes `sitout` rows so waiting and sit-out players can share a `queue_position`.

**L11. LOW — "Accept all rejoins" writes N undo snapshots** (`fix-offline-rejoin-expected-facility.sql:30-37`), pushing the operator's real history out of the 5-entry retention.

### Frontend/SQL drift
- All 61 RPC names and argument names called from `WaitlistApp.tsx` exist in SQL, and the `harden-rpc-execute-grants.sql` allowlist matches that set. No drift.
- Dead but still-defined SECURITY DEFINER functions with legacy unscoped bodies: `end_current_game`, `end_king_game`, `set_king_max_wins`, `reverse_king_game`, `rejoin_waitlist_at_back`, `leave_waitlist`, `admin_accept_all_offline_rejoins`, `fill_one_court_slots`, `repair_active_court_assignments`, `next_game_player_ids`. Drop them in a migration.
- `supabase/fix-waitlist-read-join-geofence-facility-scope.sql` no longer byte-matches the applied migration `20260924020558` (the migration carries an extra grant), despite the QA doc's "byte-for-byte aligned" claim.

### Migration hygiene
1. `teams-rejoin-waitlist-mode.sql:44,109` use `as $ … end; $;` — invalid dollar quoting; the file cannot be replayed as written.
2. Five files regex-edit live function bodies via `pg_get_functiondef` (`multi-facility-tenancy.sql:190-206`, `reverse-latest-court-game.sql:44-63`, `team-substitute-next-game.sql`, `fix-facility-player-join.sql`, `fix-king-player-null-owner-authorization.sql`). Their result depends on what was live at the time. Concrete hazard: the root `fix-group-and-king-action-facility-scope.sql:93,122,140` still contains the vulnerable `player.user_id<>auth.uid()` guard (NULL-owner bypass) that the CLI patch fixed in place; re-applying that root file in another environment re-introduces the bypass. Rewrite the source with `is distinct from`.
3. Most historical files have no `begin/commit`, and several mutate data at deploy time (`select public.fill_open_court_slots()`, `delete from public.king_teams …`), so replays change live data.
4. No baseline for the base schema exists in the repo; the environment cannot be rebuilt or its RLS audited from source.
5. Six advisory-lock magic numbers are duplicated across ~40 files with no single definition, which is how L2 happened.

---

## 6. Improvement suggestions (beyond bug fixes)

1. **Split `WaitlistApp.tsx`.** One 227 KB file with 5,000-character lines is the root cause of most of the above: stale closures, fire-once effects, DOM hacks. Suggested cut: `useQueueData` (fetch/realtime/refresh with request sequencing), `useDragAndDrop` (regular) and `useKingDrag` (teams), `NoticeQueue`, `Tutorial*`, `KingBoard`, `QueueCard`, and a thin `App` that composes them. Run Prettier so diffs become reviewable.
2. **One snapshot RPC.** Replace the 14-query `refresh()` with a single `get_facility_snapshot()` that returns players, config, courts, teams, fill-ins, substitutes, pending requests and own-player status in one JSON payload, filtered server-side by the session facility.
3. **Server-side notifications.** Emit pushes from a database trigger/queue so delivery does not depend on the advancing player's phone, and so the edge function can authorise recipients itself.
4. **Structured events.** Give `waitlist_events` typed columns (`court_number`, `game_number`, `kind`) and let the client format the sentence in the user's language, replacing regex parsing of English messages and the DOM-walking translator.
5. **Real tests.** Stand up `supabase start` in CI, apply the migrations, and turn the highest-value regex tests (facility scoping, advance/reverse idempotency, undo/redo) into SQL tests that call the RPCs. Keep a few Playwright smoke flows (join, next game, rejoin, drag) against the local stack. Make `npm test` run everything.
6. **Migration ledger.** Follow through on `docs/qa/SUPABASE_CLI_MIGRATIONS.md`: reconcile the remote history, squash the 90 historical files into a reviewed baseline, and stop applying SQL by hand through the dashboard.
7. **Name policy.** Whole-token matching, a much shorter list of always-blocked substrings, and an admin override for false positives.
8. **Anonymous-user hygiene.** Reuse the existing anonymous session on "Continue as guest" instead of signing out/in, and schedule a job to delete anonymous users older than a day.
9. **Rate-limit admin sign-in.** `sign_in_waitlist_admin` is callable by any anonymous session with no attempt counter; bcrypt slows brute force but a per-facility lockout or `pg_net`-free counter table is cheap.
10. **Housekeeping.** Delete template residue, rewrite the README for OpenGym (env vars, deployment, SQL story, test commands), pick one lockfile, gitignore `tsconfig.tsbuildinfo`, fix manifest icons, cap the recovery reloads.
