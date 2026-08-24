# FARBERMAKERS Architectural Decision Log

Permanent, append-only record of significant technical and business decisions for the Makers Air Valet system. Never delete an entry — if a decision is later reversed, add a new entry that supersedes it and cross-link both (see [[future-maintenance]] at the end of this file).

Each entry follows this template:

```
# Decision Title
Date
Problem
Options Considered
Decision Made
Reason
Trade-offs
Impact
Related Files
Future Notes
```

---

# Ticket Numbering Strategy

**Date:** Unknown — present from an early build; refined 2026-06-01

**Problem:** Every check-in needs a short, human-writable, physically-printable identifier that staff can read off a paper ticket and match to a record, without a central sequence server.

**Options Considered:**
1. Database auto-increment integer ID exposed as the ticket
2. UUID truncated to a few characters
3. Date-based counter (`MMDD-N`) computed client-side from existing same-day records
4. Fully manual entry with no suggestion

**Decision Made:** Auto-suggest `MMDD-N` (e.g., `0622-1`, `0622-2`) based on the current date and count of same-day tickets, editable by the attendant. Strict duplicate protection added 2026-06-01 (warns, does not hard-block).

**Reason:** Staff need to reconcile tickets against Daily Closing "first ticket / last ticket" ranges by eye; a date-scoped counter is legible on a thermal receipt and naturally resets daily. A hard block on duplicates was rejected because legitimate edge cases (corrections, reprints) need to still save.

**Trade-offs:** Not globally unique across dates by construction — collision risk is deliberately handled by soft warning rather than a hard constraint, which means duplicate tickets are possible if staff ignore the warning.

**Impact:** Daily Closing Report's `first_ticket`/`last_ticket` fields are derived from this same numbering scheme. The Ascend sub-brand later overloaded this same field (see next entry) rather than adding a new column.

**Related Files:** `index.html` (`getNextTicket`, `_autoTicket`), `migrations/20260712_create_daily_closing_reports.sql` (`first_ticket`, `last_ticket`)

**Future Notes:** If the ticket format ever changes (e.g., adding a location prefix), the `isAscend()` regex (`^A-`) and the Daily Closing ticket-range logic must be updated together — they both parse the same string.

---

# Ascend Valet Workflow (Brand-via-Ticket-Prefix)

**Date:** Pre-dates tracked git history and migrations; documented 2026-07-13

**Problem:** Makers Air needed to support a second, private-flight service ("Ascend Valet") sharing the same operational system, with different branding on tickets/SMS and a different (Customs-only) Welcome-Back/Gratuity flow — without disrupting the existing Makers Air data model.

**Options Considered:**
1. Add a `brand` / `service_type` column to `passengers` and a migration
2. Separate table or separate app instance for Ascend
3. Overload the existing `ticket` field with a prefix convention and detect it in code

**Decision Made:** Any ticket matching `^A-` (format `A-MMDD-N`) is treated as Ascend everywhere via a single `isAscend(r)` helper. This flips: ticket format, print header (brand name + "PRIVATE FLIGHT"), badge styling (`✈ ASCEND` tag), customer-copy print gating (confirmation prompt, since Ascend normally skips the customer copy), and which Welcome-Back/Gratuity SMS copy is used.

**Reason:** Avoided a schema migration and kept both services on one flat table and one codebase, since the only real behavioral difference is presentation and messaging, not data shape.

**Trade-offs:** Brand identity is now implicitly encoded in a string pattern rather than an explicit column — a future rename of the ticket format would silently break brand detection everywhere it's checked. There's also no database-level guarantee that `A-`-prefixed tickets stay reserved for Ascend.

**Impact:** Every brand-sensitive code path (`isAscend()`) must be kept in sync manually; there are currently ~15+ call sites in `index.html` depending on this single regex.

**Related Files:** `index.html` (`isAscend`, `getNextAscendTicket`, `selOp`, print builders, SMS builders)

**Future Notes:** If Ascend ever needs its own fields (e.g., a distinct pricing model or a third brand is added), revisit this decision — a real `service_type`/`brand` column would remove the string-parsing fragility. Do not repeat the same trick for a third brand.

---

# Customs Communication Workflow (Welcome Back → Gratuity)

**Date:** ~2026-07-12 (migration `20260712_add_customs_communication_fields.sql`)

**Problem:** Customs deliveries need a two-step passenger communication (arrival notice, then a gratuity ask) that must never fire out of order, never duplicate, and must be per-trip (not per-passenger-forever), while keeping no new PII surface.

