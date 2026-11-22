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

### SMS codes (Twilio Verify)

Sign-up and password reset send a real SMS code through the `dorly-otp` Edge Function. Sign-up refuses any phone number that wasn't verified this way. The function needs three secrets, set in Supabase under **Edge Functions → Secrets**:

| Secret | Where to find it |
|---|---|
| `TWILIO_ACCOUNT_SID` | Twilio Console home page ("Account SID") |
| `TWILIO_AUTH_TOKEN` | Twilio Console home page ("Auth Token") |
| `TWILIO_VERIFY_SID` | Twilio Console → Verify → Services → your service ("Service SID", starts with `VA`) |

Until they are set, sign-up and password reset show "خدمة الرسايل مش متاحة دلوقتي".

### Known limits

- Verification documents (ID, commercial register) are recorded by file name only and are not uploaded yet.
