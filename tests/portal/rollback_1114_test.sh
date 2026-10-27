#!/bin/bash
# LOCAL ONLY: 20261114 apply → rollback → re-apply ×2 → rollback ×2 (twice), schema fingerprint must match;
# the Valet Pass view must stay the production (v86) md5; staff data survives the safe rollback; the SQL tests pass on top.
#   bash tests/portal/rollback_1113_test.sh
set -u
W="$(cd "$(dirname "$0")/../.." && pwd)/migrations"; T="$(cd "$(dirname "$0")" && pwd)"
DB="docker exec -i supabase_db_airvalet-portal-local psql -U postgres -d postgres -v ON_ERROR_STOP=1 -q"
PROD_VIEW_MD5=38c00516d1971a855a04b5d68ad63b45
FP="select md5(string_agg(x, '|' order by x)) from (
  select 'f:' || p.oid::regprocedure::text || ':' || md5(pg_get_functiondef(p.oid)) || ':' || coalesce((select string_agg(a::text, ',' order by a::text) from unnest(p.proacl) a), '')  /* ACL order-insensitive */ x
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.prokind = 'f'
  union all select 'c:' || table_name || '.' || column_name || ':' || data_type || ':' || coalesce(column_default, '') || ':' || is_nullable from information_schema.columns where table_schema = 'public'
  union all select 'k:' || conrelid::regclass || '.' || conname || ':' || pg_get_constraintdef(oid) from pg_constraint where connamespace = 'public'::regnamespace
  union all select 'g:' || grantee || ':' || table_name || '.' || column_name || ':' || privilege_type from information_schema.column_privileges where table_schema = 'public'
  union all select 'i:' || indexname || ':' || indexdef from pg_indexes where schemaname = 'public'
  union all select 'p:' || tablename || '.' || policyname from pg_policies where schemaname = 'public'
  union all select 't:' || tgrelid::regclass || '.' || tgname from pg_trigger where not tgisinternal) s"
fp() { echo "$FP" | $DB -tA 2>&1 | tail -1; }
FPR="select x from (
  select 'f:' || p.oid::regprocedure::text || ':' || md5(pg_get_functiondef(p.oid)) || ':' || coalesce((select string_agg(a::text, ',' order by a::text) from unnest(p.proacl) a), '')  /* ACL order-insensitive */ x
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.prokind = 'f'
  union all select 'c:' || table_name || '.' || column_name || ':' || data_type || ':' || coalesce(column_default, '') || ':' || is_nullable from information_schema.columns where table_schema = 'public'
  union all select 'k:' || conrelid::regclass || '.' || conname || ':' || pg_get_constraintdef(oid) from pg_constraint where connamespace = 'public'::regnamespace
  union all select 'g:' || grantee || ':' || table_name || '.' || column_name || ':' || privilege_type from information_schema.column_privileges where table_schema = 'public'
  union all select 'i:' || indexname || ':' || indexdef from pg_indexes where schemaname = 'public'
  union all select 'p:' || tablename || '.' || policyname from pg_policies where schemaname = 'public'
  union all select 't:' || tgrelid::regclass || '.' || tgname from pg_trigger where not tgisinternal) s order by 1"
fpr() { echo "$FPR" | $DB -tA 2>&1; }
vmd5() { echo "select md5(pg_get_functiondef('public.airvalet_portal_view(text,text)'::regprocedure))" | $DB -tA; }
pass=0; fail=0; ck() { if [ "$1" = "$2" ]; then pass=$((pass+1)); echo "ok   $3"; else fail=$((fail+1)); echo "FAIL $3 ($1 vs $2)"; fi; }
apply() { $DB < "$W/$1.sql" > /dev/null 2>&1 || { echo "  FAILED $1"; $DB < "$W/$1.sql" 2>&1 | grep ERROR; fail=$((fail+1)); }; }

# Existing data must never change: tickets, tips, payments, history, Closing, SMS, pass links, settings.
SEED="insert into public.passengers (id, ts, checkin_date, name, phone, ticket, status, ret, loc, car, color, obs, tip_received, checkout_date) values
  (981480, 'x', now() - interval '5 days', 'DATA KEEP ONE', '3055557480', 'DK-1', 'DELIVERED', '1/1/2031', 'HANGAR 19', 'BMW', 'Black', 'note', true, now() - interval '1 day'),
  (981481, '6/4/2025 8:04:49', null, 'MRS DATA KEEP', '0000000000', 'DK-2', 'ARCHIVED', '6/9/2025', 'HANGAR 18', 'Kia', 'Gray', null, null, null);
