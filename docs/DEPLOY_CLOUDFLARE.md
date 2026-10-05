# Deploying OpenGym to Cloudflare Workers

OpenGym is built with vinext, which produces a Cloudflare Worker. `pnpm run build`
writes the deploy settings to `dist/server/wrangler.json`, and `npx wrangler deploy`
picks that file up automatically. There is no hand-written `wrangler.jsonc`; the
Worker name and bindings live in `vite.config.ts`.

The Supabase database is a separate service. Changing the web host does not touch
queues, players, or admin logins.

## One-time setup (Cloudflare dashboard)

1. Create a free account at https://dash.cloudflare.com.
2. Open **Workers & Pages → Create → Import a repository**, connect GitHub, and
   select `Athcora/OpenGym`. Cloudflare will ask to install its GitHub app on
   the repository.
3. Use these settings:

   | Setting | Value |
   |---|---|
   | Project / Worker name | `opengym` (must match `name` in `vite.config.ts`) |
   | Production branch | `main` |
   | Build command | `pnpm run build` |
   | Deploy command | `npx wrangler deploy` |
   | Root directory | `/` |

   Cloudflare installs dependencies with pnpm automatically (pinned through
   `packageManager` in `package.json`) and uses Node 22 from `.node-version`.

4. Under **Settings → Build → Variables and secrets**, add these as **build**
   variables. They are compiled into the browser bundle, so they must be present
   at build time, not only at runtime:

   | Variable | Value |
   |---|---|
   | `VITE_SUPABASE_URL` | Supabase dashboard → Project Settings → API → Project URL |
   | `VITE_SUPABASE_PUBLISHABLE_KEY` | Supabase dashboard → Project Settings → API Keys → publishable key |
   | `VITE_VAPID_PUBLIC_KEY` | The Web Push public key currently used in production |

   All three are public values, not secrets. The code currently falls back to the
   production values when they are missing, so the site works without them, but
   setting them explicitly is safer.

5. Save and deploy. Cloudflare gives the site a temporary address such as
   `opengym.<your-account>.workers.dev`.

## Test before moving the domain

Keep playopengym.com on its current host while you check the `workers.dev`
address on a phone:

- The facility picker loads and your facility opens from its QR link (`/g/<slug>`).
- Join as a guest, then leave.
- Admin sign-in works.
- Location check works if the facility uses one.

The temporary address talks to the **production** database, so use a test name
and leave the queue afterwards.

## Point playopengym.com at Cloudflare

Do this only after the test passes.

1. Find where the domain is registered (the company you pay for playopengym.com).
2. Either:
   - **Add the domain to Cloudflare** (Websites → Add a domain) and change the
     nameservers at your registrar to the two Cloudflare gives you, or
   - **Transfer the domain to Cloudflare Registrar**: unlock it at the current
     registrar, get the transfer/auth code, and start the transfer in Cloudflare.
3. In the Worker, open **Settings → Domains & Routes → Add → Custom domain** and
   add `playopengym.com` (and `www.playopengym.com` if you use it).
4. DNS changes can take up to a day to reach every phone. Leave the old host
   running until the new one is serving traffic.

## After setup

Every push to `main` deploys automatically. Pushes to other branches build a
preview version with its own URL, so changes can be checked before merging.

## Local check

```
pnpm install
pnpm run build
npx wrangler deploy --dry-run   # validates the bundle without uploading
npx wrangler dev -c dist/server/wrangler.json   # serves the build on the Workers runtime
```

## Alternative: Vercel

The app also builds with standard Next.js, which Vercel runs natively.
`vercel.json` makes Vercel run `next build` instead of the package `build`
script (that script produces the Cloudflare Worker). Settings are read by
`app/env.ts`, which accepts either `NEXT_PUBLIC_*` or `VITE_*` names.

1. In Vercel, **Add New → Project → Import** `Athcora/OpenGym`. Vercel's GitHub
   app needs access to the repository; an Athcora org owner may need to approve it.
2. Leave the framework and commands as detected from `vercel.json`.
3. Add environment variables `NEXT_PUBLIC_SUPABASE_URL`,
   `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY` and `NEXT_PUBLIC_VAPID_PUBLIC_KEY`
   (same values as listed above).
4. Test the `*.vercel.app` address, then add `playopengym.com` under
   **Settings → Domains** and update DNS at the registrar as Vercel instructs.

Not carried over on Vercel: the Worker in `worker/index.ts`, which set
`Cache-Control: no-store` on HTML pages. Vercel clears its cache on every
deploy, so stale pages after a release are not expected.
