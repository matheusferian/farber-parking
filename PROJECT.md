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
- **Hosting:** Static file hosting (no server-side runtime beyond Supabase).
- **External services:**
  - Supabase (database, auth, RLS)
  - Device-native SMS/Messages app (system opens `sms:` links — the app never sends SMS itself)
  - Device-native Phone app (`tel:` links)
  - Stripe payment link (gratuity collection) — `https://buy.stripe.com/8x214mccK0uh9TjgIM6Vq00`
  - iOS Contacts import via generated `.vcf` files

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
1. **Today** — two columns, **Leaving Today** and **Checked In Today** side by side (name, vehicle+color, hangar/location, ticket, and either departure or check-in time; a ✓ DELIVERED chip on same-day-delivered Checked-In-Today rows; a red NO LOCATION indicator on any row missing a hangar).
2. **Tomorrow** — the existing **Leaving Tomorrow** prep view, unchanged: time-bucketed (Early Morning → After Hours), departure time, passenger, vehicle+color, hangar, ticket, flight number, and only badges that are actually knowable before delivery (✈ ASCEND from the ticket-prefix rule, NOT RETURNING from the check-in-time checkbox) — never CUSTOMS/LOCKBOX, since `delivery_type` isn't set until the vehicle is actually delivered.
3. **Operations** — three columns: **Special Handling & Alerts** (missing departure time tomorrow, missing location — independent alert types only), **Customs / Ascend** (see below), and **Active Vehicles by Location** (hangar occupancy totals for active, non-delivered vehicles).

A compact KPI row sits above the pages on every page: Checked In Today, Leaving Today, Leaving Tomorrow, Missing Locations, Customs / Special (gratuity-reminder-due count), and Total In Custody (all active, non-delivered records — not date-scoped).

**"Checked In Today" definition:** the passenger's actual check-in timestamp, not Return Date. Primary source is `checkin_date` (an ISO timestamp written at insert time); for older records that predate that column, TV Mode uses the same `checkin_date || ts` fallback already resolved by `mapPassengerRow()` and used elsewhere (Dashboard's Arrived Today, the Operations Report). ISO values are parsed with `new Date()` and compared against the local calendar day (`sd()`/`getToday()` from `utils.js`) rather than by string-splitting, so a check-in near a local-day boundary lands on the correct day regardless of the server's UTC offset. Non-ISO legacy strings fall back to the existing `isArrToday()` parser. Sorted newest check-in first. This replaced an earlier version of TV Mode that used the legacy `ts` field only — `ts` and `checkin_date` are written at the same instant for every record since `checkin_date` was introduced, so the two only ever differed for pre-`checkin_date` legacy rows, which the fallback already covers.

**Customs / Ascend panel:** tracks two things using only existing helpers — no new business rules.
- **NEEDS HANDLING** — active (not yet delivered) records where `isAscend(r)` is true (the existing `A-` ticket-prefix rule).
- **AT CUSTOMS** — records where `isCustomsDelivered(r)` is true (`status==='DELIVERED' && delivery_type==='CUSTOMS'`), scoped to today's deliveries (`isToday(r.deldate)`) the same way the KPI's existing Lockbox-today logic is scoped, so this stays a live-shift view instead of growing forever as old Customs deliveries go un-archived. Shown with a muted row background and a subtle strike-through on the name only (vehicle/ticket/hangar stay fully readable), a green ✓ AT CUSTOMS chip, and an amber GRATUITY DUE chip when the existing `getCustomsDueRecords()`/`isCustomsGratuityReminderDue()` logic says the Customs gratuity SMS reminder is due. A record can only ever be in one of the two groups (not-yet-delivered vs. delivered-via-Customs are mutually exclusive on `status`), so nothing is ever shown twice — and the general Special Handling & Alerts column intentionally does **not** duplicate the gratuity-due signal, since every gratuity-due record is by definition already an AT CUSTOMS record.

**Reliability:** Supabase realtime subscription (best-effort, debounced 800ms) layered over a 60s reconciliation poll that alone guarantees the board is never more than ~60s stale; a 15s watchdog that forces an extra reconciliation past 90s without a successful update and shows a STALE DATA banner past 180s; exponential-backoff realtime reconnect; local-clock-only date-rollover detection (no server round-trip) that re-renders Today/Tomorrow groupings and forces a reconciliation at midnight; a session-expired overlay if the Supabase token is rejected (401/JWT error); fullscreen support; cursor auto-hide and an auto-hiding corner control panel (Full Screen, Refresh Now, Pause/Resume Rotation, Next Page, Copy TV URL, Exit TV Mode); and full teardown (`destroyTvMode()`) of every interval/listener/realtime channel on exit or `beforeunload`, so nothing leaks if the tab is reused.

**Visual design (2026-08-24 redesign):** light, low-fatigue 24/7 operations-board theme — soft blue-gray page background (`#E8EEF7`, never pure white), a medium Makers Air navy-to-blue header band, white/near-white cards, dark navy text, and restrained semantic color (blue = operational, green = healthy/completed, amber = needs attention, red = critical only). Replaced the original near-black theme and removed the decorative background drift animation and the always-on card glow pulse on every Leaving Tomorrow card — animation is now limited to the functional reconnecting-dot pulse and a brief page-rotation fade, both cheap and meaningful rather than decorative. See Development Decisions below for why AT CUSTOMS is day-scoped and why the original "Arriving Today" KPI was folded into "Checked In Today."

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
  **Decision:** Redesigned to a light, low-fatigue theme (see TV Mode section above); fixed Checked In Today to read `checkin_date` (with the existing `checkin_date || ts` fallback) via new `tvIsCheckedInToday()`/`tvCheckinTimestamp()` helpers that parse ISO timestamps against the local calendar day rather than string-splitting; reordered pages so Today loads first with the longest dwell; added a Customs / Ascend panel built entirely on existing helpers (`isAscend()`, `isCustomsDelivered()`, `getCustomsDueRecords()`) with two decisions worth recording: (1) **NEEDS HANDLING is not date-scoped** — it shows every active Ascend record regardless of return date, since it's meant as a standing custody list, not a today/tomorrow view; (2) **AT CUSTOMS is scoped to `isToday(r.deldate)`**, mirroring the existing `lockboxToday` pattern, so the panel stays a live-shift view instead of accumulating every un-archived Customs delivery forever. Removed the decorative background-drift animation and the always-on card glow pulse (every Leaving Tomorrow card had one) — animation is now limited to the functional reconnecting-dot pulse and a brief page-fade on rotation.
  **Impact:** No schema change, no changes to delivery/payment/SMS/printing/Daily Closing logic — TV Mode's script/markup/CSS were the only files touched, plus this doc. Verified via a standalone test harness (not committed) that loads the real extracted TV Mode code — same `buildTvViewModel()`/render functions, same CSS — against synthetic data covering zero/normal/high-volume record counts, since TV Mode requires a live Supabase session and no test credentials were available in this environment; realtime-channel-specific behavior (actual Supabase Realtime events, not the reconciliation-poll fallback) was reasoned about from the unchanged subscription code but not separately exercised. See Known Issues for a pre-existing, unrelated dead-code condition found (not fixed) during the audit.

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

---

## Maintenance Note

At the end of every future task in this repository, update this file whenever new business rules, workflows, or architectural decisions are introduced — add a Changelog entry and, if applicable, a Development Decisions entry. This keeps PROJECT.md authoritative so project knowledge is never re-derived from scratch in a future session.
