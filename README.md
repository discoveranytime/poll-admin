# Community Poll System

A reusable polling system: a fast public voting page + a private admin
dashboard, backed by Supabase (Postgres + Auth + Edge Functions). Built for
peptide-community polls (Retatrutide first), generic enough for any topic.

```
poll-system/
├── docs/API.md                  # the contract both frontends build against
├── public/                      # -> https://discoveranytime.github.io/retatrutide-poll/
│   ├── index.html               # the voting page (no CDN, plain fetch)
│   └── config.js                # SUPABASE_URL + ANON_KEY (empty = preview mode)
├── admin/                       # -> https://discoveranytime.github.io/poll-admin/
│   ├── index.html               # dashboard (Supabase Auth + TOTP 2FA)
│   └── config.js
└── backend/supabase/
    ├── schema.sql               # tables, RLS, triggers, RPCs, seed poll
    ├── functions/vote/index.ts  # voting endpoint: dedup, rate limit, captcha
    ├── functions/track-view/index.ts
    └── .env.example
```

## 1. Create the backend (one time, ~15 min)

1. Sign up at https://supabase.com and create a new project (free tier is plenty).
2. In the SQL editor, run `backend/supabase/schema.sql` (all of it).
3. Deploy the edge functions (needs the Supabase CLI, or use the dashboard's
   Edge Functions editor and paste the files):
   ```bash
   supabase login
   supabase link --project-ref YOUR_PROJECT_REF
   supabase functions deploy vote
   supabase functions deploy track-view
   supabase secrets set IP_SALT=$(openssl rand -hex 32)
   # optional: supabase secrets set TURNSTILE_SECRET=...
   ```
4. Create your admin login: **Authentication → Users → Add user** (email+password).
   Then in SQL: `insert into public.admins (user_id) values ('<that user''s uuid>');`
5. (Recommended) Enable TOTP MFA for your account from the admin dashboard's
   Settings tab after first login. Also consider enabling "Leaked password
   protection" under Auth → Policies.

## 2. Point the frontends at it

Edit `public/config.js` and `admin/config.js`:
```js
window.POLL_CONFIG = {
  SUPABASE_URL: "https://YOUR_PROJECT_REF.supabase.co",
  SUPABASE_ANON_KEY: "YOUR_ANON_KEY",   // Settings → API (public anon key, safe for frontend)
  TURNSTILE_SITEKEY: ""                 // optional, Cloudflare Turnstile site key
};
```
The **service_role key is never used in a frontend** — only inside edge functions.

## 3. Deploy (GitHub Pages)

- `public/` → repo `retatrutide-poll` (branch `main`, path `/`)
- `admin/` → repo `poll-admin`
- Enable Pages (Settings → Pages → Deploy from branch → `main` / `/`).

Without `SUPABASE_URL` set, the public page runs in **preview mode**
(local votes only, clearly badged) and the admin shows a setup notice.

## 4. Day-to-day

- **New poll**: Admin → Polls → New poll. Set slug, answers, schedule, disclaimer.
  The public page picks it up immediately (`?poll=your-slug`, or make it the
  open poll to feature it).
- **Moderation**: Moderation tab → validate/invalidate flagged votes, ban hashes.
- **Export**: Settings → Export CSV.
- **Retention**: Settings → data-retention days + purge button. Nothing is kept
  longer than you configure.

## Privacy model

- No account, email, or personal info needed to vote.
- Fingerprint = salted client-side hash (UA/screen/timezone/canvas), not a cookie.
- IPs are hashed server-side with a secret salt; raw IPs are never stored.
- Country is recorded only if the platform provides it (Cloudflare/Vercel header).
- CAPTCHA (Cloudflare Turnstile) is optional per poll — privacy-friendly, no tracking.

## Security notes

- Admin = Supabase Auth user listed in `admins`, with optional TOTP 2FA.
- All admin reads/writes go through Row Level Security (`is_admin()`).
- Every poll/option/ban/settings change is written to `audit_log` by DB trigger.
- Rate limiting + duplicate detection + burst heuristics live in the `vote`
  edge function (service role, not bypassable from the browser).
- Rotate `IP_SALT` only if you accept that old hashes become unlinkable
  (they remain valid as opaque strings; dedup just restarts).

## Files of record

Your data lives in **your Supabase Postgres** — exportable anytime
(SQL dump or the admin CSV export). The frontends are disposable; the database
is not.
