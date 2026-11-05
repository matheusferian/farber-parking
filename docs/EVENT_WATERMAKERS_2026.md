# FARBER PARKING — WATERMAKERS VALET (MIASF Member Connect · Thank You Veterans)

Wednesday **Nov 11, 2026 · 5:30–7:30 PM · Watermakers, Inc., 2233 S Andrews Ave, Fort Lauderdale** ·
complimentary valet courtesy of Farber Parking · up to 30 cars.

Same Event Valet module as the Halloween event (see `EVENT_MAKERS_HALLOWEEN_2026.md` for behaviour,
bad-network handling, push alerts and tests). Only the differences are listed here.

| Piece | What |
|---|---|
| Staff page | `/events/watermakers-veterans-2026` (Home-Screen app "Watermakers Valet") |
| Guest page | `/events/watermakers-veterans-2026/t#<token>` |
| Event row | `event_valet_events.id = 'watermakers-veterans-2026'`, 30 key slots, locations FRONT / SIDE / BACK |
| Migration | `migrations/20261111_event_valet_watermakers.sql` (+ `_rollback.sql`) |
| SMS wording | `lib.ts` → `BRANDS['watermakers-veterans-2026']`, signed "— Farber Parking Valet" (Halloween text unchanged) |

What the migration changes: adds `event_valet_events.locations` (default = Halloween list), replaces the
fixed parking-location CHECK with a trigger that validates against the ticket's event, updates
`event_valet_set_location` + `event_valet_checkin_offline` to use the per-event list, inserts the event
row (SMS off, test-only, tips off, no guest link). Only `event_valet_*` objects.

Off-site printer: the page has **Printer → CHANGE PRINTER IP** (stored as `ev_printer_host`, this page only;
the main AirValet app's `printer_host` is untouched). Phones and printer must be on the same Wi-Fi/hotspot.

## GO checklist (each step needs owner GO)

1. DB: apply `20261111_event_valet_watermakers.sql` in prod (fingerprint non-event objects before/after).
2. Function: redeploy `event-valet` (`--no-verify-jwt`) — per-event texts.
3. Secret: new `EVENT_VALET_INBOUND_KEY` (was unset after Halloween).
4. App: merge branch → Vercel prod (pages only).
5. Event row: `staff_alert_phones`, `sms_test_phones` = owner → test → `sms_enabled=true`, then `sms_test_only=false`.
6. Tips (optional): `tip_links = {"sms": "<FARBER buy.stripe.com link>", ...}` + `tip_enabled=true`.
7. Event day only: Twilio AirValet SMS (MG9f8e…) inbound → `event-valet/inbound?k=<key>`.

## After the event

`is_open=false, sms_enabled=false, tip_enabled=false`; Twilio inbound back to `/functions/v1/twilio-inbound`;
unset `EVENT_VALET_INBOUND_KEY`; back up the event data.

## Tests (local stack airvalet-sms-local)

SQL Watermakers 17/17 (`tests/event_valet/sql_tests_watermakers.sql`), SQL Halloween 62/62, race 20/20,
edge 16/16 (`deno test -A --no-check`, the 3 type errors are pre-existing), webpush 2/2,
E2E 64/64 on both pages (`EV_EVENT=watermakers-veterans-2026 node tests/event_valet/e2e_errors.mjs …`),
rollback → functions + constraints identical to before.
