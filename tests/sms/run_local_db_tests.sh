#!/bin/sh
# LOCAL ONLY. Spins up throwaway Supabase Postgres containers. Never points at
# a real Supabase project.
#  Phase A — Return/Pickup release: prod-baseline fixture + prod-like rows,
#            ONLY the release migrations (no SMS/Twilio objects), apply →
#            rollback → re-apply, then the release tests.
#  Phase B — full set (SMS + Return/Pickup + pass links + SMS review view),
#            apply → rollback → re-apply, SQL tests, concurrency, integration.
set -eu
cd "$(dirname "$0")/../.."

IMAGE=public.ecr.aws/supabase/postgres:17.11.0.004
REL_MIGS="migrations/20261010_add_passenger_return_operator.sql migrations/20261010_tv_mode_rpc_return_operator.sql"
REL_RBS="migrations/20261010_tv_mode_rpc_return_operator_rollback.sql migrations/20261010_add_passenger_return_operator_rollback.sql"
MIGS="migrations/20261010_add_passenger_return_operator.sql migrations/20261010_tv_mode_rpc_return_operator.sql migrations/20261009_create_airvalet_sms_messages.sql migrations/20261010_create_airvalet_pass_links.sql migrations/20261011_return_reviews_include_sms.sql migrations/20261012_airvalet_sms_audit.sql"
RBS="migrations/20261012_airvalet_sms_audit_rollback.sql migrations/20261011_return_reviews_include_sms_rollback.sql migrations/20261010_create_airvalet_pass_links_rollback.sql migrations/20261009_create_airvalet_sms_messages_rollback.sql migrations/20261010_tv_mode_rpc_return_operator_rollback.sql migrations/20261010_add_passenger_return_operator_rollback.sql"