**Options Considered:**
1. New join table linking passengers to communication events
2. Separate "communications" table keyed by passenger phone/name
3. Additive boolean/timestamp columns directly on `passengers`

**Decision Made:** Five nullable/defaulted columns added directly to `passengers`: `customs_welcome_sent`, `customs_welcome_sent_at`, `customs_gratuity_sent`, `customs_gratuity_sent_at`, `customs_gratuity_dismissed`. Application logic (`isCustomsGratuityReminderDue`) enforces: gratuity is only eligible after Welcome Back is sent, never fires twice, and respects manual dismissal. Kept explicitly separate from the unrelated Hangar 19 "Welcome Back" feature, which uses its own `welcome_back_sent_at` field.

**Reason:** Each check-in is already its own row in `passengers`, so the communication state is naturally trip-scoped — no join table needed. Migration comments explicitly note it is additive-only and safe to run more than once.

**Trade-offs:** No relational integrity enforcing the sequencing — the "Welcome Back before Gratuity" rule lives only in application code (`isCustomsCommEligible`, `getCustomsGratuityReminderTime`), not the database. A future direct-SQL edit could violate the sequence silently.

**Impact:** Two independent "Welcome Back" concepts now exist in the codebase (Hangar 19 vs. Customs) that must not be conflated — this is called out explicitly in code comments and must be respected in any refactor.

**Related Files:** `migrations/20260712_add_customs_communication_fields.sql`, `index.html` (`sendCustomsWelcomeSms`, `sendCustomsGratuitySms`, `isCustomsGratuityReminderDue`, `buildCustomsGratuitySms`)

**Future Notes:** If a third communication step is ever added (e.g., a follow-up survey), continue the same additive-column pattern for consistency, and keep the eligibility chain (`isCustomsCommEligible` → welcome sent → gratuity eligible) as a single, well-tested function rather than duplicating the condition inline elsewhere.

---

# SMS Strategy (Prefill-Only, Never Auto-Send)

**Date:** Present from the earliest version of the system

**Problem:** Passengers need timely SMS updates (welcome, confirmation, Customs comms, gratuity) without the system holding SMS-sending credentials, carrier costs, or opt-in/compliance overhead of a programmatic SMS API (e.g., Twilio).

**Options Considered:**
1. Integrate a transactional SMS API (Twilio, etc.) for fully automatic sending
2. Pre-fill an `sms:` deep link that opens the device's native Messages app, requiring a manual tap-to-send
3. Manual copy-paste of message text

**Decision Made:** Every SMS touchpoint (Welcome, Task confirmation, Hangar 19 Welcome Back, Customs Welcome Back, Customs Gratuity) builds the message text in JS and opens it via an `sms:` link in the device's native app; the attendant must press Send.

**Reason:** Avoids carrier/API costs and A2P registration entirely, avoids storing/managing message-sending credentials, and keeps a human in the loop to catch obviously wrong numbers/messages before sending. This was an explicit, documented limitation in the operational manual, not an oversight.

**Trade-offs:** Messages are sometimes not actually sent if staff navigate away before pressing Send in the Messages app — a known operational risk, mitigated by training rather than by the system. No delivery receipts or read status are available to the app.

**Impact:** All "Send X SMS" flows in the UI are really "prepare and hand off to Messages app" flows; any future automation would be a genuine architecture change (see Future Improvements in `PROJECT.md`), not a small patch.

**Related Files:** `index.html` (all `sms:`-link builders), `PROJECT.md` (SMS Templates section)

