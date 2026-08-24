# FARBERMAKERS Project Documentation

> Permanent technical knowledge base for the Makers Air Valet system. Update this file whenever a task introduces a new business rule, workflow, or architectural decision — see the maintenance note at the end of this document.

---

## Project Overview

**Makers Air Valet** (branded **Ascend Valet** for private-flight check-ins) is a single-page web application that runs the day-to-day valet parking operation for Makers Air, operated by Farber Parking, at a private aviation terminal (FBO). It replaces paper logs with a live system of record for every vehicle in custody.

Core purpose: **never lose, misplace, or misdeliver a vehicle.** The system tracks:
- Passenger/vehicle check-in and check-out (delivery)
- Vehicle location (hangar) at all times
- Expected return dates, including unconfirmed/approximate dates that need follow-up
- Delivery via three channels: Normal (in person), Customs, or Lockbox
- Communication with passengers via prefilled SMS (welcome, confirmation, Customs welcome-back, gratuity)
- Physical ticket printing (customer copy, key tag, dashboard tag, flight tag) via a networked Epson ePOS printer
- Daily cash/card/digital-payment closing reconciliation
- Monthly operational reporting for staffing and management

Primary users are on-site valet attendants working from iPads during live operations, plus a supervisor role that reviews reports and closings.

## Technology Stack

- **Frontend:** Single-file vanilla HTML/CSS/JS application — [index.html](index.html) (~5,800 lines: markup + inline `<script>`/styles combined with [styles.css](styles.css)). No build step, no framework, no bundler.
- **Language:** JavaScript (ES5-leaning style, `var`-based, some `async/await`), HTML5, CSS3.
- **Shared JS helpers:** [utils.js](utils.js) — XSS-escaping, date parsing/formatting, phone formatting, fuzzy name matching.
- **Fonts:** `DM Sans` (body), `Syne` (display/numeric emphasis), `DM Mono` (tags/badges).
- **Icons:** Font Awesome (`fa-solid`/`fa-regular`) for tab icons; emoji used extensively elsewhere in the UI for status/section markers.
- **Database:** Supabase (managed Postgres + REST API + Row Level Security). Accessed directly from the browser.
- **Printing:** Epson ePOS thermal printer over the local network (default IP `10.20.60.142`, reachable via `setPrinterHost()` from the browser console if it changes). Printer protocol switched from `https://` to `http://` (see Changelog).
- **Hosting:** GitHub Pages, static file hosting, no server-side runtime beyond Supabase — see Deployment section below for the full setup.
- **External services:**
  - Supabase (database, auth, RLS)
  - Device-native SMS/Messages app (system opens `sms:` links — the app never sends SMS itself)
  - Device-native Phone app (`tel:` links)
  - Stripe payment link (gratuity collection) — `https://buy.stripe.com/8x214mccK0uh9TjgIM6Vq00`
  - iOS Contacts import via generated `.vcf` files

## Deployment

**Hosting:** GitHub Pages, serving directly from the repository — no build step, no CI config, no bundler. Whatever is on the production branch's root is exactly what's served; a push is the entire deploy.