NAME=""
cleanup() { [ -n "$NAME" ] && docker rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT
start_db() {
  cleanup
  NAME=airvalet_sms_test_db_$$_$1
  docker run -d --name "$NAME" -e POSTGRES_PASSWORD=postgres -p 127.0.0.1::5432 "$IMAGE" >/dev/null
  i=0; until docker exec "$NAME" pg_isready -U postgres -h localhost >/dev/null 2>&1; do
    i=$((i+1)); [ $i -gt 60 ] && { echo 'db did not start'; exit 1; }; sleep 2; done
  sleep 3
}
admin() { docker exec -i "$NAME" psql -U supabase_admin -h localhost -d postgres -v ON_ERROR_STOP=1 -q "$@"; }
pg()    { docker exec -i "$NAME" psql -U postgres -h localhost -v ON_ERROR_STOP=1 -q "$@"; }

# ── Phase A: Return/Pickup release only ─────────────────────────────────
start_db rel
admin < tests/sms/fixture_prod_baseline.sql
pg < tests/sms/release_seed_pre_migration.sql
for m in $REL_MIGS; do pg < "$m"; done
for r in $REL_RBS; do pg < "$r"; done
for m in $REL_MIGS; do pg < "$m"; done
echo 'release migrations (2, no SMS): apply → rollback → re-apply OK'
out=$(pg < tests/sms/release_return_pickup_tests.sql 2>&1 || true)
printf '%s\n' "$out" | grep -E 'NOTICE|ERROR|RELEASE_TESTS' | sed -e 's/^psql:<stdin>:[0-9]*: //' -e 's/^NOTICE:  //'
printf '%s\n' "$out" | grep -q '^RELEASE_TESTS_PASSED' || { echo 'FAIL: release tests did not complete'; exit 1; }

# ── Phase B: full set ───────────────────────────────────────────────────
start_db full
admin < tests/sms/fixture_prod_baseline.sql
for m in $MIGS; do pg < "$m"; done
# Data written while installed must SURVIVE a rollback (A2P record keeping):
pg -q <<'SQL'
insert into public.passengers (id, name, phone, ticket, status) values (4401, 'Keep Me', '3055554401', 'K-1', 'PENDING');
insert into public.airvalet_sms_consents (phone_e164, passenger_id, status, method, disclosure_version) values ('+13055554401', 4401, 'granted', 'checkin_attendant', 'keep-v1');
insert into public.airvalet_sms_opt_outs (phone_e164, opted_out, last_keyword, source) values ('+13055554402', true, 'STOP', 'inbound_sms');
insert into public.airvalet_sms_messages (direction, passenger_id, phone_e164, message_type, provider, status, idempotency_key, body)
  values ('outbound', 4401, '+13055554401', 'CHECK_IN', 'mock', 'delivered', 'keep:1', 'kept body');
insert into public.airvalet_sms_status_events (provider_message_sid, status) values ('SM_KEEP', 'delivered');
insert into public.airvalet_sms_devices (id, key_hash, label, status) values ('00000000-0000-0000-0000-00000000dddd', public.airvalet_sms_device_key_hash('keep_device_key_kkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkk'), 'Keep iPad', 'approved');
insert into public.airvalet_sms_enrollments (passenger_id, phone_e164, device_id, consent_id, staff_name)
  select 4401, '+13055554401', '00000000-0000-0000-0000-00000000dddd', id, 'Keep' from public.airvalet_sms_consents where passenger_id = 4401;
select public.airvalet_pass_mint(4401);
SQL
for r in $RBS; do pg < "$r"; done
ctab=$(pg -tA -c "select relname from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'airvalet_archive' and relname like 'airvalet_sms_consents__rb_%' limit 1")
kept=$(pg -tA -c "select count(*) from airvalet_archive.\"$ctab\" where disclosure_version = 'keep-v1'")
tables=$(pg -tA -c "select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='airvalet_archive' and c.relkind='r' and (relname like 'airvalet_sms_%__rb_%' or relname like 'airvalet_pass_links__rb_%')")
anon=$(pg -tA -c "select count(*) from information_schema.role_table_grants where table_schema='airvalet_archive' and grantee in ('anon','authenticated','PUBLIC')")
[ "$kept" = 1 ] && [ "$tables" = 9 ] && [ "$anon" = 0 ] || { echo "FAIL: rollback did not preserve data (consent=$kept tables=$tables anon_grants=$anon)"; exit 1; }
echo 'ok  rollback preserves consents, opt-outs, messages, status audit, devices, enrollments, settings, admin audit trail, link audit (9 archived tables, no anon/authenticated access)'
for m in $MIGS; do pg < "$m"; done
[ "$(pg -tA -c "select count(*) from public.airvalet_sms_messages")" = 0 ] || { echo 'FAIL: re-apply not clean'; exit 1; }
pg -q -c "delete from public.passengers where id = 4401"   # a v46 delete after the rollback…
ltab=$(pg -tA -c "select relname from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'airvalet_archive' and relname like 'airvalet_pass_links__rb_%' limit 1")
mtab=$(pg -tA -c "select relname from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'airvalet_archive' and relname like 'airvalet_sms_messages__rb_%' limit 1")
[ "$(pg -tA -c "select count(*) from airvalet_archive.\"$ltab\" where passenger_id = 4401")" = 1 ] && [ "$(pg -tA -c "select count(*) from airvalet_archive.\"$mtab\" where passenger_id = 4401")" = 1 ] \
  || { echo 'FAIL: deleting a passenger altered the archive'; exit 1; }
echo 'ok  archive independent of live tables: deleting the passenger kept its archived link + message (no FK cascade / set null)'
echo 'migrations (6): apply → rollback (reverse, data archived) → re-apply OK'

out=$(pg < tests/sms/sql_tests.sql 2>&1 || true)
printf '%s\n' "$out" | grep -E 'NOTICE|ERROR|ALL_SQL' | sed -e 's/^psql:<stdin>:[0-9]*: //' -e 's/^NOTICE:  //'
printf '%s\n' "$out" | grep -q '^ALL_SQL_TESTS_PASSED' || { echo 'FAIL: SQL tests did not complete'; exit 1; }

# Concurrency: 20 parallel claims with the SAME key must yield exactly one row
# and exactly one claimed=true (double-tap / client retry / two iPads).
STAFF="'00000000-0000-0000-0000-0000000000a1'"
DEV="public.airvalet_sms_device_key_hash('race_device_key_rrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrr')"
pg -c "update public.airvalet_sms_settings set sending_enabled = true, test_only = false, cutover_at = now() - interval '1 hour', cutover_after_id = 0; insert into public.airvalet_sms_devices (id, key_hash, label, status) values ('00000000-0000-0000-0000-00000000eeee', $DEV, 'Race iPad', 'approved');"
pg -c "insert into public.passengers (id, name, phone, ticket, status) values (2001, 'Race', '3055552001', 'R-1', 'PENDING'); insert into public.airvalet_sms_consents (phone_e164, status, method) values ('+13055552001', 'granted', 'checkin_attendant'); insert into public.airvalet_sms_enrollments (passenger_id, phone_e164, device_id, consent_id) select 2001, '+13055552001', '00000000-0000-0000-0000-00000000eeee', id from public.airvalet_sms_consents where phone_e164 = '+13055552001';"
for n in $(seq 1 20); do
  pg -tA -c "select claimed from public.airvalet_sms_claim('pax:2001:CHECK_IN:checkin', 2001, 'R-1', '+13055552001', 'CHECK_IN', 'CHECK_IN', 'v1', 'b', 1, 'mock', $STAFF, null, null, null, $DEV);" &
done > /tmp/airvalet_sms_race_$$ 2>&1
wait
claimed=$(grep -c '^t$' /tmp/airvalet_sms_race_$$ || true)
rows=$(pg -tA -c "select count(*) from public.airvalet_sms_messages where idempotency_key = 'pax:2001:CHECK_IN:checkin';")
rm -f /tmp/airvalet_sms_race_$$
[ "$claimed" = 1 ] && [ "$rows" = 1 ] || { echo "FAIL: race → claimed=$claimed rows=$rows"; exit 1; }
echo "ok  20 concurrent claims, same key → 1 row, 1 claimed"

# Global daily cap under concurrency: 20 different phones at once, cap leaves
# room for exactly 5 → exactly 5 claimed (global advisory lock, no overshoot).
used=$(pg -tA -c "select count(*) from public.airvalet_sms_messages where direction = 'outbound' and status <> 'blocked' and created_at > now() - interval '24 hours'")
pg -c "update public.airvalet_sms_settings set max_messages_day = $used + 5, max_per_device_hour = 500;"
pg -q -c "insert into public.airvalet_sms_consents (phone_e164, status, method) select '+1305556' || lpad(g::text, 4, '0'), 'granted', 'checkin_attendant' from generate_series(1, 20) g;
  insert into public.passengers (id, name, phone, ticket, status) select 2100 + g, 'Cap', '305556' || lpad(g::text, 4, '0'), 'C-' || g, 'PENDING' from generate_series(1, 20) g;
  insert into public.airvalet_sms_enrollments (passenger_id, phone_e164, device_id, consent_id) select 2100 + g, '+1305556' || lpad(g::text, 4, '0'), '00000000-0000-0000-0000-00000000eeee', (select c.id from public.airvalet_sms_consents c where c.phone_e164 = '+1305556' || lpad(g::text, 4, '0')) from generate_series(1, 20) g;"
for n in $(seq 1 20); do
  pg -tA -c "select claimed from public.airvalet_sms_claim('cap:$n', 2100 + $n, null, '+1305556' || lpad('$n', 4, '0'), 'CHECK_IN', 'CHECK_IN', 'v1', 'b', 1, 'mock', $STAFF, null, null, null, $DEV);" &
done > /tmp/airvalet_sms_cap_$$ 2>&1
wait
capped=$(grep -c '^t$' /tmp/airvalet_sms_cap_$$ || true)
rm -f /tmp/airvalet_sms_cap_$$
[ "$capped" = 5 ] || { echo "FAIL: daily cap under concurrency → claimed=$capped (expected 5)"; exit 1; }
echo "ok  20 concurrent sends vs daily cap with room for 5 → exactly 5 claimed"
pg -c "update public.airvalet_sms_settings set max_messages_day = 300, max_per_device_hour = 40;"

# Service + webhooks end-to-end against this container (needs a host port).
PORT=$(docker port "$NAME" 5432/tcp 2>/dev/null | head -1 | sed 's/.*://')
if [ -n "$PORT" ]; then
  AIRVALET_SMS_TEST_DB_URL="postgres://postgres:postgres@127.0.0.1:$PORT/postgres" \
    deno test --allow-net=127.0.0.1 --allow-env --allow-read --allow-sys tests/sms/db_integration.test.ts
fi
