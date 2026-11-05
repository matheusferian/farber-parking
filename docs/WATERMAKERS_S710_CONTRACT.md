# Watermakers Valet — S710-first system contract (v1, 2026-11-05)

Single source of truth for the three components built in parallel:

| Component | Repo / branch | Owns |
|---|---|---|
| **S710 app** "Watermakers Valet" `com.farberparking.watermakers.tips` | NEW repo `~/Dev/farber-watermakers-terminal` (git init, local only) | The primary operational device: check-in, hooks, get car, delivery, card tips, cash tips, offline queue |
| **AirValet event-valet** (vehicles, SMS, customer pass, staff links, admin) | `~/Dev/worktrees/airvalet-watermakers`, branch `event/watermakers-veterans-2026` | Vehicle records, hook allocation, customer pass + thank-you page, READY routing, cash tips, operational report |
| **Revenue event-pay** (Farber Parking Stripe) | NEW worktree `~/Dev/worktrees/revenue-watermakers` from `origin/main`, branch `feat/watermakers-event-pay` | Stripe connection tokens, card tip ledger (S710 + digital Checkout), webhook reconciliation, partner summary |

Hard rules (all components): nothing deployed, pushed, installed on the physical S710 or applied to any production DB. No real charges (Stripe TEST / simulated reader only). No real SMS (mock Twilio). No Stripe secret or Supabase service-role key in any APK or browser bundle. Makers Air, Causeway, Funky Buddha, Halloween and Rosie's code paths keep working unchanged (regression tests prove it). Rosie's app source (`~/Dev/farber-event-terminal`) is NOT copied or forked; it may be read to learn the infrastructure.

## 0. Identifiers

- AirValet event id: `watermakers-veterans-2026` (row already exists in migration `20261111_event_valet_watermakers.sql`; capacity becomes **50**).
- Revenue event slug: `watermakers-2026-11-11`. Report code: `WATERMAKERS_2026_11_11`.
- Stripe metadata on every Watermakers PaymentIntent: `farber_event=watermakers-2026-11-11`, `event_code=WATERMAKERS_2026_11_11`, `event_kind=TIP_ONLY`, `op_ref=<uuid>`, `channel=TERMINAL|QR`, `vehicle_ref=<AirValet ticket uuid or empty>`, `operator=<employee name or empty>`, `device_label`.
- `vehicleRef` = AirValet `event_valet_tickets.id` (uuid). Opaque to Revenue; never a phone or hook.
- Parking price is **$0 / complimentary**. Revenue event has no parking price (PARKING ops rejected for this slug); only TIP_ONLY.

## 1. Statuses (AirValet tickets)

`PARKED → REQUESTED → RETRIEVING → READY → DELIVERED`. Add `RETRIEVING` (claimed by one employee: `retrieved_by` name + access id). `REQUESTED` can come from `LINK` (customer pass), `SMS` (READY reply) or `STAFF`. Hook (`slot_no`) is released ONLY at `DELIVERED`. Undo allowed: READY→RETRIEVING, RETRIEVING→REQUESTED (release claim), REQUESTED→PARKED (staff cancel).

## 2. Hook pools (offline conflict prevention)

- Event columns: `device_pool int4range default '[1,41)'` (S710), `phone_pool int4range default '[41,51)'` (backup phones).
- Each access credential (§3) belongs to one pool: DEVICE → device_pool, LINK → phone_pool.
- Online allocation is atomic in SQL (row lock on event + unique (event_id, slot_no) where status<>'DELIVERED'): first free hook in the caller's pool; DEVICE may borrow from phone_pool when its pool is full; LINK never borrows from device_pool.
- **Offline:** only the S710 allocates (from device_pool, using its local cache + its own pending ops). The phone web app **disables check-in while offline** ("NO INTERNET — USE THE S710 TO CHECK IN"). Because no one else ever allocates device_pool hooks, the S710's offline choice cannot collide; a hook freed by a phone delivery while the S710 was offline simply stays "used" in the S710 cache until the next sync (conservative).
- Sync conflict still handled defensively: server answers `409 HOOK_TAKEN {suggestedHook}`; the app shows "HOOK 12 ALREADY USED — MOVE KEY TO HOOK 14" and confirms.

## 3. Staff / device access (AirValet)

Table `event_valet_access`: `id uuid`, `event_id`, `kind` (`DEVICE`|`LINK`), `label` (e.g. "S710-1", "Carlos phone"), `token_hash bytea unique` (sha256 of the raw token; raw token shown once at creation), `valid_from`, `valid_until`, `revoked_at`, `created_by uuid`, `created_at`, `last_seen_at`.
Table `event_valet_sessions`: `id uuid`, `access_id`, `employee_name` (2–40 chars), `started_at`, `ended_at`.
Table `event_valet_ops`: `client_key text` + `access_id` unique → `result jsonb` (idempotent replay of any mutating call).
Rate limit: 240 requests/min per access (SQL counter per minute bucket) → 429 `RATE_LIMIT`.
Every mutating call writes `event_valet_audit` with `detail.actor = {access_id, kind, label, employee_name}`.

