# MAKERS AIR — HALLOWEEN VALET (Fall Trunk or Treat)

Saturday **Oct 24, 2026 · 3:00–5:00 PM · Hangar 19, FXE** · ~10–15 cars · free valet, optional tips.

Temporary module, fully separate from the normal AirValet operation.

| Piece | What | Where |
|---|---|---|
| Staff page | Check-in + valet board (iPhone/iPad) | `/events/makers-halloween-2026` |
| Guest page | Digital ticket, REQUEST MY CAR, optional tip | `/events/makers-halloween-2026/t#<token>` |
| Database | 4 new tables + 12 functions (`event_valet_*`) | `migrations/20261024_event_valet_makers_halloween.sql` |
| Edge Function | SMS send, Twilio inbound READY, status, guest link | `supabase/functions/event-valet` |

Not touched: `index.html`, `utils.js`, `styles.css`, `service-worker.js`, passengers, Closing Report,
payments, SMS tables, Farber Stripe, other locations. Only `vercel.json` (+2 rewrites, +1 header block)
and `vercel-build.sh` (+copy of the 2 pages) change.

## Behaviour

- Check-in: phone (US, E.164) + vehicle → ticket **= last 4 digits of the phone** (`#0101`; same last 4 again → `#0101-B`, `-C`; never reused; internal `REF #001` kept)  + first free key slot `01–20`
  (freed on DELIVERED). Allocation locks the event row → no duplicate numbers/slots (20 parallel check-ins tested).
  Double tap / retry returns the same ticket (client key). 21st car with all slots taken still gets a ticket, slot assigned by hand.
- Print: Epson TM-m30II via HTTPS ePOS (same `printer_host` as the main app). Auto-print once after check-in; REPRINT never changes number/slot; 4 s guard against double print. Failure never blocks check-in.
- SMS (server side only): CHECK-IN, REQUESTED, TIP (after DELIVERED, once per ticket). RESEND ≤ 1 per 30 s.
- Guest replies `READY` (any case, optional ticket code, e.g. `READY 0101-B`). One active car → REQUESTED + confirmation.
  Two active cars on one phone → replies with the options (`READY 0101 — BMW`, `READY 0101-B — AUDI`); a number that is not theirs → no change.
  Unknown numbers: never stored, never answered. STOP/HELP handled by Twilio Advanced Opt-Out.
- Guest link: random 256-bit token, only SHA-256 stored; a new SMS link replaces the old one. Never shows key slot or phone.
- Guest without SMS: valet types the last 4 digits or the vehicle in the board search.
- Board: polls every 3 s; REQUESTED first (orange), READY (green), PARKED, DELIVERED (grey). Sound + toast on new request. DELIVERED asks for confirmation; UNDO within 15 min.

## Bad network (added 2026-10-23)

| Situation | What happens |
|---|---|
| Weak / oscillating signal | Every request gives up after 12 s (6 s at check-in) and safe actions retry; the check-in key makes retries return the same ticket |
| **Wi-Fi down, 4G up** (printer unreachable) | Everything keeps working; key tickets go to a **print queue** (header `PRINTER ✕ · N QUEUED`) and print by themselves, once, as soon as the printer answers (checked every 8 s). Queued items older than 6 h, deleted or delivered tickets are dropped |
| **No internet, printer on Wi-Fi** | **Offline mode** (header `📴 OFFLINE · N TO SYNC`): check-in is saved on the phone (code = last 4, key slot taken from the top: 20, 19…), the key ticket prints right away, and on reconnect `event_valet_checkin_offline` syncs it, keeps the printed code/slot when still free (else assigns new ones and the phone shows *Ticket changed after sync* + REPRINT), then sends the guest SMS |
| App opened with no internet | Event service worker (scope `/events/makers-halloween-2026/`, network-first) serves the cached page |

## Operator alerts

- Web Push to every phone that tapped **🔔 ALERTS** in the Home-Screen app (iOS 16.4+), on guest requests (SMS READY / link). Own RFC 8291/8292 code (`webpush.ts`), verified byte-exact against the RFC 8291 test vector.
- SMS backup to `staff_alert_phones`.

