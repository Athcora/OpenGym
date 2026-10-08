# OpenGym

OpenGym is the live volleyball waitlist behind [playopengym.com](https://playopengym.com).
Players scan a facility's QR code (`/g/<facility-slug>`), join as a guest, and the
queue, courts, groups, rejoin prompts and host/admin tools update live for everyone
at that facility.

## Stack

- **Frontend:** React app in `app/` (`WaitlistApp.tsx` is the main screen), built with
  [vinext](https://github.com/cloudflare/vinext) (Next.js App Router on Vite).
- **Hosting:** Cloudflare Workers. Every push to `main` triggers a Workers Build
  ("Workers Builds: opengym" check on the commit) and deploys to playopengym.com.
- **Backend:** Supabase (Postgres, auth, realtime). Almost all game logic lives in
  SQL functions (RPCs) that the browser calls; Row Level Security keeps each
  facility's data separate.
- **Push notifications:** `public/sw.js` (service worker) and `app/push.ts`.

## Configuration

Public build-time settings (`app/env.ts`). They fall back to the production values
when unset, so set them for any non-production environment:

| Variable | Purpose |
| --- | --- |
| `NEXT_PUBLIC_SUPABASE_URL` / `VITE_SUPABASE_URL` | Supabase project URL |
| `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY` / `VITE_SUPABASE_PUBLISHABLE_KEY` | Supabase publishable key |
| `NEXT_PUBLIC_VAPID_PUBLIC_KEY` / `VITE_VAPID_PUBLIC_KEY` | Web-push public key |

## Development

```bash
pnpm install
pnpm dev            # local dev server
pnpm build          # production build
node --test tests/  # full test suite
```

## Database changes

- New database changes go in `supabase/migrations/` as timestamped files
  (`YYYYMMDDHHMMSS_description.sql`), wrapped in `begin; … commit;`.
- They are applied to production through the Supabase SQL editor; commit the file
  in the same change so the repository matches what is live.
- Older root-level `supabase/*.sql` files are historical and must not be replayed.
- Security-definer functions should be owned by `opengym_runtime` so facility
  isolation applies to them.

## Translations

UI text is translated in `app/i18n.ts` (Spanish and Simplified Chinese). Add new
user-facing strings there; player names are never translated.

## Docs

- `docs/audit/2026-09-30-opengym-audit.md` – code audit and its follow-ups.
- `docs/qa/` – QA notes.
