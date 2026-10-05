# Poll System — API & Data Contract

Reusable polling system. Two static frontends (public poll, admin dashboard)
on GitHub Pages + Supabase backend (Postgres + Auth + Edge Functions).

No secrets are ever committed. Frontends read `config.js`:
```js
window.POLL_CONFIG = {
  SUPABASE_URL: "https://xyzcompany.supabase.co",   // "" = preview mode
  SUPABASE_ANON_KEY: "eyJ...",
  TURNSTILE_SITEKEY: ""                              // optional, public site key
};
```

## Concepts

- **Poll**: slug-addressable (`?poll=retatrutide-interests`), status
  `draft | scheduled | open | closed`. A poll is votable when
  `status='open'`, or `status='scheduled'` and `now()` is inside
  `[scheduled_opens_at, scheduled_closes_at]`.
- **Single-choice** voting (one option per poll per participant).
- **Fingerprint**: client-generated SHA-256 of non-invasive signals
  (user-agent, screen size, timezone, language, canvas noise). No cookies
  required, no personal data. Sent as `fingerprint` (hex).
- **IP**: never stored raw. Edge functions store `ip_hash =
  sha256(IP + IP_SALT)` where `IP_SALT` is a server-side secret env var.
- **Votes** have `status`: `valid | flagged | invalid`. Public results
  count only `valid` (+`flagged` optionally, admin choice — default valid only).

## Public endpoints (anon key)

Base: `{SUPABASE_URL}`. Headers: `apikey: {ANON}`, `Authorization: Bearer {ANON}`.

### Get poll by slug
`GET /rest/v1/polls?slug=eq.{slug}&select=id,slug,title,description,topic,category,status,hide_results_until_close,require_captcha,disclaimer,theme`
RLS: only votable polls are readable.

### Default (featured) poll
`GET /rest/v1/polls?status=eq.open&select=...&order=updated_at.desc&limit=1`

### Options
`GET /rest/v1/poll_options?poll_id=eq.{id}&select=id,label,emoji,position&order=position.asc`

### Public results (RPC, respects hide_results_until_close)
`POST /rest/v1/rpc/get_public_results` body `{"p_poll_id":"uuid"}`
→ `{"hidden":false,"total":123,"options":[{"option_id":"uuid","label":"...","emoji":"🔥","votes":45,"pct":36.6}]}`  
or `{"hidden":true,"total":123,"options":[]}` when hidden and poll still open.

### Vote (Edge Function, service role inside)
`POST /functions/v1/vote`
body `{"poll_id":"uuid","option_id":"uuid","fingerprint":"hex","turnstile_token":"...?"}`
→ `200 {"ok":true,"already_voted":false,"results":{...same as get_public_results...}}`  
→ `200 {"ok":true,"already_voted":true,"results":{...}}` (duplicate fingerprint)  
→ `400 {"ok":false,"error":"poll_closed"}` / `"invalid_option"` / `"captcha_failed"`  
→ `403 {"ok":false,"error":"banned"}`  
→ `429 {"ok":false,"error":"rate_limited"}`

### Track view (Edge Function)
`POST /functions/v1/track-view` body `{"poll_id":"uuid","fingerprint":"hex"}`
→ `200 {"ok":true,"counted":true|false}` (dedupes: one counted view per
fingerprint per hour)

## Admin endpoints (authenticated user in `admins` table)

Standard PostgREST on all tables (RLS: `is_admin()`). Plus:

### Overview RPC
`POST /rest/v1/rpc/admin_poll_overview` body `{"p_poll_id":"uuid"}` →
```json
{
  "views": 1200, "votes": 340, "valid_votes": 331,
  "conversion": 28.3, "flagged": 9, "invalid": 0,
  "options": [{"option_id":"uuid","label":"...","emoji":"🔥","votes":120,"pct":36.3}],
  "votes_by_day": [{"day":"2026-10-01","votes":42}],
  "votes_by_hour": [{"hour":18,"votes":55}],
  "top_countries": [{"country_code":"US","votes":200}],
  "new_vs_returning": {"new": 210, "returning": 121},
  "bans": 2
}
```
Definitions:
- **conversion** = valid votes / counted views × 100
- **engagement** (computed client-side) = weighted score 0–100 from
  conversion, votes/day velocity, and answer spread (entropy)
- **new vs returning**: fingerprint seen in any earlier poll (or earlier than
  24h before this poll's first vote) = returning
- **peak voting times**: max of votes_by_hour / votes_by_day

### Tables (admin RLS)
`polls`, `poll_options`, `votes` (select/update status), `poll_views` (select),
`bans` (CRUD), `audit_log` (select), `admins` (select), `settings` (key/value:
`data_retention_days`, `captcha_required_default`).

Audit triggers write to `audit_log` on: poll create/update/status change,
option changes, vote status change, ban create/delete, settings change.

## Fingerprint snippet (shared, both frontends)

```js
async function fingerprint() {
  const c = document.createElement('canvas');
  const x = c.getContext('2d');
  x.textBaseline = 'top'; x.font = '14px Arial';
  x.fillText('poll-fp::' + navigator.userAgent, 2, 2);
  const raw = [
    navigator.userAgent, screen.width + 'x' + screen.height,
    screen.colorDepth, Intl.DateTimeFormat().resolvedOptions().timeZone,
    navigator.language, c.toDataURL()
  ].join('|');
  const buf = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(raw));
  return [...new Uint8Array(buf)].map(b => b.toString(16).padStart(2, '0')).join('');
}
```

## Theme JSON (polls.theme)

```json
{"accent": "#7cc7ff", "accent2": "#5eead4", "accent3": "#fb923c",
 "bg": "#06070d", "card": "#0d1020", "ink": "#edf0f9", "muted": "#a9b1c9"}
```
Public page falls back to the Retatrutide theme when empty.

## Preview mode

If `SUPABASE_URL` is empty/missing, the public page runs fully client-side:
seed options from a built-in copy of the Retatrutide poll, votes in
localStorage, visible "Preview mode — connect a backend for community results"
badge. Admin page shows a setup notice.