Raw token: 32 random bytes, base64url (43 chars). Web link: `https://<site>/events/watermakers-veterans-2026/staff#k=<token>` (fragment, never sent to servers in the URL). Device: token baked into the APK build from `local.properties` (`AV_DEVICE_KEY`), revocable from admin.

All staff RPCs are `security definer`, executable **only by service_role**; the edge function validates the token, then calls them with the resolved access/session. Valid only when: event `is_open`, `staff_access_enabled`, `now()` in `[valid_from, valid_until)`, not revoked.

## 4. AirValet staff API (edge function `event-valet`, base `/functions/v1/event-valet/staff`)

Headers: `x-ev-key: <raw token>` (required), `x-ev-session: <session uuid>` (required except `POST /session`), `content-type: application/json`. Responses `cache-control: no-store`. Errors: `{ "error": CODE, "message": "<plain English for employees>" }` with codes `AUTH` 401, `REVOKED` 401, `OUTSIDE_WINDOW` 403, `EVENT_CLOSED` 403, `RATE_LIMIT` 429, `HOOK_TAKEN` 409 (+`suggestedHook`), `TAKEN_BY` 409 (+`by`), `BAD_INPUT` 400, `NOT_FOUND` 404, `DUPLICATE_CASH` 409 (+`existing`).

| Method path | Body | Result |
|---|---|---|
| `POST /session` | `{name}` | `{sessionId, employeeName, access:{kind,label,pool:[lo,hi]}}` |
| `GET /state?since=<iso>` | — | `{serverTime, event:{id,title,date,isOpen,flags:{staffAccess,customerSms,smsReplies,tips,thanks}}, counts:{active,parked,requested,retrieving,ready,delivered,hooksFree}, pools:{device:[1,40],phone:[41,50]}, tickets:[Ticket]}` — all non-delivered + delivered in last 60 min |
| `POST /hold` | `{clientKey}` | `{hook, heldUntil}` (3-min hold for an online two-step check-in) |
| `POST /checkin` | `{clientKey, phone, vehicle:{color,make,model,plate}, location, hook, keyStoredAt, offline:bool}` | `{ticket, sms:{welcome:"SENT"|"QUEUED"|"OFF"}}` — commits only with `keyStoredAt` (key confirmation is part of the check-in) |
| `POST /move-hook` | `{clientKey, ticketId, hook}` | `{ticket}` |
| `POST /status` | `{clientKey, ticketId, to}` (`REQUESTED`/`RETRIEVING`/`READY`/`DELIVERED`/`PARKED`) | `{ticket}`; `RETRIEVING` by another session → 409 `TAKEN_BY` |
| `POST /edit` | `{clientKey, ticketId, location?, vehicle?, phone?}` | `{ticket}` |
| `POST /cash-tip` | `{clientKey, amountCents (100–50000), ticketId?, confirmDuplicate?}` | `{tip}`; same ticket+amount within 3 min without `confirmDuplicate` → 409 `DUPLICATE_CASH` |
| `GET /search?q=` | — | `{tickets}` (phone last 4+, plate, vehicle text, hook number) |

`Ticket` JSON (staff): `{id, hook, status, location, vehicle:{color,make,model,plate}, vehicleText, phoneLast4, checkedInAt, checkedInBy, requestedAt, requestSource, retrievingBy, retrievingAt, readyAt, deliveredAt, deliveredBy, updatedAt}`. Never the full phone in lists (search matches server-side).

Customer-facing `/guest` (existing token flow) gains: status `RETRIEVING` shown as "On the way", `DELIVERED` shows the thank-you page; `tipUrl` = `${REVENUE_PUBLIC_BASE_URL}/e/watermakers-2026-11-11/tip?ref=<ticket uuid>` only when the event `tip_enabled`. Never the hook.

SMS (mock in local): welcome after check-in (existing template, Farber wording, link to pass), "on the way" at RETRIEVING, "ready" at READY, **one** thank-you at DELIVERED (dedupe key `thanks:<ticket>`, only when `thanks_enabled` and SMS enabled): "Thank you for joining us at Watermakers! Your valet has left you a note. View it here: <link> — Farber Parking Valet". READY replies: routed only when the phone has an active ticket in an open event-valet event (feature flag env `EVENT_VALET_SMS_ROUTING=on`, default off); otherwise the existing AirValet `twilio-inbound` behaviour is byte-for-byte unchanged. Ambiguous (2+ active cars) → ask "Reply 1 or 2"; active in Makers Air passenger flow too → don't guess, reply with the pass link hint.