insert into public.activity_log (ts, action, passenger, ticket, location, detail, passenger_id, changed_by) values ('x', 'EDITED', 'DATA KEEP ONE', 'DK-1', 'H', 'seed', 981480, 'seed');
insert into public.passenger_return_date_changes (passenger_id, passenger_name, ticket, old_return_date, new_return_date, comment, changed_by) values (981480, 'DATA KEEP ONE', 'DK-1', '1/1/2031', '1/2/2031', 'seed change', 'seed');
insert into public.payments (passenger_id, ticket, amount_cents, type, method, status, stripe_event_id) values (981480, 'DK-1', 700, 'TIP', 'STRIPE', 'succeeded', 'evt_dk_1');
select set_config('airvalet.tip_ledger', '1', false);
insert into public.airvalet_tip_records (passenger_id, ticket, amount_cents, source, business_date, recorded_by) values (981480, 'DK-1', 900, 'DELIVERY', '2031-01-01', 'seed');"
UNSEED="select set_config('airvalet.tip_ledger', '1', false); delete from public.airvalet_tip_records where ticket = 'DK-1'; delete from public.payments where stripe_event_id = 'evt_dk_1';
delete from public.passenger_return_date_changes where passenger_id = 981480; delete from public.activity_log where passenger_id = 981480; delete from public.passengers where id in (981480, 981481);"
DATA_FP="select md5(string_agg(t || ':' || h, '|' order by t)) from (
  select 'passengers' t, md5(coalesce(string_agg(x::text, '' order by x.id), '')) h from public.passengers x
  union all select 'tip_records', md5(coalesce(string_agg(x::text, '' order by x.id), '')) from public.airvalet_tip_records x
  union all select 'payments', md5(coalesce(string_agg(x::text, '' order by x.id), '')) from public.payments x
  union all select 'activity_log', md5(coalesce(string_agg(x::text, '' order by x.id), '')) from public.activity_log x
  union all select 'return_changes', md5(coalesce(string_agg(x::text, '' order by x.id), '')) from public.passenger_return_date_changes x
  union all select 'location_history', md5(coalesce(string_agg(x::text, '' order by x.id), '')) from public.vehicle_location_history x
  union all select 'closing', md5(coalesce(string_agg(x::text, '' order by x.id), '')) from public.daily_closing_reports x
  union all select 'sms', md5(coalesce(string_agg(x::text, '' order by x.id), '')) from public.airvalet_sms_messages x
  union all select 'pass_links', md5(coalesce(string_agg(x::text, '' order by x.id), '')) from public.airvalet_pass_links x
  union all select 'portal_settings', md5(coalesce(string_agg(x::text, ''), '')) from public.airvalet_portal_settings x) s"
dfp() { echo "$DATA_FP" | $DB -tA 2>&1 | tail -1; }
apply 20261114_airvalet_guests_rollback          # start from production (idempotent)
echo "$UNSEED" | $DB > /dev/null 2>&1; echo "$SEED" | $DB > /dev/null
ck "$(echo "select (select count(*) from public.passengers where id in (981480, 981481)) || '|' || (select count(*) from public.payments where stripe_event_id = 'evt_dk_1') || '|' || (select count(*) from public.airvalet_tip_records where ticket = 'DK-1') || '|' || (select count(*) from public.passenger_return_date_changes where passenger_id = 981480)" | $DB -tA)" "2|1|1|1" "seed data in place (tickets, Stripe tip, cash tip, return change)"
D0=$(dfp)
BASE=$(fp); ck "$(vmd5)" "$PROD_VIEW_MD5" "baseline: portal_view = production definition"
apply 20261114_airvalet_guests; A1=$(fp)
ck "$(dfp)" "$D0" "apply: tickets, tips, payments, history, Closing, SMS, pass links, settings unchanged"; A1R=$(fpr)
[ "$A1" != "$BASE" ] && { pass=$((pass+1)); echo "ok   apply changes the schema"; } || { fail=$((fail+1)); echo "FAIL apply changed nothing"; }
for round in 1 2; do
  apply 20261114_airvalet_guests_rollback; ck "$(fp)" "$BASE" "round $round: rollback → identical to baseline"
  ck "$(vmd5)" "$PROD_VIEW_MD5" "round $round: portal_view back to the production md5"
  apply 20261114_airvalet_guests; apply 20261114_airvalet_guests; ck "$(fp)" "$A1" "round $round: re-apply ×2 → identical to first apply"
  apply 20261114_airvalet_guests_rollback; apply 20261114_airvalet_guests_rollback; ck "$(fp)" "$BASE" "round $round: rollback ×2 → identical to baseline"
  apply 20261114_airvalet_guests