**Production repository:** [`matheusferian/farber-parking`](https://github.com/matheusferian/farber-parking) (public). This local working directory has no relationship to that repo in its own git history — it was connected via `git remote add origin` on 2026-08-24; see Development Decisions for the full reconciliation story.

**Production branch:** `main`

**Production URL:** `https://matheusferian.github.io/farber-parking/`

**Deployment trigger:** a normal, approved `git push origin main`. GitHub Pages detects the push and rebuilds automatically (`build_type: "legacy"` — no GitHub Actions workflow involved). No manual file upload is part of the normal workflow anymore.

**Normal workflow:**
```
local change → approved commit → approved `git push origin main` → GitHub Pages auto-deploys
```

**Production verification procedure** (run after every push, not assumed from a successful push):
1. Poll `GET /repos/matheusferian/farber-parking/pages/builds/latest` (via `gh api`) until `status` leaves `"building"`; confirm `status: "built"` and the `commit` field matches the pushed SHA.
2. `curl -I https://matheusferian.github.io/farber-parking/` → confirm `HTTP/2 200` and a fresh `last-modified`/`etag`.
3. Fetch `styles.css` and `utils.js` directly → confirm `HTTP 200` on each.
4. Load the production URL in a browser: confirm the AirValet login screen renders and the console has no errors.
5. Load `?mode=tv` → confirm it loads cleanly (it will show the login overlay, by design — TV Mode only activates after a real sign-in).
6. Spot-check that the specific change just shipped is actually present in the live file content (e.g. `curl` + `grep` for a marker string/constant unique to that change) — never assume the deploy contains what was intended just because the build succeeded.

**Rollback procedure (preferred — Git-based, not manual file replacement):**
```bash
git revert <bad-commit-sha>
git push origin main
```
GitHub Pages redeploys automatically from the revert; no force push, no manual upload.

**Emergency reference only — legacy backup branch:** `legacy-github-upload-history-2026-08-24`, pushed to the remote before `main` was replaced, points at `572dfaddb36e6fc7d8a45e5edaffb6f79e2c9583` — the last commit from the old manual-upload workflow (repeated "Add files via upload" commits, no real development history of its own). This branch must not be deleted. It exists purely as an emergency reference point to the exact pre-reconciliation production state; normal rollback should always use `git revert`, not this branch.

**History reconciliation status:** complete, one-time, as of 2026-08-24. Local `main` and `origin/main` are fully synced (`2d3efdf86aa35a2282b9e26ec1b12066395aa9f8` at the time of reconciliation); local `main` is a fast-forward ancestor of `origin/main`, so **every future push is a plain `git push origin main` — no `--force`, no `--force-with-lease`, ever again**, unless a future, separately-approved history change requires it.

**Secrets:** the only credential embedded in `index.html` is the Supabase key, confirmed (via JWT decode) to be the `"role":"anon"` client-safe key — not a service-role secret. No `.env` file exists in the repository; `.gitignore` excludes `.env`/`.env.*` (with an `.env.example` carve-out) so one can never be committed by accident. Because `farber-parking` is a **public** repository, all of this client-side source — including that anon key — is publicly readable; production data security therefore depends entirely on correct Supabase Row Level Security policies, not on the code being hidden. RLS itself has not yet been separately audited.

## Folder Structure

```
FARBERMAKERS/
├── index.html                     # The entire application: markup, inline JS, tab logic
├── styles.css                     # All visual styling, CSS custom properties (design tokens)
├── utils.js                       # Shared date/string/formatting/XSS-escape helpers
├── CLAUDE.md                      # Mandatory dev workflow rules for this repo (backup, scope discipline)
├── PROJECT.md                     # This file — permanent knowledge base
├── MANUAL_OPERACIONAL.md / .pdf   # Full Portuguese-language operator training manual (as of 2026-06-22)
├── may-2026-operations-report.md  # Generated/reference output of the monthly Operations Report
├── migrations/                    # Supabase SQL migrations (schema changes, RLS policies)
│   ├── 20260712_create_daily_closing_reports.sql
│   ├── 20260712_add_customs_communication_fields.sql
│   └── 20260712_daily_closing_reports_rls.sql
├── _scripts/                      # One-off/reporting Node scripts
│   ├── may2026_report.mjs
│   └── may2026_console_report.js
├── logo.PNG, mockup.PNG           # Brand/design assets
└── BKP/                           # Mandatory backup folder (see CLAUDE.md) — timestamped snapshots before edits
```

There is no `src/`, no package manager manifest, and no test suite — the app is deployed as static files that call Supabase directly from the client.

## Database

Supabase/Postgres. Two known tables (schema for `passengers` is inferred from application code — no migration file defines its original creation, so it predates the tracked migrations).

### `passengers` (primary operational table)

**Purpose:** One row per vehicle check-in ("trip"). A returning passenger who checks in again gets a new row (this is how "frequent passenger" visit history and per-trip Customs communication flags stay scoped correctly).

**Important fields** (as referenced throughout `index.html`):
| Field | Purpose |
|---|---|
| `name` | Passenger full name (stored upper-case) |
| `phone` | Passenger phone (formatted `(XXX) XXX-XXXX` in UI) |
| `ticket` | Unique service ticket number. Format `MMDD-N` (Makers Air) or `A-MMDD-N` (Ascend, see [[ascend-valet]]) |
| `vehicle` / car model, `color` | Vehicle description |
| `location` | Hangar code: `HANGAR 19`, `HANGAR 18`, `HANGAR 16`, `HANGAR 7`, `HH` |
| `status` | `PENDING` \| `NO DATE` \| `DELIVERED` \| `ARCHIVED` |
| `return_date` (Return) | Expected return date; required when status is `PENDING` |
| `estimated_return_date` | Approximate date when status is `NO DATE`; drives the Tasks queue |
| `checkin_date` / `checkout_date` | Timestamps used by operational reporting |
| `deldate` | Delivery date, set on delivery |
| `delivery_type` | `NORMAL` \| `CUSTOMS` \| `LOCKBOX` |
| `customer_rating` | **Retired 2026-07-13.** `GREAT` \| `NORMAL` \| `DIFFICULT`. No longer written or displayed anywhere in the live app — kept purely to preserve historical data (see [[tip-status-replaces-rating]]). |
| `tip_received` | `true` \| `false` \| `null` (not recorded). Replaces `customer_rating` as of 2026-07-13; set at delivery time via the Tip Received? modal. Added by migration `20260713_add_tip_received_column.sql`. |
| `obs` | Free-text notes (upper-cased); system auto-appends tags like `EARLY RETURN`, `APPROX DATE` |
| `not_returning` | Boolean — passenger stated they won't return with Makers Air |
| `return_flight`, `departure_time` | Return flight number and departure time, used for Flight Tag printing/sorting |
| `archived_by`, `archived_at` | Set when a record is archived |
| `welcome_back_sent_at` | Hangar 19 "Welcome Back" SMS status (separate from Customs communication flags below) |
| `customs_welcome_sent`, `customs_welcome_sent_at` | Customs Welcome-Back SMS status (added by migration `20260712_add_customs_communication_fields.sql`) |
| `customs_gratuity_sent`, `customs_gratuity_sent_at`, `customs_gratuity_dismissed` | Customs gratuity-reminder workflow state (same migration) |

**Relationships:** No foreign keys — `passengers` is a flat, self-contained operational table. "Frequent passenger" detection is done by fuzzy-matching name/phone across existing rows in application code, not via a relational key.

### `daily_closing_reports`

**Purpose:** End-of-day cash/operational reconciliation, independent of passenger PII (explicitly documented in the migration as read-only against `passengers`, no customer data stored here).

**Important fields:**
| Field | Purpose |
|---|---|
| `report_date` | One row per calendar date (`unique`) |
| `first_ticket`, `last_ticket` | Auto-computed ticket range for the day |
| `total_cars`, `checked_in_today`, `delivered_today` | Auto-computed counts (recalculable, editable pre-finalization) |
| `cash`, `card`, `venmo`, `cash_app`, `zelle` | Payment totals by method (all `numeric(10,2)`, non-negative) |
| `attendants` (jsonb) | Array of `{name, time_in, time_out}` |
| `money_pickups` (jsonb) | Array of `{value, name}` — cash pickups during the shift |
| `money_left` | Cash left on-site |
| `delivered_verified`, `hangars_verified` | Manual checklist confirmations |
| `status` | `DRAFT` \| `FINALIZED` |
| `finalized_at`, `finalized_by`, `created_by` | Audit trail |

**Business-rule constraints enforced at the database level:**
- All monetary/count fields must be non-negative (`dcr_no_negative_totals`).
- A report can only move to `FINALIZED` if both `delivered_verified` and `hangars_verified` are true (`dcr_finalized_requires_checklist`).
- **A `FINALIZED` report can never be flipped back to `DRAFT`** — enforced by a database trigger (`dcr_block_unfinalize`), not just app logic, so this holds even from the Supabase SQL editor or another client.
- No delete policy exists — closing reports (draft or finalized) are never removed through the app.
- Row Level Security: any `authenticated` user can select/insert/update; no anonymous access; no delete for anyone.

**Relationships:** None (flat table, keyed by `report_date`).

---

## Business Rules

- **Ticket numbering:** Auto-suggested as `MMDD-N` for the current date (e.g., `0622-1`, `0622-2`); editable, and duplicates are warned about but not hard-blocked. See [[ascend-valet]] for the `A-MMDD-N` variant.
- **Delivery workflow:** Three delivery types — **Normal** (in-person), **Customs** (vehicle staged, never released before Customs clears the passenger), **Lockbox** (key deposited, passenger notified with access instructions). Delivering (any type) always requires answering the tip question (Yes/No) — see [[tip-status-replaces-rating]].
- **Tip status (replaces Passenger Rating, 2026-07-13):** At delivery, the attendant answers a simple Yes/No — "Did the passenger leave a tip?" — instead of the old Great/Normal/Difficult rating. Stored as `tip_received` (`true`/`false`/`null`). The old `customer_rating` field and its historical values are preserved but no longer written or shown anywhere. After a successful save: Customs deliveries keep their existing Welcome Back → Gratuity SMS sequence untouched (no duplicate ask); Normal and Lockbox deliveries open a new post-delivery SMS whose copy depends on the Yes/No answer (see SMS Templates below).
  - **Confirmed live in production (2026-07-13):** End-to-end tested against the live Supabase database with a disposable `ZZTEST DO NOT USE` record (created and deleted within the same session). Verified: Yes saves `tip_received = true` and opens the no-Stripe-link SMS; No saves `tip_received = false` (correctly distinct from `null`) and opens the SMS with the exact Stripe link; Cancel changes nothing; reopening the passenger shows the correct saved status; the app's own `undoDeliverToday` safely reset the test record between passes; zero console errors throughout.
  - **Customs exclusion rule, confirmed live:** Delivering the same test record via Customs recorded `tip_received` normally but fired **zero** tip-SMS calls — the existing Customs Welcome Back/Gratuity modal opened instead, exactly as designed. This is intentional: Customs already has its own gratuity ask, so the new tip SMS is scoped to Normal/Lockbox deliveries only.
  - **Not yet validated:** physical iPhone/iPad rendering and touch interaction for the tip modal, and real on-device SMS composer behavior (Messages app hand-off) — all live testing so far has been through a desktop browser preview against the real database, not a physical iOS device.
- **Customer status lifecycle:** `PENDING` → `DELIVERED`, or `PENDING`/`NO DATE` → `ARCHIVED`. `NO DATE` requires an `estimated_return_date` to generate a Tasks confirmation item. Return Date is mandatory only for `PENDING`.
- **Customs communication flow ("Welcome Back" → "Gratuity"):** Strictly sequential — the gratuity reminder is only eligible once `customs_welcome_sent` is true; it never fires before Welcome Back, and never re-fires once sent or explicitly dismissed. This is a separate flag set from the unrelated Hangar 19 "Welcome Back" feature — the two must not be conflated in code changes.
- **Ascend Valet ("ASCEND" sub-brand):** Detected purely by ticket prefix — any ticket matching `^A-` is treated as an Ascend record (`isAscend(r)`), which changes: brand name on tickets/SMS ("Ascend Valet" vs. "Makers Air Valet"), print header ("PRIVATE FLIGHT"), badge styling, and suppresses the Hangar 19 Welcome Back feature entirely (Ascend has its own Customs-based Welcome Back/Gratuity copy instead). ASCEND check-ins are flagged as normally not needing a customer copy print (confirmation prompt shown if attempted).
- **Lockbox:** Used only when the passenger cannot be present; requires confirming the Lockbox number/instructions before depositing the key.
- **"Not Returning with Makers Air":** A checkbox at check-in that prints a warning on the customer ticket and adjusts the Welcome SMS copy; purely informational, no workflow gating.
- **Archive:** Never a hard delete — moves records out of default filters/views. Requires a 3-step confirmation (count → archiver name → final confirm). A Debug-tab bulk action exists to archive all pending 2025 records.
- **Reminders:** "Forgot Yesterday" (Dashboard) surfaces any record whose return date was yesterday and is still not `DELIVERED` — must be checked first thing every shift. The Customs gratuity reminder (see above) is a second, independent reminder system with its own eligibility rules.
- **Reports:** See the dedicated Reports section below.
- **Early Return:** When a passenger returns before their scheduled date, a dedicated action sets return date to today, status to `DELIVERED`, appends `EARLY RETURN` to `obs`, and logs it — this history then triggers a "heads up" warning on the passenger's *next* check-in.

## SMS Templates

All SMS is **pre-filled but never auto-sent** — the system opens the device's native Messages app; the attendant must press Send manually.

| Template | Trigger | Copy (paraphrased/exact where short) |
|---|---|---|
| **Welcome SMS** | Check-in, "Save + Text" / "Save + Print + Text" | Confirms ticket number, states the return date on file, asks the passenger to reply if travel plans change. |
| **Welcome SMS (no return date)** | Same, but status `NO DATE` | Explains no return date is on file yet and asks for one once confirmed. |
| **Welcome SMS (not returning)** | Same, when "Not Returning" checkbox is set | Adds a note acknowledging the passenger said they won't return with Makers Air. |
| **Task confirmation SMS** | Tasks tab, generic | *"Hi! This is Makers Air Valet. We are reaching out to confirm your return date so we can update our records. Please let us know when you plan to return. Thank you!"* |
| **Confirmation SMS (approximate-date panel)** | Passenger panel, when record has an approx date | *"Hi [Name], this is Makers Air Valet. We have your [Vehicle] parked with us. Can you confirm your return date? Thank you!"* |
| **Hangar 19 Welcome Back** | Manual send, Makers Air only (never for Ascend) | Tells the passenger to stay with their pilots after clearing Customs and return to Makers Air at Hangar 19 — do **not** exit through the Customs terminal (no transport from there). |
| **Customs Welcome Back** (Makers Air) | Customs communication panel | Vehicle ready at Customs; key is on the driver-side tire. |
| **Customs Welcome Back** (Ascend) | Same panel, Ascend ticket | Vehicle ready at Customs; an Ascend team member personally hands over the key. |
| **Customs Gratuity** | Sent only after Welcome Back, once, if not dismissed | Thanks the passenger, includes the discretionary gratuity Stripe link. Brand name in the copy switches for Ascend vs. Makers Air. |
| **Tip SMS — Yes** (added 2026-07-13, confirmed live) | Normal/Lockbox delivery only, tip answered "Yes" | Thanks the passenger for their business and generosity; **no Stripe link**. Brand name switches to "Ascend Valet" for Ascend tickets. Never sent for Customs deliveries (Customs keeps its own Gratuity SMS instead — no duplicate ask). Confirmed against production: exact copy, no `stripe.com` in the message. |
| **Tip SMS — No** (added 2026-07-13, confirmed live) | Normal/Lockbox delivery only, tip answered "No" | Politely offers the same discretionary gratuity Stripe link used by the Customs flow. Brand name switches to "Ascend Valet" for Ascend tickets. Never sent for Customs deliveries. Confirmed against production: exact copy, exact link `https://buy.stripe.com/8x214mccK0uh9TjgIM6Vq00` unmodified. |

## Dashboard

Cards grouped by urgency, in this order:

| Section | Purpose | Notes |
|---|---|---|
| **Arrived Today** | Informational — everyone checked in today | Flags `🔴 NO HANGAR` per card and a header count if any vehicle has no location set; sorted by ticket number ascending. A same-day delivered card shows a compact tip chip (💵✓ / 💵✕ / 💵?) next to the name — full "Tip: Yes/No/Not recorded" text is detail-panel only, added 2026-07-13. |
| **Leaving Today** | Return date = today, not yet delivered | Highest priority; inline flight number/departure time fields; per-card Deliver/Customs/Lockbox buttons; per-card and bulk Flight Tag printing (printed in departure-time order) |
| **Leaving Tomorrow** | Return date = tomorrow | Same functionality as Leaving Today, used for next-day prep |
| **Returning Sunday** | Return date falls on the upcoming Sunday | Weekend planning |
| **Forgot Yesterday** | Return date was yesterday, still not delivered | Only rendered when non-empty; top priority to resolve each shift |
| **Busy Days warning** | Banner when the current week has an unusually high Sunday/return volume | Added after early global rollout of a Sunday-only version (see Changelog) |

Colors follow status semantics: amber/orange = pending/urgent-today, purple = tomorrow/no-date, red = overdue/critical, green = delivered, gray = archived. Buttons per card: `✓ Deliver`, `Customs`, `🔒 Lockbox`, and a print icon for the individual Flight Tag. Clicking a card opens the full passenger panel.

## TV Mode

**Purpose:** a dedicated, read-only operations board for an HDMI-connected TV that stays on ~24 hours/day at the FBO front desk, giving attendants an at-a-glance view of today's activity without needing an attendant logged into the normal app on that screen.

**Access:** `?mode=tv` (or `#tv`) on the app URL, opened via the "📺 Open TV Mode" button in the header or a direct bookmark. Requires a normal Supabase sign-in on that device (same auth as the rest of the app) — TV Mode is a display mode of the authenticated app, not a separate public page. **Strictly read-only:** the TV Mode code path (`isTvMode()`/`initTvMode()` and everything under it in `index.html`) never calls create/update/delete/delivery/print/SMS logic — it only reads `data` (via the same `sbGet()`/`mapPassengerRow()` the rest of the app uses) and renders it.

**Pages & rotation:** three pages, auto-rotating (15s on Today, 12s on Tomorrow and Operations), with manual Pause/Next controls and page-position dots. Today is shown first and dwells longest, since same-shift activity is the most time-sensitive thing on the board:
1. **Today** — two columns, **Leaving Today** and **Checked In Today** side by side (name, vehicle+color, hangar/location, ticket, and either departure or check-in time; a ✓ DELIVERED chip on same-day-delivered Checked-In-Today rows; a red NO LOCATION indicator on any row missing a hangar; a Hangar 19 Welcome Back reminder chip on eligible Leaving Today rows — see below).
2. **Tomorrow** — the existing **Leaving Tomorrow** prep view, unchanged: time-bucketed (Early Morning → After Hours), departure time, passenger, vehicle+color, hangar, ticket, flight number, and only badges that are actually knowable before delivery (✈ ASCEND from the ticket-prefix rule, NOT RETURNING from the check-in-time checkbox) — never CUSTOMS/LOCKBOX, since `delivery_type` isn't set until the vehicle is actually delivered.
3. **Operations** — three columns: **Special Handling & Alerts** (missing departure time tomorrow, missing location — independent alert types only), **Customs / Ascend** (see below), and **Active Vehicles by Location** (hangar occupancy totals for active, non-delivered vehicles).

A compact KPI row sits above the pages on every page: Checked In Today, Leaving Today, Leaving Tomorrow, Missing Locations, Customs / Special (gratuity-reminder-due count), and Total In Custody (all active, non-delivered records — not date-scoped).

**"Checked In Today" definition:** the passenger's actual check-in timestamp, not Return Date. Primary source is `checkin_date` (an ISO timestamp written at insert time); for older records that predate that column, TV Mode uses the same `checkin_date || ts` fallback already resolved by `mapPassengerRow()` and used elsewhere (Dashboard's Arrived Today, the Operations Report). ISO values are parsed with `new Date()` and compared against the local calendar day (`sd()`/`getToday()` from `utils.js`) rather than by string-splitting, so a check-in near a local-day boundary lands on the correct day regardless of the server's UTC offset. Non-ISO legacy strings fall back to the existing `isArrToday()` parser. Sorted newest check-in first. This replaced an earlier version of TV Mode that used the legacy `ts` field only — `ts` and `checkin_date` are written at the same instant for every record since `checkin_date` was introduced, so the two only ever differed for pre-`checkin_date` legacy rows, which the fallback already covers.

