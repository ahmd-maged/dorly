# دورلي — Dorly

An Arabic (Egyptian) iPhone marketplace: buy, sell and trade used iPhones, with a seller dashboard and an admin console.

- `dorly.html` — the public site (buyers, sellers, merchants). `index.html` redirects here.
- `admin.html` — admin console (admins only).
- `assets/dorly-cloud.js` — connects both pages to Supabase: loads data, saves changes, logins and photo uploads.
- `vendor/supabase.js` — supabase-js 2.45.4 (UMD build), served locally.
- `supabase/` — database migrations, sample data (`seed.sql`) and the `dorly-signup` Edge Function.

There is no build step: it is a static site, deployed on Vercel straight from this repository.

## Backend (Supabase)

All tables are prefixed `dorly_`. Security is enforced in the database, not in the browser:

- **Row Level Security** on every table. Visitors see active listings and public seller info only. Sellers see and edit their own listings, inquiries and private details. Admins see everything.
- **Guard triggers** stop sellers from approving their own listings, raising their verification level or giving themselves badges.
- **Sign-up** goes through the `dorly-signup` Edge Function, which creates the account with the service role, so nobody can sign up as an admin.
- **Photos** go to Storage. Listing photos are public (`dorly-public`). Settings screenshots are private (`dorly-private`), readable only by the owner and admins.

### Make someone an admin

The user registers normally on the site first. Then run this in the Supabase SQL editor:

```sql
select set_config('request.jwt.claims','{"role":"service_role"}',false);
update dorly_profiles set role = 'admin' where phone = '01XXXXXXXXX';
```

### Sign-up verification (currently off)

Sign-up creates the account right away, with no SMS or e-mail code. The `dorly-otp` Edge Function, which e-mails codes through Brevo's free plan, is ready for later. To turn verification back on: set `BREVO_API_KEY` and `DORLY_MAIL_FROM` in Supabase **Edge Functions → Secrets**, add the `otp` step back to `RSTEPS` in `dorly.html`, and require the token again in `dorly-signup`. Git history has that version (commit "Verify accounts by e-mail code").

### Known limits

- Phone numbers and e-mails are not verified, and password reset goes through the team.
- Verification documents (ID, commercial register) are recorded by file name only and are not uploaded yet.