**Future Notes:** If automatic sending is ever implemented (top item in the manual's roadmap), this decision should be superseded by a new entry here — including how compliance (opt-out, quiet hours) will be handled, since none of that exists today.

---

# Backup Policy (Mandatory Timestamped Backups Before Any File Change)

**Date:** 2026-07-13

**Problem:** File edits in this project (a single large `index.html`, hand-maintained migrations) have no version control safety net for uncommitted work, and mistakes during AI-assisted or manual edits could silently destroy working code with no easy recovery path.

**Options Considered:**
1. Rely solely on git for recovery
2. Require a manual "save a copy" step left to human discipline
3. Mandatory, automatic, timestamped backup folder before any file is touched, enforced as a standing rule

**Decision Made:** Before any modify/create/delete/rename/move, copy every affected file into `FARBERMAKERS/BKP/YYYY-MM-DD HH-MM-SS/`, preserving folder structure; never overwrite a prior backup; stop and report if a backup can't be created.

**Reason:** Git alone is insufficient here because a large portion of the current feature set (Ascend, Customs comms, Daily Closing) is sitting **uncommitted** in the working tree (confirmed via `git status` — see `PROJECT.md` Known Issues). A backup policy is a safety net independent of whether changes have been committed yet.

**Trade-offs:** Creates growing disk usage in `BKP/` over time with no automatic pruning; adds a small amount of overhead to every file-touching task.

**Impact:** Every task in this repo now has a recoverable pre-change snapshot, at the cost of manual/periodic cleanup of the `BKP/` folder (not automated by this policy).

**Related Files:** `CLAUDE.md` (Section 1), `BKP/` (runtime artifact)

**Future Notes:** Consider committing the working tree to git regularly so this backup policy becomes a second line of defense rather than the only one. No automatic pruning of old `BKP/` snapshots exists yet — revisit if disk usage becomes a problem.

---

# Daily Closing Report (Cash/Attendant Reconciliation)

**Date:** ~2026-07-12 (migration `20260712_create_daily_closing_reports.sql`)

**Problem:** End-of-shift cash and staffing reconciliation was undocumented in the system — no record of payment-method totals, attendants on shift, or money pickups, and no protection against a finalized day's numbers being altered afterward.

**Options Considered:**
1. Track closing data as free-text notes on existing records
2. Store closing data in `passengers`-adjacent fields
3. New dedicated `daily_closing_reports` table, decoupled from passenger data, with an explicit Draft/Finalized lifecycle

**Decision Made:** New table, one row per `report_date` (unique), holding auto-computed counts (first/last ticket, checked-in/delivered today), payment-method totals (cash/card/venmo/cash_app/zelle), JSON arrays for attendants and money pickups, two manual verification checkboxes, and a `status` of `DRAFT`/`FINALIZED`. A database trigger blocks any `FINALIZED → DRAFT` transition, and finalizing requires both verification checkboxes to be true — enforced both in the app (`dcValidateForFinalize`) and at the database level.

**Reason:** Explicitly designed to hold **no passenger PII** ("read-only against `passengers`" per the migration's own comment) so it can have different (broader) internal access than customer data, and to make finalized financial records tamper-resistant even from direct database access.

**Trade-offs:** Attendants and money pickups are stored as `jsonb` arrays rather than normalized child tables, trading relational query-ability for simplicity given the small, bounded size of these lists per day.

**Impact:** Once a day is finalized, the only way to correct it is a new decision/process (there is currently no "correction" or "amendment" flow) — this is intentional friction, not an oversight.

**Related Files:** `migrations/20260712_create_daily_closing_reports.sql`, `migrations/20260712_daily_closing_reports_rls.sql`, `index.html` (`dc*`-prefixed functions)

**Future Notes:** If a correction workflow is ever needed for finalized reports, it must be a new, explicit, audited decision — do not simply remove the `dcr_block_unfinalize` trigger, since that would defeat the entire point of finalization.

---

# Leaving Tomorrow Report — Direct PNG/PDF Export (No Print Dialog)

**Date:** Undated (present in current `index.html`; post-dates the tracked git history, since it doesn't appear in any of the 33 committed commits)

**Problem:** Staff need to share the next day's departure list (vehicle, hangar, flight info) with people who aren't at a workstation — typically via WhatsApp — without relying on the OS print dialog, which is slow and inconsistent across iPad/desktop.

**Options Considered:**
1. Keep using the existing browser print dialog (`window.print()`) for this report too
2. Generate a server-rendered PDF (would require a backend, which this app doesn't have)
3. Render an off-screen, purpose-built HTML view and rasterize it client-side with `html2canvas`, then share/download the image directly

**Decision Made:** Built a dedicated hidden export host (`#leavingTomorrowExport`), styled independently from the live UI, rendered off-screen and captured via `html2canvas` at a fixed target width (`LT_EXPORT_TARGET_PNG_WIDTH = 3240px`, prioritizing readability over file size). Shares the resulting PNG directly through the Web Share API (file-only payload) when available, with an explicit fallback modal to manually save the image if direct sharing fails or isn't supported. A "Save PDF" option is offered alongside "Share Image."

**Reason:** A backend-rendered PDF wasn't feasible without a server; a client-only screenshot-style export sidesteps print-dialog inconsistencies and produces something instantly shareable to WhatsApp, which is how this report is actually used operationally.

**Trade-offs:** Depends on a third-party CDN script (`html2canvas@1.4.1` from jsDelivr) at runtime — an outage or CDN block would break this specific export path (though the rest of the app is unaffected). Large fixed export width (3240px) trades file size for legibility on all devices.

**Impact:** Establishes a reusable pattern (off-screen styled host + `html2canvas` + Web Share with manual-save fallback) that could be reused for other shareable reports in the future.

**Related Files:** `index.html` (`captureLeavingTomorrowCanvas`, `shareLeavingTomorrowImage`, `buildLeavingTomorrowExportData`, `ensureLeavingTomorrowExportStyle`, `#ltShareFallbackOv`)

**Future Notes:** If other reports need the same "share as image" treatment (e.g., Daily Closing already has a `dcSharePng()` following the same pattern), factor the off-screen-host + html2canvas + Web-Share-with-fallback logic into a single shared helper instead of duplicating it per report.

---

# Security Baseline: Universal HTML-Escaping Against XSS

**Date:** Present from the earliest tracked version of `utils.js`

**Problem:** Nearly every piece of data rendered in the UI (names, phone numbers, vehicle info, notes) originates from free-text staff input and is interpolated directly into HTML strings built in JavaScript — a classic stored/reflected XSS surface if left unescaped.

**Options Considered:**
1. Escape ad hoc at each render call site as needed
2. Rely on a templating library with automatic escaping (would require adopting a framework)
3. A single shared `escapeHTML()` utility, used consistently at every interpolation point

**Decision Made:** A single `escapeHTML(s)` helper (escaping `& < > " '`) lives at the top of `utils.js` and is called at essentially every point where user-controlled data is interpolated into an HTML string (table rows, cards, tickets, print markup, modals).

**Reason:** The app has no framework-level auto-escaping (it's hand-built HTML-in-JS), so a single, consistently-applied helper was the simplest way to close the XSS surface without adopting a templating framework.

**Trade-offs:** Escaping discipline depends on every new render call site remembering to use `escapeHTML()` — there is no compiler/linter enforcing this; a missed call site is a silent vulnerability.

**Impact:** This is the project's primary XSS defense and must be preserved in any refactor; never interpolate raw user input into HTML strings without it.

**Related Files:** `utils.js` (`escapeHTML`)

**Future Notes:** If the app is ever restructured (e.g., introducing a templating layer or framework), replacing hand-rolled `escapeHTML()` calls with framework-level auto-escaping would remove this "easy to forget" risk — but until then, treat every new HTML-string-building function as needing an explicit escaping review.

---

# Tip Status (Yes/No) Replaces Passenger Rating

**Date:** 2026-07-13

**Problem:** The Passenger Rating step (Great/Normal/Difficult), asked at the moment of delivery, was being repurposed for a narrower operational need: knowing whether a passenger left a tip. The rating scale didn't map to that question, and "rating" the passenger as a person is a different (and more sensitive) thing than recording a tip outcome.

**Options Considered:**
1. Keep the 3-option rating and reinterpret it informally as a tip proxy
2. Add a second, separate post-rating question for tip status (two questions per delivery)
3. Replace the rating step outright with a single Yes/No tip question, retiring rating entirely

**Decision Made:** Replaced the rating modal and its Great/Normal/Difficult options with a single "Did the passenger leave a tip?" Yes/No modal. Delivery finalization (the DB write that flips `status` to `DELIVERED`) still happens on this same screen, exactly as it did with rating — only the question and the stored value changed. New column `tip_received` (nullable boolean: `true`/`false`/`null`) added via `migrations/20260713_add_tip_received_column.sql`. The historical `customer_rating` column and its existing GREAT/NORMAL/DIFFICULT values are left untouched and unwritten going forward — this is a genuine field retirement, not a rename or repurpose.

**Reason:** A dedicated Yes/No question is unambiguous and directly answers the operational question ("did they tip?") without the baggage of rating a passenger's demeanor. Reusing the existing delivery-finalization screen (rather than adding a second step) keeps the attendant workflow exactly as fast as before — one screen, one decision, delivery is finalized.

**Trade-offs:** Any historical "difficult passenger" signal that the old rating captured is no longer collected going forward — this was a deliberate scope narrowing, not an oversight; if passenger-behavior tracking is needed again later, it should be reconsidered as its own explicit feature rather than folded back into tip status. Two independent modal-reuse-safety mechanisms now exist in the codebase (Customs comms flags vs. tip status) that both key off delivery events but store to different columns — a future refactor should keep these conceptually separate rather than merging them.

**Impact:** Every quickDeliver path (table ✓ button, Dashboard Deliver/Customs/Lockbox buttons) now asks the tip question instead of rating. The passenger detail panel's "Passenger Rating" row became a "Tip" row (full text: "💵 Tip: Yes" / "Tip: No" / "Tip: Not recorded"); the Dashboard's delivered-card badge became a compact icon-only chip (💵✓ / 💵✕ / 💵?). Both display paths use strict `true`/`false`/`null` checks so a recorded "No" is never confused with "not yet recorded" — a deliberate defense against a truthy/falsy shortcut bug. A new post-delivery SMS opens for Normal/Lockbox deliveries based on the Yes/No answer (see next entry-adjacent note in `PROJECT.md`'s SMS Templates table); Customs deliveries are explicitly excluded so the existing Customs Welcome-Back → Gratuity sequence is never duplicated.

**Related Files:** `index.html` (`#tipOv`, `openTipModal`, `selectTip`, `deliverWithTip`, `buildTipSms`, `openTipSms`, `tipStatusHtml`, `tipStatusCompact`), `styles.css` (`.tip-opt`, `.tip-yes`, `.tip-no`, `.cr-tip-*`, `.tip-chip*`), `migrations/20260713_add_tip_received_column.sql`

**Future Notes:** The migration has been written but **not executed** against Supabase as of this writing (confirmed live during testing: a real save attempt returned `PGRST204 — Could not find the 'tip_received' column`). It must be run in the Supabase SQL editor before this feature will actually persist tip status in production; until then, every delivery will fail to save with a visible error (by design — the app fails loudly rather than silently dropping the tip answer).

---

# VCF / Contact Export Standards-Compliance Fixes

**Date:** 2026-07-13

**Problem:** The project's three contact-export surfaces (individual "Save to Contacts," bulk "Export All/New Contacts," and "Reset Export Date") had accumulated confirmed bugs: non-standard line endings, a per-keystroke Blob URL leak, stale data surviving modal reuse, ALL-CAPS exported names, a missing trailing CRLF and non-standard MIME type on bulk exports, and no confirmation/feedback on the reset action.

**Options Considered:**
1. Leave the existing implementation as-is (bugs are minor, "mostly works")
2. Rewrite the contact-export system from scratch with a new architecture
3. Fix each confirmed bug in place, sharing logic between individual and bulk export where possible, without redesigning the overall approach

**Decision Made:** Fixed in place. Added a single shared `buildVcardBlock()` (vCard 3.0, CRLF throughout, trailing CRLF, `N:`+`FN:` fields, `ORG:`/`NOTE:`, proper escaping via the already-existing `escapeVCardText()`) used by both the individual Save-to-Contacts link and the bulk exporter. Added `titleCaseName()`/`splitNameForVcard()` (preserves apostrophes/hyphens, never invents a last name) since stored names are all-caps but iPhone contacts should read in Title Case. Fixed `normalizePhoneForVcf()` to preserve international numbers beginning with `+` (previously stripped the `+` along with all other non-digits, silently discarding non-US numbers) while leaving its existing US 10/11-digit handling unchanged. Added Blob-URL revocation tracking (`_vcfLastUrl`) to the individual link, wired `updateVcf()` into the frequent-passenger autocomplete handler (previously not called there — a confirmed stale-data bug) and into `openAdd()`'s reset (previously left stale data visible when the New Entry modal was reused for a different passenger).

**Reason:** All of these were confirmed, reproducible bugs against the project's own iPhone-compatibility goal — not a case for a rewrite. The bulk exporter's dedup-by-normalized-phone and most-recent-wins logic was already correct and was left untouched.

**Trade-offs:** "Export New Contacts" tracking remains `localStorage`-only — device/browser-specific, lost on Safari data clear, not synced across iPhone/iPad/desktop. A database-backed version was explicitly out of scope for this pass (would be a larger architectural change requiring separate approval) and this limitation is now documented in `PROJECT.md` rather than hidden.

**Impact:** Both export paths now produce iPhone-importable, standards-compliant vCard 3.0 files with correctly cased names. The individual Save-to-Contacts link no longer leaks a Blob URL on every keystroke and no longer shows a previous passenger's contact after the New Entry modal is reopened.

**Related Files:** `index.html` (`buildVcardBlock`, `titleCaseName`, `splitNameForVcard`, `updateVcf`, `normalizePhoneForVcf`, `downloadVcfContacts`, `resetContactsExportDate`)

**Future Notes:** If "Export New Contacts" reliability becomes a real operational problem (not just a known limitation), the next step would be a database-backed export-tracking column/table rather than continuing to patch the `localStorage` approach — that change needs its own approval and its own DECISIONS.md entry before implementation.

---

## Future Maintenance

Whenever a significant architectural or business decision is made in a future task, add a new entry to this file using the template at the top — do not silently fold the reasoning into commit messages or PROJECT.md alone. If a past decision is reversed or superseded, add a new entry rather than editing the old one, and cross-reference both so the history of *why* is never lost.
