# Watermakers S710 — running the AirValet side locally

Everything here is **local only** (Docker stack `airvalet-sms-local`, mock SMS). Nothing talks to
production Supabase, Twilio, Stripe or Vercel. API contract: `docs/WATERMAKERS_S710_CONTRACT.md` §4.

## 1. Local stack

```sh
docker ps | grep airvalet-sms-local          # db 55332, API gateway 55331
```
Migrations used by this module (apply in order on a fresh stack; the current local DB already has them):
`20261024_event_valet_*`, `20261111_event_valet_watermakers.sql`, `20261112_event_valet_watermakers_s710.sql`
(rollback: `20261112_event_valet_watermakers_s710_rollback.sql`, tested — fingerprint identical).

```sh
docker exec -i supabase_db_airvalet-sms-local psql -U postgres -v ON_ERROR_STOP=1 < migrations/20261112_event_valet_watermakers_s710.sql
```

Local service / anon JWTs + test password live in the session scratchpad `keys/` folder
(`service.key`, `anon.key`, `pw.txt`) — the stack's `PGRST_JWT_SECRET` is a JWKS, keys are minted from its `oct` key.

## 2. Edge function + pages (dev server)

```sh
K=<scratchpad>/keys
EV_SERVICE_KEY_FILE=$K/service.key EV_ANON_KEY_FILE=$K/anon.key \
  [EV_REVENUE_URL=http://127.0.0.1:3741 EV_PARTNER_KEY_FILE=<file>] \
  deno run -A tests/event_valet/devserver.ts
```
- `http://127.0.0.1:8790/event-valet/...` — the `event-valet` handler (SMS mode **mock**). Binds all interfaces:
  the Android emulator reaches it at **`http://10.0.2.2:8790/event-valet`**.
- `http://127.0.0.1:8789/` — pages from `dist/` (run `sh vercel-build.sh` first to refresh `dist/`).
  - backup staff page: `/events/watermakers-veterans-2026/staff#k=<LINK token>`
  - admin page: `/events/watermakers-veterans-2026/admin` (log in as `localadmin@airvalet.local`, password in `pw.txt`)
  - customer pass: `/events/watermakers-veterans-2026/t#<guest token>`
- `:8791` fake printer (legacy Halloween page only).

## 3. Credentials for local testing

```sh
sh tests/event_valet/mint_local_keys.sh <scratchpad>/watermakers-local
```
Turns Watermakers `staff_access_enabled` ON locally and writes two raw 43-char tokens (valid 7 days):
- `av_device.key` — **DEVICE** "LOCAL S710" (hook pool 01–40) → Android `local.properties` `AV_DEVICE_KEY`
- `av_link.key` — **LINK** "LOCAL phone" (hook pool 41–50) → backup staff page `#k=`

Android `local.properties` (emulator): `AV_API_BASE=http://10.0.2.2:8790/event-valet`, `AV_EVENT_ID=watermakers-veterans-2026`.

Note: `tests/event_valet/edge_s710_test.ts` tears down to "all switches OFF" (it turns
`staff_access_enabled` off at the end). Re-run the mint script (or
`update event_valet_events set staff_access_enabled=true where id='watermakers-veterans-2026'`) before an Android E2E.

Useful local switches (as postgres):
```sql
update event_valet_events set sms_enabled=true, sms_test_only=false, thanks_enabled=true, sms_replies_enabled=true,
       tip_enabled=true where id='watermakers-veterans-2026';      -- mock SMS rows only, nothing is sent
```

## 4. Quick smoke (curl)

```sh
B=http://127.0.0.1:8790/event-valet/staff; KEY=$(cat <dir>/av_device.key)
S=$(curl -s -XPOST $B/session -H "x-ev-key: $KEY" -H 'content-type: application/json' -d '{"name":"Carlos"}' | jq -r .sessionId)
curl -s "$B/state?pending=0" -H "x-ev-key: $KEY" -H "x-ev-session: $S" | jq .counts
curl -s -XPOST $B/checkin -H "x-ev-key: $KEY" -H "x-ev-session: $S" -H 'content-type: application/json' \
  -d '{"clientKey":"smoke-0001","phone":"9545550101","vehicle":{"color":"Black","make":"BMW"},"location":"FRONT","keyStoredAt":"'$(date -u +%FT%TZ)'"}' | jq .ticket.hook
```

## 5. Tests

| Suite | Command | Last result (2026-11-05) |
|---|---|---|
| S710 staff/admin SQL | `docker exec -i supabase_db_airvalet-sms-local psql -U postgres -v ON_ERROR_STOP=1 -v admin=7ee4a46f-f40e-454a-a68c-fda9deb7c662 -v ipad=b8d4fc9b-4dca-4cb0-92f9-5f1476281e98 -qtA < tests/event_valet/sql_tests_s710.sql` | 79/79 |
| S710 concurrency | `sh tests/event_valet/race_s710.sh` | 37 parallel → 35 cars, 35 distinct hooks, pools respected, 2 phone refusals |
| S710 edge | `EV_SERVICE_KEY_FILE=… EV_ANON_KEY_FILE=… EV_PW_FILE=… deno test -A --no-check tests/event_valet/edge_s710_test.ts` | 17/17 |
| Watermakers SQL (updated to 50 hooks) | `… -v ipad=… < tests/event_valet/sql_tests_watermakers.sql` | 17/17 |
| Halloween SQL (regression) | `… -v ipad=… -v tv=849c93a5-3c89-4255-b6a4-567d52b40a1f < tests/event_valet/sql_tests.sql` | 62/62 |
| Halloween race (regression) | `sh tests/event_valet/race_test.sh b8d4fc9b-…` | 20/20 |
| Halloween edge (regression) | `… deno test -A --no-check tests/event_valet/edge_test.ts` | 16/16 |
| AirValet shared SMS (regression, twilio-inbound) | `deno test -A --no-check supabase/functions/_shared/sms/sms.test.ts` | 75/75 |
