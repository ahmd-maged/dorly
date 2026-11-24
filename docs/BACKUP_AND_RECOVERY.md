# Dorly — backup and recovery checklist

Status: **proposed, nothing here has been run against production.** Every step that touches the
live project needs explicit approval first.

## 1. What the database snapshot does and does not cover

`supabase/proposed/phase0_backup_snapshot.sql` copies the rows of the nine Dorly app tables into the
private schema `dorly_backup_20261123`, plus a list of the files in the two Dorly Storage buckets.
It is a **safety net for a bad migration or bad bulk edit — not a disaster-recovery backup.**

| Item | In the snapshot? | Where it lives / how to back it up |
|---|---|---|
| App rows: profiles, sellers, seller_private, listings, listing_private, inquiries, complaints, verifs, audit | Yes (all columns) | the snapshot |
| Storage file **list** (bucket, path, owner, created, size/type) | Yes | `storage_objects` table in the snapshot |
| Storage file **contents** (listing photos, private settings screenshots) | **No** | §2 |
| Logins: `auth.users`, identities, sessions, password hashes | **No** | Supabase daily backups (Pro plan) or `supabase db dump` of the `auth` schema (§3); not restorable by hand |
| `dorly_otp_codes` | No (temporary, unused) | — |
| Table definitions, RLS policies, functions, triggers, grants | **No** | `supabase/migrations/*.sql` in Git + a fresh schema dump (§3) |
| Edge Functions (`dorly-signup`, `dorly-otp`) code | No | `supabase/functions/` in Git |
| Edge Function secrets (service key, etc.) | No | Supabase dashboard → Edge Functions → Secrets (record the *names* only; values are re-issued, never written down in Git) |
| Auth settings (sign-ups on/off, e-mail confirmation, redirect URLs, rate limits) | No | Supabase dashboard → Authentication (screenshot/notes, §4) |
| Storage bucket settings (public/private, size and type limits) | No | Supabase dashboard → Storage (notes, §4); the bucket policies are in the migrations |
| API settings (exposed schemas) | No | Supabase dashboard → Settings → API (notes, §4) |
| Vercel project settings, domains, deployment protection | No | Vercel dashboard (notes, §4); `vercel.json` is in Git |
| Website code | — | Git (`main`, commit of the live deployment) |

## 2. Storage file contents

Buckets: `dorly-public` (listing photos, public), `dorly-private` (inspection screenshots, private).
(Verification documents are **not** uploaded anywhere today — only their file names are stored.)

Options, in order of preference:
1. **Supabase Pro daily backups / PITR** do *not* include Storage objects — don't rely on them for files.
2. **Download with the Supabase CLI** (run on a trusted machine, with the project linked):
   `supabase storage cp -r ss:///dorly-public ./backup/dorly-public --experimental`
   `supabase storage cp -r ss:///dorly-private ./backup/dorly-private --experimental`
   Keep the private folder encrypted; it can contain personal data.
3. Or the S3-compatible Storage endpoint with `aws s3 sync` (S3 access keys from the dashboard;
   never commit them).

Check afterwards: the number of files downloaded per bucket equals the count in the snapshot's
`storage_objects` table taken at the same time.

## 3. Schema, policies, functions and logins

On a trusted machine with the Supabase CLI linked to the project:
- `supabase db dump -f backup/schema.sql` (tables, RLS policies, functions, triggers, grants)
- `supabase db dump --data-only -f backup/data.sql` (all data, including `auth` — contains password
  hashes and personal data: store encrypted, delete when no longer needed)
- `supabase db dump --role-only -f backup/roles.sql`

Compare `backup/schema.sql` with the migrations in Git; any difference is drift worth recording.

## 4. Settings to record (read-only, no values of secrets)

- Authentication: providers enabled, "allow new users to sign up", confirm e-mail on/off,
  site URL and redirect URLs, rate limits.
- Storage: each bucket's public flag, file size limit, allowed MIME types.
- API: exposed schemas (expected: `public`, `graphql_public`).
- Edge Functions: list, `verify_jwt` per function, secret **names**.
- Vercel: production branch, domains, deployment protection (Vercel Authentication on Previews),
  environment variables (names only; currently none).

## 5. Restore procedure (database rows)

`supabase/proposed/restore_from_backup.sql` — **do not run without approval.**
- Re-inserts only rows that are missing; never overwrites or deletes existing rows.
- Disables the guard/validation triggers during the copy so restored values (status, owner, payment,
  badges) are kept as they were, and re-enables them before commit.
- Order follows the foreign keys: profiles → sellers → seller_private → listings → listing_private →
  inquiries → complaints → verifs → audit.
- Ends with a check that every backed-up row exists again; otherwise everything rolls back.
- Tested locally: after deleting all rows of all nine tables, the restore made every table
  byte-identical to the state before deletion (see the Phase 1 report).
- Limitation: profiles reference `auth.users`. A profile whose login no longer exists cannot be restored
  until the login is restored from a full backup (§3).

## 6. Orphaned uploads

Photos are uploaded to Storage just before their listing row is saved. If the save is rejected the
files stay behind ("orphans"). The pages now (a) check the form against the same limits as the
database *before* uploading and (b) reuse files already uploaded when the user fixes the form and
retries, so orphans should be rare. To clean up what remains:

1. Run `supabase/proposed/storage_orphans_report.readonly.sql` (read-only; lists files older than
   24 h that no listing references).
2. Review the list; download a copy of those files (§2) if in doubt.
3. Delete them through the Storage API or dashboard (not SQL `DELETE` on `storage.objects`, which
   would leave the actual files behind).
Do this by hand, monthly or after an incident; do not automate deletion until it has been run
manually a few times.

## 7. Recommended order for the Phase 1 changes (each step needs approval)

1. Deploy the new pages first (`dorly.html`, `admin.html`, `assets/dorly-cloud.js`). They work with
   and without the database validation. The *old* pages can produce one value the validation refuses:
   a website link typed without `https://` in the seller dashboard. So the validation must not go live
   before the new pages.
2. Re-run `phase1_check_existing_rows.readonly.sql`; expect zero rows with a non-null `problem`.
3. Take the snapshot (`phase0_backup_snapshot.sql`); every `ok` must be true.
4. Optional full backup: download Storage contents (§2) and a schema dump (§3).
5. Apply `phase0_restrict_complaints.sql`, then `phase1_input_validation.sql`.
6. Rollback scripts are in `supabase/proposed/rollback/`.
7. The updated sign-up Edge Function (`supabase/functions/dorly-signup`) is optional: the deployed
   version stays compatible (it shortens document names to 120 characters, within the new limit of 255).
   Deploying it removes that silent shortening and returns clear errors.