**Hangar 19 Welcome Back reminder (2026-08-24):** a read-only visual reminder on Leaving Today rows for when to send the existing Hangar 19 Welcome Back SMS — TV Mode never sends it. Reuses the Dashboard's own eligibility and ETA logic exactly (`getWelcomeBackEta()`, `isValidDepTime()`, `isAscend()`, `r.delivery_type`, `r.welcome_back_sent_at` — no second interpretation of departure time): excluded entirely for Ascend (separate Customs-based workflow) and Customs deliveries, and never guessed when departure time is missing/invalid. States, driven by the shared `WELCOME_BACK_REMINDER_MINUTES` constant:
- More than the threshold before departure — no badge.
- Within the threshold through departure time, not yet sent — amber **SEND WELCOME BACK**.
- Past departure time, still not sent — red **⚠ WELCOME BACK OVERDUE** (the row's left border also turns red; this is the only red state).
- `welcome_back_sent_at` set — quiet green **✓ WELCOME BACK SENT**, regardless of timing.

No animation on any state (TV Mode's existing no-flashing rule). Recomputed once a minute by extending the existing 1-second clock tick (`updateTvClock()`) to also call `renderTvDashboard()` whenever the seconds roll to `:00` — no second timer was added, and no network call is made (re-renders against already-loaded `data`).

**`WELCOME_BACK_REMINDER_MINUTES` (shared constant, = 30):** defined once, immediately above `getWelcomeBackEta()`. Both Dashboard call sites (`welcomeBackButtonHtml()`'s initial-render urgency check, and `refreshWelcomeBackUrgency()`'s 60-second live DOM-class toggle) and TV Mode's reminder all read this single constant — changed from a hardcoded 20 minutes (duplicated in two places) to 30 minutes on 2026-08-24, specifically so Dashboard and TV Mode can never show contradictory timing again.

**Customs / Ascend panel:** tracks two things using only existing helpers — no new business rules. Scoped to **today and tomorrow only**, by the passenger's **return date** (`isToday(r.ret)`/`isTmrw(r.ret)`) — the same field and helpers that already drive Leaving Today/Tomorrow everywhere else in the app, not the delivery timestamp. Each row carries a small TODAY/TOMORROW tag; TODAY rows sort before TOMORROW rows within each group.
- **NEEDS HANDLING** — active, not-yet-delivered records where `isAscend(r)` is true, whose return date is today or tomorrow.
- **AT CUSTOMS** — any record where `isCustomsDelivered(r)` is true (`status==='DELIVERED' && delivery_type==='CUSTOMS'`), whose return date is today or tomorrow — **not** filtered by `isAscend()`, so a regular Makers Air vehicle delivered via Customs appears here too, with just the ✓ AT CUSTOMS chip (no ✈ ASCEND chip). Shown with a muted row background and a subtle strike-through on the name only (vehicle/ticket/hangar stay fully readable), and an amber GRATUITY DUE chip when the existing `getCustomsDueRecords()`/`isCustomsGratuityReminderDue()` logic says the Customs gratuity SMS reminder is due. A record can only ever be in one of the two groups (not-yet-delivered vs. delivered-via-Customs are mutually exclusive on `status`), so nothing is ever shown twice — and the general Special Handling & Alerts column intentionally does **not** duplicate the gratuity-due signal, since every gratuity-due record is by definition already an AT CUSTOMS record. A Customs delivery whose return date has fallen outside the today/tomorrow window (e.g. delivered yesterday) simply stops appearing here — the underlying Supabase record is untouched, this is TV-display filtering only.

**Reliability:** Supabase realtime subscription (best-effort, debounced 800ms) layered over a 60s reconciliation poll that alone guarantees the board is never more than ~60s stale; a 15s watchdog that forces an extra reconciliation past 90s without a successful update and shows a STALE DATA banner past 180s; exponential-backoff realtime reconnect; local-clock-only date-rollover detection (no server round-trip) that re-renders Today/Tomorrow groupings and forces a reconciliation at midnight; a session-expired overlay if the Supabase token is rejected (401/JWT error); fullscreen support; cursor auto-hide and an auto-hiding corner control panel (Full Screen, Refresh Now, Pause/Resume Rotation, Next Page, Copy TV URL, Exit TV Mode); and full teardown (`destroyTvMode()`) of every interval/listener/realtime channel on exit or `beforeunload`, so nothing leaks if the tab is reused.

**Visual design (2026-08-24 redesign):** light, low-fatigue 24/7 operations-board theme — soft blue-gray page background (`#E8EEF7`, never pure white), a medium Makers Air navy-to-blue header band, white/near-white cards, dark navy text, and restrained semantic color (blue = operational, green = healthy/completed, amber = needs attention, red = critical only). Replaced the original near-black theme and removed the decorative background drift animation and the always-on card glow pulse on every Leaving Tomorrow card — animation is now limited to the functional reconnecting-dot pulse and a brief page-rotation fade, both cheap and meaningful rather than decorative. See Development Decisions below for why AT CUSTOMS is day-scoped and why the original "Arriving Today" KPI was folded into "Checked In Today."

## Offline Mode

**Status: Phase 1 (infrastructure only) — implemented 2026-08-24. Offline Check-In does not exist yet.** Normal, online New Entry (`saveEntry()`) is completely unmodified and is still the only way a check-in reaches Supabase. Nothing in this phase reads from or writes to IndexedDB from any production workflow — the infrastructure below exists only so a later phase can build real offline check-in on top of it, and is exercised today only through the Debug tab's diagnostics panel with synthetic test records.

**Full design:** a 22-point audit and architecture report, followed by a focused follow-up on ticket format/device identity/auth window, preceded implementation — see this repository's development history for the complete reasoning (ticket collision analysis, idempotency strategy, sync state machine, RLS/RPC considerations, iPad/Safari-specific risk analysis, etc.). Summarized here is only what Phase 1 actually built.

**Files added:** `service-worker.js`, `offline-db.js`, `offline-auth.js`, `vendor/supabase.js`. **Modified:** `index.html` only (script tags, header connectivity indicator, update banner, Debug-tab diagnostics panel, `onAuthStateChange` hook). `styles.css` required no changes — the diagnostics panel reuses the existing `.epson-card`/`.epson-stat-grid`/`.epson-btn` component classes already established for the Printer Diagnostics section.

**Service worker & app shell:** `service-worker.js`, registered with relative scope (`./service-worker.js`) so it works correctly under GitHub Pages' `/farber-parking/` path without hardcoding it. Precaches exactly 8 files into a versioned cache (`airvalet-shell-v1`): `./`, `./index.html`, `./styles.css`, `./utils.js`, `./logo.PNG`, `./vendor/supabase.js`, `./offline-auth.js`, `./offline-db.js` — via `cache.addAll()`, which is atomic: any single failed/non-2xx request fails the entire install, so a service worker can never claim offline-readiness with a partially-cached shell. The fetch handler is an explicit allow-list — only requests matching one of those 8 files are ever served from cache; everything else (Supabase REST/Auth/RPC, any other origin) passes straight through untouched, always network-only. `activate()` deletes any `airvalet-shell-*` cache that isn't the current version. New workers never auto-activate or force a reload mid-session — they sit in `waiting` until the attendant taps "Reload Now" on the Update Available banner, which posts `{type:'SKIP_WAITING'}` to the waiting worker; a single `controllerchange`-triggered reload follows (not a loop). To bump the shell version on a future deploy, change `CACHE_VERSION` in `service-worker.js`.

**Vendored Supabase JS:** was `cdn.jsdelivr.net/npm/@supabase/supabase-js@2` — a **floating major-version tag**, not a true pin (jsdelivr resolves `@2` to whatever the latest 2.x release is at request time). Resolved and frozen at exactly **2.112.4** on 2026-08-24, fetched from `https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.112.4/dist/umd/supabase.js` and committed unmodified as `vendor/supabase.js` (SHA-256 `f8ce7fab799af1916019cbd0b485b39bb80dbdbc6dc062909a751c9e5198e04c`). This removes the CDN as a hard dependency for the app to even load, and means the library version can no longer drift silently — a future upgrade must be a deliberate, visible change to this file.

**Connectivity detection:** a header indicator (🟢 ONLINE / 🟡 NETWORK — NO SERVER / 🔴 OFFLINE) driven by two independent signals that are never conflated: `navigator.onLine` (device network interface only) and a real, rate-limited reachability probe (`offlineProbeSupabase()`, a lightweight `GET .../rest/v1/passengers?select=id&limit=1`, minimum 15s between checks, triggered on `online` events and on the tab becoming visible again — never polled aggressively). `navigator.onLine===true` is never treated as proof Supabase is reachable.

**Device identity:** `getOfflineDeviceId()` — a `crypto.randomUUID()` generated once and stored in `localStorage`, stable across reloads and across changing the device code, never shown to attendants. `getOfflineDeviceCode()`/`setOfflineDeviceCode()` — a short, human-facing code (e.g. `M1`), **manually assigned only, never auto-generated** (two iPads must never silently receive the same code). Validated to 1-4 uppercase letters/digits starting with a letter, and explicitly rejects `A` or anything starting with `A-`, to stay unambiguous with the Ascend ticket rule. **Not yet enforced unique across devices** — Phase 1 has no server-side registry; a `devices` table with a `UNIQUE(device_code)` constraint is required before Offline Check-In can be safely enabled (Phase 3, alongside the sync migration below).

**Offline authorization window:** `OFFLINE_AUTH_WINDOW_HOURS = 24`, a single named constant. On every `SIGNED_IN`/`TOKEN_REFRESHED` event, `recordOfflineAuthSuccess(email)` writes `{deviceId, userEmail, lastAuthenticatedAt, expiresAt}` to `localStorage` — timestamp/email/device id only, **never** a password, JWT, or refresh/access token. `SIGNED_OUT` deliberately does not touch this marker — it neither refreshes nor clears it; it only ever expires on its own schedule. This marker is **not** a Supabase session and does not prove Supabase would authenticate the user right now — while offline, that can't be verified at all. It means exactly: *this operational iPad successfully authenticated online within the last 24 hours.* Once Offline Check-In exists (Phase 2+), a valid window permits it; an expired or missing window shows "OFFLINE ACCESS NOT AVAILABLE — connect to the internet and sign in," and already-queued records are never deleted because this window expired.

**IndexedDB (`airvalet_offline`, version 1):** one object store, `offline_checkins` (keyPath `offline_sync_id`), indexed on `syncState` and `createdAt`. Fields: `offline_sync_id`, `payload`, `createdAt`, `syncState`, `serverPassengerId`, `attemptCount`, `lastAttemptAt`, `lastError`, `deviceId` — deliberately minimal; printing/SMS-status fields are intentionally deferred to whichever phase actually implements those behaviors, not reserved speculatively now. In Phase 1 this store contains only synthetic diagnostics records created via the Debug tab's "Write Test IndexedDB Record" button — never real passenger data.

**Debug tab — Offline Mode Diagnostics panel:** Service Worker / Shell Cache version / IndexedDB / Device Network / Supabase reachability / Update Available / Device ID / Device Code (with manual assignment) / Last Online Auth / Offline Auth Valid Until / Offline Auth state, plus a live view of any test IndexedDB records. Explicitly labeled "infrastructure only" and states check-in is not available yet — this panel must never be mistaken for a production feature announcement.

**Known required follow-up before Phase 2 (documented here so it can't be forgotten):**
- **Ticket format for offline check-ins is approved as `MMDD-N-<DeviceCode>`** (e.g. `0824-6-M1`; Ascend: `A-0824-6-M1`) — the device code as a *suffix* was chosen specifically because `getNextTicket()`/`getSharedDailyMax()` ([index.html](index.html), "TICKET AUTO-SUGGEST") parse via `parseInt()` on the text after the date prefix, which naturally stops at the first non-digit character — so a trailing code parses correctly with **no changes needed** to those functions, while a *leading* code (like `0824-M1-6`) would silently break them for every device once synced. `isAscend()`'s `/^A-/` check is unaffected either way since a suffix never touches the start of the string.
- **`dcParseTicketSeq()`** (Daily Closing, "Ticket parsing — MMDD-N and A-MMDD-N") uses a strict regex, `/^(A-)?(\d{2})(\d{2})-(\d+)$/`, that does **not** match the offline suffix format at all — any offline-formatted ticket is silently excluded from Daily Closing's First/Last Ticket computation until this regex is extended (e.g. an added optional trailing group) to recognize it.
- **`renderDay()`'s Arrived Today sort** strips all non-digit characters before comparing (`ticket.replace(/\D/g,'')`) — a device code containing a digit can tie with an unrelated ticket's stripped value, producing an imprecise (not incorrect-*data*, just imprecise-*order*) sort. Recommended fix: replace the blind digit-stripping with the same sequence parser used above.
- **Recommendation:** extract one shared `parseTicketSequence()` helper used by both the Daily Closing parser and the Arrived Today sort, rather than maintaining two separate implementations of "what counts as a ticket's sequence number."
- None of the above is broken today — Phase 1 creates no real offline-formatted tickets. This is scoped, required work for whichever phase starts generating them for real.
- A Supabase migration (`offline_sync_id uuid` column + partial unique index + a `SECURITY DEFINER` `sync_offline_checkin()` RPC, following the exact pattern already established by `change_passenger_return_date_with_reason()`) is required before real sync can exist, and an RLS/RPC security audit must precede writing that migration — neither has been done yet; both are explicitly Phase 3 scope, not created here.

## Reports

Generated from the **Report** tab, three independent tools:

1. **Passenger Report (PDF)** — filter by date + type (`All Pending`, `Tomorrow`, `No Date`, `Today`, `Overdue`); preview table; print/save PDF or open in a new tab.
2. **Monthly Operations Report** — select month/year + delivery filter (`All`/`Normal`/`Customs`/`Lockbox`); outputs total check-ins/deliveries, busiest weekday, most-active hangar, per-weekday volume averages, top 10 busiest days, and a hangar-utilization-by-weekday matrix (staffing planning tool). See [may-2026-operations-report.md](may-2026-operations-report.md) for a real generated example, and `_scripts/may2026_report.mjs` / `_scripts/may2026_console_report.js` for the scripted/console equivalent.
3. **Contacts Export (.vcf)** — export all unique contacts, or only new ones since the last export; de-duplicated (most recent visit wins); import via iOS Files/Contacts. Standards-compliance pass (2026-07-13, see [[vcf-standards-compliance]]): vCard 3.0 with CRLF line endings, `N:`+`FN:` fields, title-cased names (stored names are all-caps), `+1`-normalized US phones with international-number preservation, and filenames `makers-air-contacts-YYYY-MM-DD.vcf` / `makers-air-new-contacts-YYYY-MM-DD.vcf`. Function-level correctness (CRLF, escaping, title-casing, phone normalization, multi-card structure) was verified directly against the live app's own functions.
   - **Known, unresolved limitation:** "Export New Contacts" tracking is still `localStorage`-based — device/browser-specific, lost if Safari site data is cleared, and not synchronized across iPhone, iPad, and desktop. This was true before the 2026-07-13 fixes and remains true after them; a database-backed version would be a larger architectural change and has not been approved.
   - **Not yet validated:** physical iPhone/iPad import of a generated `.vcf` file (opening it in Files/Safari and confirming Contacts picks it up correctly) has not been performed — only the file's internal structure and browser-side generation have been verified.

There is also the separate **Daily Closing Report** (its own tab, not under Report) — see Database section above for its full field set; it supports Draft save, recalculation of auto-fields, and one-way Finalize (irreversible).

## UI Standards

**Design tokens** (CSS custom properties, [styles.css:2-19](styles.css)):
```css
--navy:#1B3B6F   --navy2:#162E58   --blue:#2A5DB0
--gold:#C9AC54   --gold2:#A8893A
--ok:#1A9E6A     --red:#CC3333     --pur:#5B7FBD
--bg:#F0F3FA     --s:#FFFFFF       --s2:#E8EDF7   --b:#C8D3E8
--tx:#0D1B2E     --mu:#5A6E8C
--acc:#C9AC54    --acc2:#1B3B6F
```
- **Typography:** `DM Sans` for body text, `Syne` for display/numeric emphasis (headers, chip counts), `DM Mono` for tags/badges/monospace data.
- **Buttons/chips:** `border-radius: 10px` (buttons), `12px` (cards), `20px`/`999px` (pill chips/badges).
- **Badges/tags:** small (`9px` font), `border-radius: 4px`, `DM Mono`, used for `TODAY`/`TMR`/`LATE`/`~APPROX`/`✈ ASCEND` labels.
- **Responsive:** optimized primarily for iPad (zoom disabled, installable as a home-screen web app); scales up on desktop to show more simultaneous information; header layout has explicit iPhone/iPad/desktop fixes (see Changelog).
- **Icons:** Font Awesome for the 8 main tab icons; emoji used pervasively for section/status markers elsewhere (kept intentionally — this is a deliberate, established style, not an inconsistency to "fix").
- **Modals:** used for archive confirmation (3-step), print confirmations, Customs Gratuity detailed queue (Previous/Next), and passenger panel dialogs.

## Components

The app is not componentized in a framework sense (no React/Vue) — it is organized as reusable **render functions** and **card builders** in `index.html`, notably:
- Passenger row/card rendering (table row, dashboard card, Flight List result card — share formatting helpers like `escapeHTML`, `fmtD`, `fmtP`, `fmtA`, `tipStatusHtml`/`tipStatusCompact`)
- Print builders: Customer Copy, Key Copy, Dashboard Copy, Flight Tag (ESC/POS-style markup strings sent to the Epson printer)
- SMS builders: Welcome, Task-confirmation, Hangar 19 Welcome Back, Customs Welcome Back, Customs Gratuity (`buildCustomsGratuitySms`, etc.)
- Daily Closing form module (`dc*` prefixed functions): dynamic attendant rows, dynamic money-pickup rows, currency/int sanitizers, dirty-state tracking with `beforeunload` guard
- Shared helpers in [utils.js](utils.js): `escapeHTML`, date parsing (`pd`, `sd`, `isToday`, `isTmrw`, `isLate`, `isSunday`), formatters (`fmtD`, `fmtP`, `fmtA`, `d2us`, `tsToDateInput`), `fuzzyMatch` for frequent-passenger detection

## User Workflow

**Check-in → custody → delivery/archive**, end to end:

1. **Check-in:** `+ New Entry` → fill Name (autocomplete against history), Phone, auto-suggested Ticket, Return Date (or `NO DATE` + estimate), Vehicle, Color, Hangar. System surfaces frequent-passenger history and Early Return warnings inline.
2. **Save + Print + Text** (recommended): persists the record, prints Customer/Key/Dashboard copies, opens the Welcome SMS.
3. Attendant hands Customer Copy to passenger, clips Key Copy to keys, places Dashboard Copy in the vehicle, parks in the selected hangar.
4. **In custody:** location changes go through "Move Hangar" (single or bulk), which prompts to reprint the Key Copy — the old tag must be physically swapped, never left doubled-up.
5. **Approaching return:** Dashboard surfaces the record under Leaving Today/Tomorrow/Sunday; flight info can be attached for Flight Tag printing; Tasks tab handles unresolved date confirmations.
6. **Delivery (check-out):** locate by name/ticket → confirm identity against the physical ticket → retrieve vehicle → mark delivered → choose delivery type (Normal/Customs/Lockbox) → rate the passenger. For Customs, the Welcome Back → Gratuity SMS sequence follows.
7. **Early Return** short-circuits steps 5–6 if the passenger arrives before their scheduled date.
8. **Archive:** at period end or supervisor request, selected `DELIVERED`/stale records are archived (3-step confirm), removing them from default views but retaining full history.
9. **Daily Closing:** end of shift, reconcile cash/card/digital totals, log attendants and money pickups, check both verification boxes, and Finalize (irreversible) — or leave as Draft to revisit.

## Known Issues

No formal bug tracker exists in-repo. Recorded here from the operational manual's "Most Common Errors" section (business-process risks, not code defects) plus anything discovered during development:

| Description | Status | Possible solution |
|---|---|---|
| SMS is only pre-filled, never actually sent by the system — attendants sometimes navigate away without pressing Send | Known limitation, mitigated by training | Manual's suggested improvement: automatic SMS sending (see Future Improvements) |
| Vehicles can be saved with no hangar (`NO HANGAR`), risking a lost vehicle if not caught | Mitigated via Dashboard alert (`🔴 NO HANGAR`) | Could make hangar selection a hard requirement at save time |
| Duplicate ticket numbers are only warned about, not blocked | By design (some duplicates are legitimate/edge cases) | Revisit if duplicate collisions cause real incidents |
| No per-attendant login/identity — Logs record actions but not which specific staff member performed them | Open, noted in manual's future improvements | "Múltiplos usuários com identificação" — per-user login |
| `index.html`/`styles.css` have uncommitted local changes not yet captured in git history (Ascend, Customs comms, Daily Closing UI) | Working-tree only as of this writing | Commit once verified stable, per [[feedback-farbermakers-change-discipline]] |
| Physical iPhone/iPad validation is still pending for both the tip workflow (modal layout/touch targets, real SMS composer hand-off) and the VCF contact-export fixes (actually importing a generated `.vcf` on-device) | Open — 2026-07-13 pass validated function-level correctness and live production behavior via desktop browser only | Perform an on-device pass on a real iPhone/iPad before considering either feature fully verified |
| "Export New Contacts" tracking is `localStorage`-only — device/browser-specific, lost on Safari data clear, not synced across devices | Known limitation, unchanged by the 2026-07-13 VCF fixes | Would require a database-backed tracking column/table — a larger change requiring separate approval |
| TV Mode's "Leaving Today" overdue flag (`isLate(r.ret)` applied to records already filtered to `isToday(r.ret)`) can never actually be true — `isLate()` only returns true for a date strictly before today, so this condition is permanently dead code. Found 2026-08-24 during the TV Mode redesign audit. | Open, not fixed — pre-existing, outside the approved scope of the TV Mode redesign | Either remove the dead check, or replace it with a real "was expected earlier today" concept if one is wanted — needs a scoping decision before touching it |

## Future Improvements

From the operational manual's roadmap (Section 30) plus in-repo signals:

1. Automatic SMS sending (no manual "press Send" step)
2. Digital signature capture on delivery
3. Photo capture of vehicle condition at check-in/check-out
4. QR code on tickets for fast record lookup
5. Automatic flight-data lookup from tail number
6. Automated in-system alerts before a passenger becomes late
7. Visual hangar map showing occupied/available spots
8. Per-attendant login/identity for better log traceability
9. Tip-rate analytics report over time (successor to the retired Passenger Rating concept — now tracked via `tip_received`)
10. Formalize the currently-uncommitted Ascend Valet / Customs communication / Daily Closing feature set into tracked commits with tests where practical
11. **Daily Control report (planned, not yet implemented)** — an internal end-of-day operational report for Farber Parking management, distinct from the Leaving Tomorrow PNG export and from the Daily Closing Report (which is a cash/attendant reconciliation tool). Daily Control is **statistics-only** and must **never include customer PII** (no names, phone numbers, or vehicle details). Planned contents:
    - Report date
    - First ticket issued that day
    - Last ticket issued that day
    - Total vehicles checked in
    - Total vehicles delivered
    - Total vehicles still pending
    - First check-in time
    - Last check-in time
    - First delivery time
    - Last delivery time
    - Vehicles archived
    - Customs deliveries
    - Lockbox deliveries
    - Ascend deliveries
    - Optional operational notes

    Planned export: PNG (required), PDF (optional), for internal management records only. **Move this entry out of Future Improvements and into the Reports section once implemented**, and add a corresponding entry to `DECISIONS.md` documenting the implementation approach.

## Development Decisions

Document new entries here as **Date / Reason / Decision / Impact** whenever an architectural choice is made. Seeded from what's inferable in the current codebase:

- **Date:** 2026-07-12 (approx., per migration filenames)
  **Reason:** Need to track Customs Welcome-Back/Gratuity SMS state per trip without introducing PII into a new table.
  **Decision:** Added five nullable/defaulted boolean+timestamp columns directly onto `passengers` rather than a new join table, since each check-in is already its own row and the flags are trip-scoped by nature.
  **Impact:** Simpler queries, no joins; but any future multi-trip aggregation of Customs comms would need to scan across rows by phone/name rather than a foreign key.

- **Date:** 2026-07-12 (approx.)
  **Reason:** Daily cash/attendant reconciliation needed a system of record separate from passenger data, with a hard guarantee that finalized closings can't be silently altered.
  **Decision:** New `daily_closing_reports` table, one row per date, with a DB-level trigger blocking `FINALIZED → DRAFT` transitions (not just an app-level check) and no delete policy at all.
  **Impact:** Finalized daily closings are tamper-resistant even against direct SQL access; drafts remain fully editable until finalized.

- **Date:** unknown (pre-dates tracked migrations)
  **Reason:** Distinguish the private-flight "Ascend Valet" service from standard Makers Air check-ins without a schema change.
  **Decision:** Overload the existing `ticket` field — any ticket prefixed `A-` is treated as Ascend everywhere in the UI (`isAscend()`), rather than adding a `brand`/`service_type` column.
  **Impact:** Zero migration cost, but brand identity is now implicitly encoded in a string pattern; renaming the ticket format would silently break brand detection.

- **Date:** 2026-08-04
  **Reason:** Evaluate migrating the 24 `sms:`-link SMS flows to Twilio Programmable Messaging, without touching production behavior in this first step. Full audit requested and delivered first (see [[twilio-migration-audit]] — `docs/TWILIO_MIGRATION_AUDIT.md`), covering every send point, the Customs Welcome-Back → Gratuity ordering risk, the Ascend/Makers-Air branding rules, and a proposed Supabase Edge Function + `sms_messages`/`sms_conversations` schema for a future phase.
  **Decision:** Only Fase 1 (SMS provider abstraction) and Fase 2 (`mock_twilio` local simulation mode) were approved and implemented. A single entry point, `sendPassengerSms()`, now sits in front of every SMS send; `SMS_PROVIDER` (`'native' | 'mock_twilio' | 'twilio'`) controls transport and defaults to `'native'`, which is behaviorally byte-identical to the pre-existing `window.open('sms:...)` flow (verified by an automated headless test harness that loads the real code with `fetch`/`window.open` intercepted — see `docs/TWILIO_MIGRATION_PHASE1-2_IMPLEMENTATION.md`). Two previously inline SMS templates (the approximate-date "Send Confirmation Text" link and the Tasks-tab confirmation text) were extracted into named builder functions (`buildReturnDateConfirmationSms`, `buildTaskConfirmationSms`) with byte-identical output, since they were the only two templates not already following the `build*Sms()` pattern. No Twilio account, Edge Function, migration, or secret exists anywhere in the codebase — the `'twilio'` branch is a placeholder that throws `Error('Real Twilio provider is not configured.')`.
  **Impact:** Every future SMS-related change (real Twilio integration, bulk send, inbox) now has one call site to modify (`sendPassengerSms`) instead of the 8 scattered `window.open('sms:...)` call sites that existed before. A pre-existing gap was found and corrected in the audit during testing: the Customs "Send Gratuity" button was never actually blocked client-side before Welcome Back is sent (only its subtitle text changed) — this was not introduced by this change and was **not** fixed here (out of approved scope), but is now accurately documented as risk R1 for the still-unapproved Fase 4 (server-side revalidation via Edge Function).

- **Date:** 2026-08-24
  **Reason:** TV Mode's original dark theme was too heavy for a display meant to stay on ~24h/day, its "Arriving/Checked In Today" section used the legacy `ts` field instead of `checkin_date` and was ambiguously named, and there was no way to see Ascend or Customs-in-progress vehicles at a glance. Full audit, a standalone HTML mockup, and two review rounds preceded implementation (see the mockup review in this session's transcript for the rejected/accepted alternatives).
  **Decision:** Redesigned to a light, low-fatigue theme (see TV Mode section above); fixed Checked In Today to read `checkin_date` (with the existing `checkin_date || ts` fallback) via new `tvIsCheckedInToday()`/`tvCheckinTimestamp()` helpers that parse ISO timestamps against the local calendar day rather than string-splitting; reordered pages so Today loads first with the longest dwell; added a Customs / Ascend panel built entirely on existing helpers (`isAscend()`, `isCustomsDelivered()`, `getCustomsDueRecords()`), initially scoped to `isToday(r.deldate)` for AT CUSTOMS and not date-scoped at all for NEEDS HANDLING — both **superseded 2026-08-24 same day**, see the entry below for the corrected today/tomorrow-by-return-date scoping. Removed the decorative background-drift animation and the always-on card glow pulse (every Leaving Tomorrow card had one) — animation is now limited to the functional reconnecting-dot pulse and a brief page-fade on rotation.
  **Impact:** No schema change, no changes to delivery/payment/SMS/printing/Daily Closing logic — TV Mode's script/markup/CSS were the only files touched, plus this doc. Verified via a standalone test harness (not committed) that loads the real extracted TV Mode code — same `buildTvViewModel()`/render functions, same CSS — against synthetic data covering zero/normal/high-volume record counts, since TV Mode requires a live Supabase session and no test credentials were available in this environment; realtime-channel-specific behavior (actual Supabase Realtime events, not the reconciliation-poll fallback) was reasoned about from the unchanged subscription code but not separately exercised. See Known Issues for a pre-existing, unrelated dead-code condition found (not fixed) during the audit.

- **Date:** 2026-08-24 (same day, follow-up)
  **Reason:** Two small TV Mode gaps found in review: (1) the Dashboard's Hangar 19 Welcome Back reminder had no TV Mode equivalent, and its 20-minute urgency threshold was hardcoded in two separate places in `index.html`, risking future drift; (2) the Customs/Ascend panel's AT CUSTOMS group was scoped by delivery timestamp (`isToday(r.deldate)`) rather than the return-date field the rest of the app uses for "Today/Tomorrow," and NEEDS HANDLING had no date scope at all, so it could show Ascend records from any day.
  **Decision:** Introduced one shared `WELCOME_BACK_REMINDER_MINUTES = 30` constant (defined immediately above `getWelcomeBackEta()`) and pointed both existing Dashboard call sites (`welcomeBackButtonHtml()`, `refreshWelcomeBackUrgency()`) and a new TV Mode helper (`tvWelcomeBackState()`) at it — the Dashboard threshold changed from 20 to 30 minutes as part of this, by explicit request, specifically so Dashboard and TV Mode can never show contradictory timing. TV Mode's Leaving Today rows now show a read-only SEND WELCOME BACK (amber, ≤30 min out) / ⚠ WELCOME BACK OVERDUE (red, past departure and unsent) / ✓ WELCOME BACK SENT (quiet green) badge, reusing `getWelcomeBackEta()`/`isAscend()`/`r.delivery_type`/`r.welcome_back_sent_at` exactly as Dashboard does — no second eligibility rule, no animation, and TV Mode still cannot send anything. Recomputed once a minute by extending the existing 1-second `updateTvClock()` tick rather than adding a new timer. Separately, rescoped the Customs/Ascend panel: both NEEDS HANDLING and AT CUSTOMS now require `isToday(r.ret)` or `isTmrw(r.ret)` (return date, matching Leaving Today/Tomorrow's own field), each row tagged TODAY/TOMORROW, sorted today-first; AT CUSTOMS is explicitly not filtered by `isAscend()`, so a regular Makers Air Customs delivery shows there too.
  **Impact:** No schema change, no SMS content change, no delivery/Customs workflow change. All 17 automated assertions (eligibility, threshold boundaries, date scoping, dedup) passed against the real extracted code plus synthetic data; normal AirValet mode and TV Mode rotation/read-only behavior reconfirmed unaffected.

- **Date:** 2026-08-24
  **Reason:** Begin the Offline Mode project (iPad connectivity-loss resilience for New Passenger Check-In) with a full audit before any implementation — the app had zero offline capability despite PWA-looking manifest metadata (confirmed: no service worker, no IndexedDB, no Cache Storage anywhere in the codebase; a cold reopen while offline failed completely, showing Safari's own error page, not AirValet). The audit also surfaced that the Supabase JS dependency was loaded from a *floating* CDN version tag (`@2`, not a true pin) — a pre-existing risk independent of Offline Mode that this project happened to force a fix for.
  **Decision:** Phase 1 (infrastructure only, this entry) implements the app shell/connectivity/identity foundation without routing any real check-in through it — see the Offline Mode section above for full detail. Key architectural calls made during design, not to be revisited casually: (1) ticket format for future offline check-ins is `MMDD-N-<DeviceCode>` (device code as a **suffix**, not prefix — chosen specifically because it parses correctly through the existing `parseInt`-based ticket-sequence functions with zero changes, unlike a prefix placement which would silently break them); (2) device codes are manually assigned, never auto-generated, and device-code *uniqueness* is a hard gate before Offline Check-In may ever be enabled (requires a Phase 3 server-side registry, not yet built); (3) the "offline authorization window" (24h) is explicitly an operational-trust policy, not a security/authentication claim — documented carefully to avoid ever implying Supabase authenticated someone while offline; (4) `offline_sync_id` (UUID, idempotency) and the physical ticket number are deliberately two separate concerns — the ticket is never silently renumbered during sync, matching the real-world constraint that it may already be printed and physically attached to a vehicle.
  **Impact:** Zero change to any production write path — `saveEntry()`, ticket generation, Dashboard, TV Mode, printing, SMS, Daily Closing, and all delivery/Customs/Ascend workflows are byte-for-byte unmodified. A real bug was found and fixed *during* this phase's own testing (not a pre-existing issue): `offline-auth.js`/`offline-db.js` were initially left out of the service worker's precache list, causing a `ReferenceError` on a true cold offline reload; fixed by adding both to `SHELL_FILES`, verified via a clean-slate (unregistered + cache-cleared) install and a genuine server-down reload. No Supabase migration exists yet — required only when Phase 3 (real sync) begins, alongside an RLS/RPC security audit that must precede it.

## Changelog

Chronological list of major changes, reconstructed from `git log` (commits from 2026-05-22 through 2026-06-04) plus untracked working-tree additions observed directly in the current files. Keep this updated going forward — see maintenance note below.

- **2026-05-22:** Initial "Busy Day" warning banner for Sunday returns; refactored into a general "Busy Days" section, then scoped to the current week.
- **2026-05-2x:** Vehicle model + color autocomplete with learning; numeric keyboard triggers for Phone/Ticket on mobile.
- **2026-05-2x:** Reports tab rebuilt into a full 7-section report builder; PDF export implemented and fixed; Report tab icon polish.
- **2026-05-22 → 2026-06-04 (various):** Full audit log with per-field old→new tracking; inline Color editing with persisted vehicle suggestions; car/color split into separate fields; header/navbar responsive rework and "Ultra Clean Modern" redesign (Font Awesome icons replacing emoji in the header/nav only).
- **2026-05-28:** `checkin_date`/`checkout_date` added to all delivery paths; Monthly Operations Report rewritten with full Normal/Customs breakdown; fixed a syntax error in `generateOperationsReport()` that was blocking login; replaced the fixed May report with a dynamic month/year selector.
- **2026-05-30:** Passenger Rating (Great/Normal/Difficult) added to Quick Deliver and the Customs flow.
- **2026-06-01:** Auto-suggested ticket numbers with strict duplicate protection.
- **2026-06-04:** Fixed Epson printing on iOS by switching the printer URL scheme from `https://` to `http://`.
- **Since 2026-06-04 (untracked in git as of this writing):** Operational manual (`MANUAL_OPERACIONAL.md/.pdf`) authored (2026-06-22); Daily Closing Reports feature (table, RLS, full UI) and Customs communication fields/migrations added (2026-07-12); Ascend Valet sub-brand, Hangar 19 Welcome Back SMS, and Customs Welcome-Back/Gratuity reminder workflow built into `index.html`; `CLAUDE.md` and this `PROJECT.md` created (2026-07-13).
- **2026-07-13:** Replaced the Passenger Rating workflow (Great/Normal/Difficult) with a Yes/No "Did the passenger leave a tip?" modal, stored in a new `tip_received` boolean column (migration `20260713_add_tip_received_column.sql`). Added a post-delivery tip SMS for Normal/Lockbox deliveries (Yes = no Stripe link; No = includes the gratuity Stripe link), branded per Ascend/Makers Air; Customs deliveries are explicitly excluded to avoid duplicating the existing Customs Gratuity ask. Fixed several confirmed VCF/contacts bugs: missing CRLF line endings and `N:` field, a Blob-URL leak on every keystroke in the individual "Save to Contacts" link, stale contact data surviving New-Entry-modal reuse, ALL-CAPS (non-title-cased) exported names, a missing trailing CRLF and non-standard MIME type in bulk exports, and a `Reset Export Date` button with no confirmation or success feedback.
- **2026-07-13 (later same day):** Migration executed in Supabase. Ran full end-to-end validation of the tip workflow against the live production database using a disposable `ZZTEST DO NOT USE` record (created and deleted within the session) — confirmed Yes/No save the correct `tip_received` value, the correct SMS opens with the correct copy (no Stripe link for Yes, exact Stripe link for No), Cancel changes nothing, the passenger detail panel reflects the saved status on reopen, Customs deliveries do not trigger a duplicate gratuity SMS, and no console errors occurred throughout. Physical iPhone/iPad testing (touch layout, real Messages hand-off, on-device `.vcf` import) has not been performed — all validation so far is desktop-browser-based against the real database.
- **2026-08-04:** Twilio migration audit delivered (`docs/TWILIO_MIGRATION_AUDIT.md`) covering all 24 SMS send points, risks, proposed architecture/schema, and a 10-phase plan. Only Fase 1 (SMS provider abstraction — `SMS_PROVIDER`, `sendPassengerSms()`) and Fase 2 (`mock_twilio` local simulation modal + Debug-tab history panel) were approved and implemented; `SMS_PROVIDER` defaults to `'native'`, preserving the exact pre-existing `sms:` behavior (verified via a headless test harness with `fetch`/`window.open` intercepted — 58/58 assertions passed, no real network call made). Extracted the two remaining inline SMS templates (`buildReturnDateConfirmationSms`, `buildTaskConfirmationSms`) with byte-identical output. No Twilio account, Edge Function, migration, or secret was created. Full implementation report: `docs/TWILIO_MIGRATION_PHASE1-2_IMPLEMENTATION.md`. Fases 3–10 (migrations, real Twilio send, inbound webhook, bulk send, scheduling, opt-out) remain unapproved.
- **2026-08-24:** TV Mode redesigned from a near-black theme to a light, low-fatigue 24/7 operations-board theme (see TV Mode section above), following an audit, an approved standalone mockup, and two review rounds. Fixed "Checked In Today" (renamed from the ambiguous "Arriving / Checked In Today") to read `checkin_date` instead of the legacy `ts` field, with the existing fallback preserved and ISO timestamps compared against the local calendar day rather than parsed by string-splitting; sorted newest-first. Reordered TV pages to Today → Tomorrow → Operations, with Today now getting the longest rotation dwell. Added a Customs / Ascend panel to the Operations page (NEEDS HANDLING / AT CUSTOMS, built entirely on the existing `isAscend()`/`isCustomsDelivered()`/`getCustomsDueRecords()` helpers — no new business rules); folded the Customs-gratuity-due alert into that panel instead of duplicating it in Special Handling & Alerts. Removed two purely decorative animations (background drift, always-on Leaving-Tomorrow card glow). No schema change; no changes to payment, SMS/Twilio, delivery workflow, Customs business rules, Daily Closing, reports, or printing. Verified via a standalone (uncommitted) test harness that runs the real extracted TV Mode code against synthetic data — normal, zero-record, and 20+-record/density scenarios — since live Supabase credentials weren't available in the dev/test environment for this session; normal (non-TV) AirValet mode confirmed unaffected (login screen and console checked against the built app). A pre-existing, unrelated dead-code condition in the "Leaving Today overdue" check was found during the audit and documented in Known Issues, not fixed (out of approved scope).
- **2026-08-24 (later same day):** Added a read-only Hangar 19 Welcome Back reminder to TV Mode's Leaving Today rows (SEND WELCOME BACK / ⚠ WELCOME BACK OVERDUE / ✓ WELCOME BACK SENT), reusing the Dashboard's exact eligibility (`isAscend()`, `delivery_type==='CUSTOMS'` exclusion) and ETA logic (`getWelcomeBackEta()`) with no second interpretation of departure time and no ability to send anything. Centralized the reminder threshold into one `WELCOME_BACK_REMINDER_MINUTES = 30` constant shared by Dashboard and TV Mode, replacing two duplicated `20*60000` literals — **the Dashboard threshold changed from 20 to 30 minutes** as an explicit, approved part of this change. Rescoped the Customs/Ascend panel (both NEEDS HANDLING and AT CUSTOMS) to today/tomorrow by return date (`isToday(r.ret)`/`isTmrw(r.ret)`) instead of delivery timestamp, with a TODAY/TOMORROW tag per row; AT CUSTOMS is explicitly not filtered by Ascend status, so regular Makers Air Customs deliveries appear there too. No schema, SMS, delivery, or Customs workflow changes. See Development Decisions for the full rationale and test coverage.
- **2026-08-24 (Offline Mode Phase 1):** Added the app-shell/connectivity/identity infrastructure for the future Offline New Entry feature — `service-worker.js` (versioned precache of 8 shell files, network-only for all Supabase traffic, no auto-activating updates), vendored `vendor/supabase.js` (froze the previously-floating `@2` CDN tag at the exact version it resolved to, 2.112.4, unmodified), `offline-db.js` (IndexedDB `airvalet_offline`/`offline_checkins`, diagnostics-only in this phase), `offline-auth.js` (stable per-device UUID, manually-assigned device code, and a 24-hour "offline authorization window" marker — timestamp/email only, never a token or password), a header ONLINE/OFFLINE/NETWORK-NO-SERVER indicator distinguishing `navigator.onLine` from actual (rate-limited) Supabase reachability, and a Debug-tab diagnostics panel. **Offline Check-In does not exist yet** — `saveEntry()` and every other production write path are completely unmodified; nothing here writes real passenger data. Full architecture (ticket-collision strategy, idempotency, sync state machine, RLS considerations, multi-iPad conflict analysis, iPad/Safari-specific risks) documented but only partially implemented — see the Offline Mode section above for what Phase 1 actually built and the explicit list of follow-up work required before Phase 2. One real bug was found and fixed during this phase's own testing: the two new offline-infrastructure files were initially missing from the service worker's precache list, breaking a true cold offline reload; caught via a clean-slate test (unregister + clear caches, fresh install, server stopped, reload) before being considered done.

---

## Maintenance Note

At the end of every future task in this repository, update this file whenever new business rules, workflows, or architectural decisions are introduced — add a Changelog entry and, if applicable, a Development Decisions entry. This keeps PROJECT.md authoritative so project knowledge is never re-derived from scratch in a future session.
