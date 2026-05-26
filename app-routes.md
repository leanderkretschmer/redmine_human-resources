# Companion-app routes — what the plugin currently exposes

This document lists every endpoint the `redmine_human_resources` plugin
*currently* provides, with the shape a phone/wall companion app needs:
HTTP method, path, auth, body, response, and notes on whether it is
machine-friendly (JSON) or HTML-only.

Sourced from `config/routes.rb`, `app/controllers/hm_timeclock_controller.rb`
and `lib/redmine_human_resources/snapshot.rb`. No endpoints in this list are
hypothetical — they all exist on `main` today.

> **Reader-mode endpoints (signed-token toggle, BLE identifier ingestion) are
> NOT yet implemented.** See "Gaps for the BLE flow" at the bottom.

---

## Authentication

The plugin does not define its own auth — every controller uses Redmine's
standard `before_action :require_login`. Two ways to authenticate from a
companion app:

1. **Redmine API key** (recommended for an app). Each user has a unique
   API key under *My account → API access key*. Send it as:
   - HTTP header: `X-Redmine-API-Key: <key>`, *or*
   - query string: `?key=<key>`
2. **Session cookie**. Useful if the app embeds a `WKWebView`/`WebView` that
   the user logs into normally; otherwise harder to acquire programmatically.

All examples below use the API-key header form.

## Content negotiation

`Accept: application/json` (or path suffix `.json` on routes that allow it)
is required to get a JSON body. Without it, controllers redirect/render HTML.
Endpoints that currently support JSON are marked **[JSON]** below; the rest
are HTML/CSV only.

---

## Identifying the user

The plugin has no "who am I" endpoint of its own — it always operates on
`User.current` derived from the API key or session. To resolve the API key
to a Redmine user **id** and **login name**, use Redmine core:

```
GET /users/current.json
Headers: X-Redmine-API-Key: <key>

Response 200 (excerpt):
{
  "user": {
    "id": 42,
    "login": "anna.muster",
    "firstname": "Anna",
    "lastname": "Muster",
    "mail": "anna@example.com",
    "api_key": "..."
  }
}
```

For the BLE flow, the companion app advertises one of:

- `user.id` (stable integer, never changes)  → recommended
- `user.login` (string, *can* be renamed by an admin)

Pair the identifier with a per-app secret + HMAC + timestamp so the wall
device cannot replay a captured advertisement (see `reader-implimentations.md`
for the token format).

---

## Timeclock — read endpoints

### `GET /hm_timeclock/status` **[JSON]**

The canonical snapshot the navbar ticker and the in-app timer should both
read. Safe to poll every 10–30 s.

```
GET /hm_timeclock/status
Headers: X-Redmine-API-Key: <key>
        Accept: application/json
```

**Response 200** (shape from `RedmineHumanResources::Snapshot#to_h`):

```jsonc
{
  "state": "idle | working | on_break | needs_correction",
  "as_of_unix": 1715433600,
  "work_started_at_unix": 1715420400,        // null when idle / needs_correction
  "current_break_started_at_unix": null,     // set only when on_break
  "worked_seconds_today": 4321,
  "current_break_seconds": 0,
  "total_break_seconds_today": 0,
  "daily_target_seconds": 28800,
  "max_break_seconds": 3600,
  "overtime_threshold_seconds": 28800,
  "expected_end_unix": 1715448000,           // null until first start of day
  "first_today_started_at_unix": 1715420400,
  "pending_correction": null,                // populated when state=needs_correction
  "notify_target_reached": true,
  "notify_break_over": true,
  "poll_interval_seconds": 30,
  "labels": {
    "target_reached":   "Soll-Arbeitszeit erreicht.",
    "break_over":       "Pause vorbei.",
    "needs_correction": "Offener Arbeitszeit-Eintrag — Korrektur erforderlich",
    "target_done":      "Soll erfüllt"
  }
}
```

The `state` field is the single source of truth — use it to choose what
button(s) the app shows:

| `state`            | Display                       | Permitted action    |
|--------------------|-------------------------------|---------------------|
| `idle`             | "Clock in" button             | POST `/start`       |
| `working`          | running timer + Pause + Stop  | POST `/pause` or `/stop` |
| `on_break`         | break timer + Resume + Stop   | POST `/resume` or `/stop` |
| `needs_correction` | banner + link to web UI       | (no mobile action — web only) |

When `state == "needs_correction"`, `pending_correction` carries the
information you'd need to render a corrective form, but the actual
`POST /correct/:id` action is form-encoded HTML only (no JSON path) — for now,
deep-link out to the Redmine web UI for that case.