## Safety switches (row `event_valet_events`, id `makers-halloween-2026`)

| Column | Default | Meaning |
|---|---|---|
| `sms_enabled` | false | nothing is sent while false |
| `sms_test_only` | true | only `sms_test_phones` receive texts |
| `tip_enabled` | false | TIP SMS + tip buttons hidden while false |
| `tip_links` | `{}` | `{"5":url,"10":url,"20":url,"other":url}` — Stripe **Matt Solutions** only |
| `include_ticket_link` | true | adds "Your digital ticket: <link>" to the check-in SMS |
| `is_open` | true | false = check-in closed, inbound READY ignored |

## GO checklist (each step needs owner GO)

1. **DB**: apply `migrations/20261024_event_valet_makers_halloween.sql` to prod (additive only).
2. **Function**: `supabase functions deploy event-valet --no-verify-jwt --project-ref sfewtirvqhrpanwhbchd`
3. **Secrets** (Supabase → Edge Functions → Secrets):
   `TWILIO_ACCOUNT_SID`, `TWILIO_API_KEY_SID` + `TWILIO_API_KEY_SECRET` (send), `EVENT_VALET_INBOUND_KEY` (random ≥32 chars, webhook URL key `?k=`) — or `TWILIO_AUTH_TOKEN` for X-Twilio-Signature (when set, the URL key is no longer accepted),
   `TWILIO_MESSAGING_SERVICE_SID` = AirValet SMS (MG9f8e…281f; number +1 954-526-9800, A2P campaign approved),
   `EVENT_VALET_PUBLIC_URL=https://sfewtirvqhrpanwhbchd.supabase.co/functions/v1/event-valet`.
   Optional: `TWILIO_API_KEY_SID` / `TWILIO_API_KEY_SECRET` (send with an API key instead of the Auth Token).
4. **Twilio**: AirValet SMS service → Integration → Incoming messages webhook →
   `https://sfewtirvqhrpanwhbchd.supabase.co/functions/v1/event-valet/inbound?k=<EVENT_VALET_INBOUND_KEY>` (before it points to the never-deployed
   `twilio-inbound`; FarberOS service/number untouched). Restore after the event.
5. **App**: merge branch → Vercel prod deploy (pages only).
6. **Test (test-only mode)**: `sms_enabled=true`, `sms_test_phones={owner phone}` → check-in, READY, deliver.
7. **Go live**: `sms_test_only=false`. Tips only after the Stripe account is confirmed (`tip_enabled=true`, `tip_links`).

## Rollback

- Turn off texts instantly: `update event_valet_events set sms_enabled=false where id='makers-halloween-2026';`
- Close the event: `… set is_open=false …`
- Pages: redeploy the previous Vercel deployment (main app unaffected either way).
- Twilio: set the AirValet SMS inbound URL back to `…/functions/v1/twilio-inbound`.
- Function: `supabase functions delete event-valet`; then unset `EVENT_VALET_INBOUND_KEY` (rotate after the event).
- DB: `migrations/20261024_event_valet_makers_halloween_rollback.sql` (archives the data in `airvalet_archive`, drops only `event_valet_*`).

## Tests

`tests/event_valet/e2e_errors.mjs` — 64 checks in headless Chrome with two isolated "phones": validation, autocomplete, lost response, slow signal, Wi-Fi drop + auto print, SMS endpoint down, simultaneous check-ins, same last 4, board sync, delete, offline mode + sync conflict, full offline, offline delete, app reopened offline, banner, expired session, end-state integrity.

```
tests/event_valet/sql_tests.sql   49 checks (rolls back)          psql -v ipad=<uuid> -v tv=<uuid> -f …
tests/event_valet/race_test.sh    20 simultaneous check-ins
tests/event_valet/edge_test.ts    9 tests, real local PostgREST, fake Twilio
tests/event_valet/devserver.ts    local pages + function (mock SMS) + fake printer
tests/event_valet/sim_sms.ts      signed inbound SMS to the local devserver
```
