#!/bin/bash
# LOCAL ONLY: concurrent check-ins against the local portal stack DB
# (supabase_db_airvalet-portal-local). Real parallel connections, committed
# rows, cleaned up at start and end (ts = 'deepconc').
#   bash tests/portal/concurrency_checkin.sh
set -u
DB=supabase_db_airvalet-portal-local
docker ps --format '{{.Names}}' | grep -qx "$DB" || { echo "local DB container $DB not running"; exit 2; }
q() { docker exec -i "$DB" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -At "$@"; }
pass=0; fail=0
check() { if [ "$1" = "$2" ]; then pass=$((pass+1)); echo "ok   $3"; else fail=$((fail+1)); echo "FAIL $3 (got '$1', expected '$2')"; fi; }
cleanup() { q -c "delete from public.passengers where ts = 'deepconc'" >/dev/null; }
cleanup; trap cleanup EXIT
MMDD=$(q -c "select to_char((now() at time zone 'America/New_York')::date, 'MMDD')")
N=9500

# 1. 20 devices save the SAME typed ticket at the same moment.
for i in $(seq 1 20); do
  q -c "insert into public.passengers (ts, checkin_date, name, phone, ticket, status) values ('deepconc', now(), 'CONC $i', '30555508$(printf %02d $i)', '$MMDD-$N', 'PENDING')" >/dev/null 2>&1 &
done; wait
check "$(q -c "select count(*) from public.passengers where ts='deepconc' and name like 'CONC %'")" 20 "20 concurrent saves of ticket $MMDD-$N → 20 rows"
check "$(q -c "select count(distinct ticket) from public.passengers where ts='deepconc' and name like 'CONC %'")" 20 "… with 20 distinct tickets (no same-day duplicate)"
check "$(q -c "select count(*) from public.passengers where ts='deepconc' and name like 'CONC %' and ticket = '$MMDD-$N'")" 1 "… exactly one kept the typed number"
check "$(q -c "select max((regexp_match(ticket, '-(\d+)$'))[1]::int) - min((regexp_match(ticket, '-(\d+)$'))[1]::int) from public.passengers where ts='deepconc' and name like 'CONC %'")" 19 "… numbers are consecutive ($N..$((N+19)))"

# 2. Makers and Ascend at the same moment share one sequence.
M=9600
for i in $(seq 1 10); do
  if [ $((i % 2)) = 0 ]; then t="A-$MMDD-$M"; else t="$MMDD-$M"; fi
  q -c "insert into public.passengers (ts, checkin_date, name, phone, ticket, status) values ('deepconc', now(), 'MIX $i', '30555509$(printf %02d $i)', '$t', 'PENDING')" >/dev/null 2>&1 &
done; wait
check "$(q -c "select count(distinct (regexp_match(ticket, '-(\d+)$'))[1]) from public.passengers where ts='deepconc' and name like 'MIX %'")" 10 "10 concurrent Makers/Ascend saves of N=$M → 10 distinct numbers (shared sequence)"
check "$(q -c "select count(*) from public.passengers where ts='deepconc' and name like 'MIX %' and ticket like 'A-%'")" 5 "… Ascend rows keep the A- prefix"

# 3. The same form (same client_key) saved 20 times at once → one row.
CK="ck_deepconc_$(date +%s)_aaaaaaaa"
for i in $(seq 1 20); do
  q -c "insert into public.passengers (ts, checkin_date, name, phone, ticket, status, client_key) values ('deepconc', now(), 'SAMEKEY', '3055550899', '$MMDD-9700', 'PENDING', '$CK')" >/dev/null 2>&1 &
done; wait
check "$(q -c "select count(*) from public.passengers where client_key = '$CK'")" 1 "20 concurrent saves with the same client_key → exactly one row"

# 4. The REST path the app uses (PostgREST insert as a logged-in iPad) with a client_key retry.
API=http://127.0.0.1:56331
ANON=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0
PWF="${PORTAL_SCRATCH:-}/test_password.txt"
if [ -n "${PORTAL_SCRATCH:-}" ] && [ -f "$PWF" ]; then
  JWT=$(curl -s -X POST "$API/auth/v1/token?grant_type=password" -H "apikey: $ANON" -H 'Content-Type: application/json' \
    -d "{\"email\":\"localipad@airvalet.local\",\"password\":\"$(cat "$PWF")\"}" | python3 -c 'import json,sys;print(json.load(sys.stdin)["access_token"])')
  CK2="ck_deepconc_rest_$(date +%s)_bbbbbbbb"
  body="{\"ts\":\"deepconc\",\"checkin_date\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"name\":\"REST KEY\",\"phone\":\"3055550898\",\"ticket\":\"$MMDD-9800\",\"status\":\"PENDING\",\"client_key\":\"$CK2\"}"
  c1=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$API/rest/v1/passengers" -H "apikey: $ANON" -H "Authorization: Bearer $JWT" -H 'Content-Type: application/json' -H 'Prefer: return=representation' -d "$body")
  r2=$(curl -s -w ' HTTP%{http_code}' -X POST "$API/rest/v1/passengers" -H "apikey: $ANON" -H "Authorization: Bearer $JWT" -H 'Content-Type: application/json' -H 'Prefer: return=representation' -d "$body")
  check "$c1" 201 "REST insert as IPAD_OPS → 201"
  check "$(echo "$r2" | grep -c passengers_client_key_unique)" 1 "REST retry with the same client_key → refused with passengers_client_key_unique (app then loads the first row)"
  check "$(q -c "select count(*) from public.passengers where client_key = '$CK2'")" 1 "… still one row"
else
  echo "skip REST client_key check (set PORTAL_SCRATCH to the scratch portal dir)"
fi

echo; echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