### `GET /hm_timeclock/calendar` **[JSON]**

Per-day net-worked totals for one month. Used to render the monthly
"how much did I work" calendar.

```
GET /hm_timeclock/calendar?month=2026-05
Headers: X-Redmine-API-Key: <key>
        Accept: application/json
```

`month` is `YYYY-MM`; omit to default to the current month.

**Response 200**:

```jsonc
{
  "month": "2026-05-01",
  "days": [
    { "date": "2026-05-01", "seconds": 0 },
    { "date": "2026-05-02", "seconds": 28920 },
    /* ... one entry per day of the month ... */
    { "date": "2026-05-31", "seconds": 0 }
  ]
}
```

### `GET /hm_timeclock/export` (CSV)

Per-month CSV export for the current user — useful if the app wants a
"share my month" button.

```
GET /hm_timeclock/export?month=2026-05
Headers: X-Redmine-API-Key: <key>
```

Returns `Content-Type: text/csv; charset=utf-8` with filename
`hm_timeclock_<login>_<YYYY-MM>.csv`. Not JSON, not paginated.

### `GET /hm_timeclock/` (HTML only)

The full Stempeluhr web page. Not useful for the app except as a deep-link
target (e.g. when the app needs to bounce out for correction).

### `GET /hm_timeclock/settings` (HTML only)

The settings form. JSON equivalent is `update_settings` below — there is
no JSON GET for the current values today; the relevant numbers live in the
`/status` snapshot (`daily_target_seconds`, `max_break_seconds`, …).

---

## Timeclock — write endpoints

All four state-change actions return the **fresh snapshot** as JSON when
called with `Accept: application/json`. Idempotency rules:

- `start` when already `working`/`on_break` → no-op (still 200).
- `pause` when not `working` → no-op.
- `resume` when not `on_break` → no-op.
- `stop` when `idle` → no-op.
- Any state-change call while `state == needs_correction` → no-op + flash
  warning, *no* state mutation. The app must resolve the correction first
  (web UI, see above) before further taps take effect.

### `POST /hm_timeclock/start` **[JSON]**

```
POST /hm_timeclock/start
Headers: X-Redmine-API-Key: <key>
        Accept: application/json
        Content-Length: 0
```

Body: none. Response: same shape as `/status`.

### `POST /hm_timeclock/pause` **[JSON]**

Same shape as `/start`. Closes the current running interval implicitly by
opening a `hm_break_entries` row.

### `POST /hm_timeclock/resume` **[JSON]**

Same shape. Closes the open break row, returns to `working`.

### `POST /hm_timeclock/stop` **[JSON]**

Same shape. Closes the open break (if any) and the work entry.

### `POST /hm_timeclock/correct/:id` (HTML only)

Form-encoded `ended_at=HH:MM` or an ISO timestamp. No JSON support today —
the app should *not* call this; bounce the user to the web UI when
`state == needs_correction`.

### `POST /hm_timeclock/settings` **[JSON]**

Updates per-user target/break/notification settings.

```
POST /hm_timeclock/settings
Headers: X-Redmine-API-Key: <key>
        Accept: application/json
        Content-Type: application/x-www-form-urlencoded

hm_user_setting[daily_target_minutes]=480
hm_user_setting[weekly_target_minutes]=2400
hm_user_setting[max_break_minutes]=60
hm_user_setting[notify_target_reached]=1
hm_user_setting[notify_break_over]=1
```

Response 200: fresh snapshot. Response 422 on validation error:

```json
{ "errors": ["Daily target minutes must be greater than 0"] }
```

---

## Absences — vacation & sickness

Currently HTML/form-encoded only. There is no JSON content type wired up on
these controllers. They are listed here for completeness — if the companion
app wants to show a "request vacation" form, the practical path today is to
open the Redmine page in an embedded webview.

| Method   | Path                              | Action               | Auth      |
|----------|-----------------------------------|----------------------|-----------|
| `GET`    | `/hm_vacation`                    | List own vacation    | logged-in |
| `POST`   | `/hm_vacation`                    | Create vacation      | logged-in |
| `GET`    | `/hm_sickness`                    | List own sickness    | logged-in |
| `POST`   | `/hm_sickness`                    | Create sickness      | logged-in |
| `POST`   | `/hm_absences`                    | Create (kind in body)| logged-in |
| `GET`    | `/hm_absences/:id/edit`           | Edit form            | owner or admin |
| `PATCH`  | `/hm_absences/:id`                | Update               | owner or admin |
| `DELETE` | `/hm_absences/:id`                | Delete               | owner or admin |
| `POST`   | `/hm_absences/:id/approve`        | Approve              | admin     |
| `POST`   | `/hm_absences/:id/reject`         | Reject               | admin     |

