# OpenGym Supabase CLI migration workflow

## Current state

- The official Supabase CLI is installed as a project-local development dependency. Use `pnpm exec supabase`.
- `supabase/config.toml` is local project scaffolding only. Its `project_id` is the repository-local name `open-gym-sites`; it is not a production project link.
- `supabase/migrations/` is intentionally empty. Existing SQL files in `supabase/` are historical deployment artifacts, not CLI migrations. QA progress records many of them as applied manually through Supabase SQL Editor.
- Do not move or rename historical SQL into `supabase/migrations/`, and do not run `supabase db push`, until the authenticated remote migration ledger has been inspected and reconciled. A new CLI installation does not know which historical scripts were applied manually. Treating them as pending migrations risks replaying schema/data changes.
- The prepared Run 4 file `supabase/fix-waitlist-read-join-geofence-facility-scope.sql` is intentionally left in its current location and has not been deployed by the CLI.

## One-time owner setup

From the repository root, the project owner should run these commands in their own terminal. The Supabase login flow stores credentials in the owner's local CLI profile; never paste credentials into chat, shell command arguments, or repository files.

```powershell
pnpm exec supabase login
pnpm exec supabase link --project-ref yxykrybhsrmxelkumxxr
```

The project ref above is the OpenGym production project ref shown in the existing Supabase dashboard. `link` may ask for the database password; enter it only into that local CLI prompt. Do not commit generated local linkage metadata or secrets.

After linking, stop before any push and inspect both histories:

```powershell
pnpm exec supabase migration list --linked
Get-ChildItem supabase/migrations
```

The remote list must be reconciled against the actual production schema and the manually applied SQL deployment history recorded in `docs/qa/PLAYOPENGYM_QA_PROGRESS.md`. If remote history is empty or incomplete, first establish a reviewed baseline/repair plan; do not mark arbitrary historical SQL as applied and do not push it. Keep historical one-off SQL out of the migration directory.

## Per-migration production gate

Only after remote and local history have been reconciled should a reviewed migration be created under `supabase/migrations/` with `pnpm exec supabase migration new <descriptive-name>`. Inspect the exact ordered migration list, then use the linked dry run:

```powershell
pnpm exec supabase db push --linked --dry-run
```

The dry run must list exactly the intended new migration and no historical or baseline SQL. If it lists anything else, stop and repair the ledger plan. Run `pnpm exec supabase db push --linked` only after the dry-run output has been reviewed and explicitly authorized. Verify deployed definitions and grants after each production push.

The normal CLI path requires both an authenticated owner CLI profile and the linked project's database password. This repository setup does not contain either credential, and neither should be requested through chat.
