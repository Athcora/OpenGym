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

_(see section appended below)_

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