`POST /hm_absences` body:

```
hm_absence[kind]=vacation|sickness
hm_absence[starts_on]=2026-06-01
hm_absence[ends_on]=2026-06-07
hm_absence[reason]=Sommerurlaub
```

Response: redirect (HTML). To make this usable from a native app you would
need to add `respond_to :json` blocks — currently out of scope.

---

## Admin endpoints

HTML only, gated by Redmine admin. Listed for completeness.

| Method | Path                                    | Action            |
|--------|-----------------------------------------|-------------------|
| `GET`  | `/admin/hm_timeclock`                   | Global overview   |
| `GET`  | `/admin/hm_timeclock/day/:date`         | Day drill-down    |
| `GET`  | `/admin/hm_timeclock/users/:user_id`    | Per-user detail   |

---

## Minimal companion-app flow (using only existing endpoints)

```
1. App start
   GET /users/current.json
      → store user.id, user.login, user.firstname
   GET /hm_timeclock/status
      → render state, timer, expected end

2. Background poll every 30 s (or 10 s while screen on)
   GET /hm_timeclock/status
      → reconcile local timer with server truth
      → fire local notification when:
          - state was "working" and worked_seconds_today crosses daily_target_seconds
            AND notify_target_reached is true
          - state was "on_break" and current_break_seconds > max_break_seconds
            AND notify_break_over is true

3. Buttons
   "Clock in"  → POST /hm_timeclock/start   → use returned snapshot
   "Pause"     → POST /hm_timeclock/pause   → use returned snapshot
   "Resume"    → POST /hm_timeclock/resume  → use returned snapshot
   "Clock out" → POST /hm_timeclock/stop    → use returned snapshot

4. Correction
   If snapshot.state == "needs_correction":
      → show banner with snapshot.pending_correction.started_at_label
      → "Open in Redmine" button → deep-link to /hm_timeclock

5. Monthly view
   GET /hm_timeclock/calendar?month=YYYY-MM
   "Export" button → GET /hm_timeclock/export?month=YYYY-MM (share sheet)
```

---

## BLE identifier delivery — what the wall device needs

The wall reader only needs to know **who tapped** and **what they want
(in / out / auto)**. Given the existing endpoints, the cheapest possible
wall-device implementation is:

1. **Phone app authenticates to Redmine itself** via its stored API key.
2. **Phone fetches `/users/current.json`** at install time, caches `id` and
   `login`.
3. When the BLE app detects the wall device's service UUID + RSSI threshold,
   it directly POSTs `/hm_timeclock/start` or `/hm_timeclock/stop`
   (or computes "auto" from a fresh `/status` and chooses the right verb)
   *itself*, using its own API key.
4. The wall device's only job is to **broadcast a static service UUID**
   and to **poll its own "what just happened?" feed** (not yet implemented;
   see gaps) so it can show the greeting.

This phone-central design means **no signed-identifier protocol is needed
over the air** — the identifier is implicit in the API key on the phone,
the wall device never sees it, and a captured BLE advertisement (which only
contains the wall device's service UUID) is useless to an attacker.

If you instead want the **wall device** to be the one talking to the Redmine
server (because you do not trust phones to have their own API keys, or you
want a kiosk-style flow where the phone never holds credentials), then the
identifier needs to travel over the air and the new endpoints in
"Gaps for the BLE flow" below must be added first.

---

## Gaps for the BLE flow (not yet in the plugin)

To support a wall device that *posts on behalf of* a user (rather than the
user's own app doing it), the following endpoints would need to be added.
None of them exist today:

- `POST /hm_timeclock/reader_toggle`
  Body: `{ token, nonce, action }` where `token` is a server-issued,
  HMAC-signed payload containing `user_id|ts|nonce`. Returns a snapshot
  plus a greeting string. *Not yet implemented.*
- `GET /hm_timeclock/reader_recent?device=&since=`
  For wall devices that do not see the user's HTTP response and need to
  poll for "what just happened on me". *Not yet implemented.*
- Per-user `reader_token` column on `hm_user_settings` plus a rotation /
  revocation UI in `/hm_timeclock/settings`. *Not yet implemented.*

Until those land, the wall-mounted device is limited to **observer mode**:
it can show whoever last tapped *via the phone's own API call* by polling
`/hm_timeclock/status` for a known set of users — which only works if the
wall device has API keys for them, which defeats the point. The
phone-central design above is therefore the only one buildable against the
current routes without further server work.