done
# ── With staff data: the full rollback refuses; the SAFE rollback keeps every note and decision ──
DATA="insert into public.passengers (id, ts, checkin_date, name, phone, ticket, status, ret) values
  (981490, 'x', now(), 'RB GUEST', '3055557490', 'RB-G1', 'PENDING', '3/20/2031'), (981491, 'x', now(), 'RB GUESTT', '3055557491', 'RB-G2', 'PENDING', '3/20/2031');
insert into public.airvalet_guest_notes (guest_key, body, created_by) values (public.airvalet_guest_auto_key(981490, '3055557490', 'RB GUEST'), 'Keep me', 'rb');
insert into public.airvalet_guest_note_revisions (note_id, action, body, by_user) select id, 'CREATE', body, 'rb' from public.airvalet_guest_notes where body = 'Keep me';
insert into public.airvalet_guest_identity (kind, from_key, to_key, reason, created_by) values ('MERGE', public.airvalet_guest_auto_key(981491, '3055557491', 'RB GUESTT'), public.airvalet_guest_auto_key(981490, '3055557490', 'RB GUEST'), 'rb test', 'rb');"
echo "$DATA" | $DB > /dev/null
KEEP="select (select count(*) from public.airvalet_guest_notes where body = 'Keep me') || '|' || (select count(*) from public.airvalet_guest_note_revisions where body = 'Keep me') || '|' || (select count(*) from public.airvalet_guest_identity where reason = 'rb test')"
K0=$(echo "$KEEP" | $DB -tA); ck "$K0" "1|1|1" "data in place (1 note, 1 revision, 1 merge decision)"
D1=$(dfp)
OUTD=$($DB < "$W/20261114_airvalet_guests_rollback.sql" 2>&1); echo "$OUTD" | grep -q "refused: 1 guest notes and 1 identity decisions" && { pass=$((pass+1)); echo "ok   full rollback REFUSES while notes / decisions exist"; } || { fail=$((fail+1)); echo "FAIL full rollback did not refuse: $OUTD"; }
apply 20261114_airvalet_guests_rollback_safe
ck "$(vmd5)" "$PROD_VIEW_MD5" "safe rollback: Valet Pass view = production v86 definition"
ck "$(echo "$KEEP" | $DB -tA)" "$K0" "safe rollback: notes, revisions and decisions kept"
ck "$(echo "$DATA_FP" | $DB -tA | tail -1)" "$D1" "safe rollback: existing data still unchanged"
ck "$(echo "select count(*) from pg_proc where proname like 'airvalet_guest_%'" | $DB -tA)" "0" "safe rollback: no guest function left"
ck "$(echo "select count(*) from pg_indexes where indexname like 'passengers_guest_%'" | $DB -tA)" "0" "safe rollback: expression indexes gone"
apply 20261114_airvalet_guests; ck "$(fp)" "$A1" "re-apply after the safe rollback → identical to the first apply"
ck "$(echo "$KEEP" | $DB -tA)" "$K0" "re-apply: data still there"
ck "$(echo "select count(*) from public.airvalet_guest_members(public.airvalet_guest_auto_key(981490, '3055557490', 'RB GUEST'))" | $DB -tA)" "2" "re-apply: the kept merge decision works again (2 tickets, one guest)"
echo "delete from public.airvalet_guest_note_revisions where body = 'Keep me'; delete from public.airvalet_guest_notes where body = 'Keep me'; delete from public.airvalet_guest_identity where reason = 'rb test';
delete from public.passengers where id in (981490, 981491);" | $DB > /dev/null

OUT=$( (echo '\set ON_ERROR_STOP 1'; echo 'begin;'; cat "$T/sql_guests_1114_tests.sql"; echo 'rollback;') | docker exec -i supabase_db_airvalet-portal-local psql -U postgres -d postgres 2>&1)
echo "$OUT" | grep -q "all 1114 checks passed" && { pass=$((pass+1)); echo "ok   SQL tests on the applied migration ($(echo "$OUT" | grep -c 'NOTICE:  ok') checks)"; } || { fail=$((fail+1)); echo "FAIL SQL tests"; echo "$OUT" | grep -E "ERROR|FAIL" | head -3; }
ck "$(dfp)" "$D0" "end of all cycles: existing data identical to the start"
echo "$UNSEED" | $DB > /dev/null
echo; echo "$pass ok, $fail failed"; [ $fail -eq 0 ]