Admin (Supabase authenticated ADMIN only, RPCs with role check): create/revoke access (returns raw token once), extend `valid_until`, toggle flags, report JSON + CSV (vehicles + cash tips + card tips from Revenue partner summary), cash correction with reason (audit keeps old value), close event (blocked while active vehicles / pending ops; disables access + routing; keeps data).

## 5. Revenue event-pay additions (Farber Parking Stripe)

- Event row `watermakers-2026-11-11` (local seed + `scripts/event-pay/prod-config-watermakers.sql` NOT applied): tip-only, `tip_only_presets_cents {500,1000,2000,4000}`, min 100, max 50000, offline caps from config (values to verify on the real account; default 50 / $1,500 until verified), `terminalLocationId` = the S710-1 location (configurable), no parking price.
- Migration (additive): `vehicle_ref text null` (uuid format check) on the ops table; `operator_name` if not present; `partner_key_hash` on events.
- `POST /terminal/sync`: TIP_ONLY ops accept optional `vehicleRef`, `operatorName`. PI metadata verification also checks `vehicle_ref` when present.
- `POST /qr/checkout` + page `/e/{slug}/tip?ref=<uuid>`: optional `vehicleRef` → Checkout Session + PI metadata `vehicle_ref`, `channel=QR`.
- NEW `GET /api/event-pay/{slug}/partner/summary` with header `x-event-partner-key` (sha256 compared in constant time, event-scoped) → `{eventCode, currency:"usd", s710:{count,cents}, digital:{count,cents}, pending:{count,cents}, failed:{count}, refunded:{count,cents}, payments:[{opRef, channel, vehicleRef, operatorName, amountCents, status, createdAt, paymentIntentId}]}` — no card data, no customer data. AirValet's admin report calls it server-side (secret `EVENT_PAY_PARTNER_KEY` in the AirValet function env, local only).
- Existing endpoints, Rosie's event, Causeway webhooks and every other Revenue module unchanged.

## 6. S710 app (Kotlin, Compose, MVVM, Stripe Terminal Android SDK — Apps on Devices for the real S710, simulated reader flavor for the emulator)

- Build config from `local.properties` (never committed): `AV_API_BASE`, `AV_DEVICE_KEY`, `AV_EVENT_ID`, `EP_API_BASE`, `EP_DEVICE_KEY`, `EP_SLUG`. Flavors `device` / `simulated`. Package `com.farberparking.watermakers.tips`, label "Watermakers Valet". New signing key `~/.android-keystores/farber-watermakers-release.jks` (password in Keychain item `farber-watermakers-keystore`).
- Screen size: S710 portrait (AVD `farber_events_s710`, 360×640 dp). One primary action per screen, ≥64 dp targets, no scrolling on primary screens, plain-English errors only.
- Home: **CHECK IN CAR · GET CAR · TIP**; status bar `Cars 18 | Requests 3 | Hooks free 32`; request banner "CAR REQUESTED — HOOK 12" (sound/vibrate if available); network chip ONLINE / "NO INTERNET — YOU CAN STILL CHECK IN CARS"; pending-sync count.
- Check-in: big numeric keypad for phone → color + make chips (or plate) → FRONT/SIDE/BACK → giant `HOOK 12` + `PUT KEY ON HOOK 12` + `KEY STORED — DONE` (+ small "use another hook") → auto-return home. Target ≤ 25 s.
- Get car: request queue (oldest first, wait time) + search (phone digits / plate / hook). `GET CAR` (=RETRIEVING) → `CAR READY` → `DELIVERED` (1 tap each) → auto-return home.
- Tip: amount ($5/$10/$20/$40/OTHER, "NO TIP / CANCEL"), optional vehicle (default none), `PAY BY CARD` → Stripe collect/confirm → `PAYMENT APPROVED` only on Stripe confirmation / `PAYMENT DECLINED` / "PAYMENT NOT CONFIRMED — CHECK STATUS" (unknown outcome → no new attempt until resolved) → home. `RECORD CASH` (AirValet `/staff/cash-tip`). Offline card tips follow `PREFER_ONLINE` with the verified caps; shown as "SAVED — WILL CONFIRM WHEN ONLINE", never as approved money. Tip ledger synced to Revenue `/terminal/sync` with `vehicleRef` + `operatorName`.
- History: last tips (status from server), pending sync list.
- Offline: local JSON store (atomic file writes) of event state + outbox; replay in order with `clientKey` idempotency; conflicts shown in plain English; nothing is ever silently dropped.
- Admin/diagnostics hidden behind a long-press + PIN (from local.properties `ADMIN_PIN`), never shown to employees.
