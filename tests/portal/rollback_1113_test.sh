#!/bin/bash
# LOCAL ONLY: 20261113 apply → rollback → re-apply ×2 → rollback ×2 (twice), schema fingerprint must match;
# airvalet_portal_view must come back to the production md5 after rollback; the SQL tests pass on top.
#   bash tests/portal/rollback_1113_test.sh
set -u
W="$(cd "$(dirname "$0")/../.." && pwd)/migrations"; T="$(cd "$(dirname "$0")" && pwd)"
DB="docker exec -i supabase_db_airvalet-portal-local psql -U postgres -d postgres -v ON_ERROR_STOP=1 -q"
PROD_VIEW_MD5=caf314d92eea95c5629754a9679e2646
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

apply 20261113_airvalet_cash_tips_rollback          # start from production (idempotent)
BASE=$(fp); ck "$(vmd5)" "$PROD_VIEW_MD5" "baseline: portal_view = production definition"
apply 20261113_airvalet_cash_tips; A1=$(fp); A1R=$(fpr)
[ "$A1" != "$BASE" ] && { pass=$((pass+1)); echo "ok   apply changes the schema"; } || { fail=$((fail+1)); echo "FAIL apply changed nothing"; }
for round in 1 2; do
  apply 20261113_airvalet_cash_tips_rollback; ck "$(fp)" "$BASE" "round $round: rollback → identical to baseline"
  ck "$(vmd5)" "$PROD_VIEW_MD5" "round $round: portal_view back to the production md5"
  apply 20261113_airvalet_cash_tips; apply 20261113_airvalet_cash_tips; ck "$(fp)" "$A1" "round $round: re-apply ×2 → identical to first apply"
  apply 20261113_airvalet_cash_tips_rollback; apply 20261113_airvalet_cash_tips_rollback; ck "$(fp)" "$BASE" "round $round: rollback ×2 → identical to baseline"
  apply 20261113_airvalet_cash_tips
done
# ── With financial data: the full rollback refuses; the SAFE rollback keeps every record ──
DATA="insert into public.passengers (id, ts, checkin_date, name, phone, ticket, status, ret, checkout_date) values
  (971390, 'x', now(), 'RB KEEP', '3055557390', 'RB-1', 'DELIVERED', '3/20/2031', '2031-03-20 15:00-04');
select set_config('airvalet.tip_ledger', '1', false);
insert into public.airvalet_tip_records (passenger_id, ticket, amount_cents, source, business_date, recorded_by) values (971390, 'RB-1', 4200, 'DELIVERY', '2031-03-20', 'rb-test');
update public.passengers set tip_in_person_cents = 4200, tip_received = true where id = 971390;
insert into public.daily_closing_reports (report_date, stripe_tips_cents, cash_counted_cents) values ('2031-03-20', 0, 5000);"
echo "$DATA" | $DB > /dev/null
KEEP="select (select count(*) || ':' || sum(amount_cents) from public.airvalet_tip_records where ticket = 'RB-1') || '|' ||
             (select cash_counted_cents || ':' || ticket_cash_tips_cents || ':' || other_tips_cents || ':' || cash_reconciliation from public.daily_closing_reports where report_date = '2031-03-20') || '|' ||
             (select tip_in_person_cents from public.passengers where id = 971390)"
K0=$(echo "$KEEP" | $DB -tA); ck "$K0" "1:4200|5000:4200:800:OTHER_TIPS|4200" "data in place (ledger \$42, closing B \$50 → Other \$8)"
OUTD=$($DB < "$W/20261113_airvalet_cash_tips_rollback.sql" 2>&1); echo "$OUTD" | grep -q "refused: 1 tip ledger rows and 1 closing" && { pass=$((pass+1)); echo "ok   full rollback REFUSES while financial records exist"; } || { fail=$((fail+1)); echo "FAIL full rollback did not refuse: $OUTD"; }
ck "$(echo "$KEEP" | $DB -tA)" "$K0" "after the refused full rollback: records intact"
apply 20261113_airvalet_cash_tips_rollback_safe
ck "$(vmd5)" "$PROD_VIEW_MD5" "safe rollback: portal_view = production definition"
ck "$(echo "$KEEP" | $DB -tA)" "$K0" "safe rollback: every financial record kept"
ck "$(echo "select count(*) from pg_trigger where tgname in ('trg_dcr_cash_reconcile', 'airvalet_tip_legacy_capture')" | $DB -tA)" "0" "safe rollback: both triggers off (v85 behaviour)"
ck "$(echo "select has_function_privilege('authenticated', 'public.airvalet_tip_record(bigint,integer,uuid,text,text)', 'execute') or has_function_privilege('authenticated', 'public.airvalet_tip_correct(bigint,integer,text,uuid)', 'execute') or has_function_privilege('authenticated', 'public.airvalet_cash_tips_for_date(date)', 'execute')" | $DB -tA)" "f" "safe rollback: staff cannot call the ledger functions"
ck "$(echo "select has_table_privilege('authenticated', 'public.airvalet_tip_records', 'select')" | $DB -tA)" "t" "safe rollback: staff can still read the ledger"
apply 20261113_airvalet_cash_tips_rollback_safe; ck "$(echo "$KEEP" | $DB -tA)" "$K0" "safe rollback twice: still kept"
apply 20261113_airvalet_cash_tips; ck "$(fp)" "$A1" "re-apply after the safe rollback → identical to the first apply"; [ "$(fp)" = "$A1" ] || diff <(echo "$A1R") <(fpr) | cut -c1-240 | head -8
ck "$(echo "$KEEP" | $DB -tA)" "$K0" "re-apply: records still there"
echo "delete from public.daily_closing_reports where report_date = '2031-03-20'; delete from public.airvalet_tip_records where ticket = 'RB-1';
select set_config('airvalet.tip_ledger', '1', false); update public.passengers set tip_in_person_cents = null where id = 971390;
delete from public.activity_log where passenger_id = 971390; delete from public.passengers where id = 971390;" | $DB > /dev/null

OUT=$( (echo '\set ON_ERROR_STOP 1'; echo 'begin;'; cat "$T/sql_cash_tips_1113_tests.sql"; echo 'rollback;') | docker exec -i supabase_db_airvalet-portal-local psql -U postgres -d postgres 2>&1)
echo "$OUT" | grep -q "all 1113 checks passed" && { pass=$((pass+1)); echo "ok   SQL tests on the applied migration ($(echo "$OUT" | grep -c 'NOTICE:  ok') checks)"; } || { fail=$((fail+1)); echo "FAIL SQL tests"; echo "$OUT" | grep -E "ERROR|FAIL" | head -3; }
echo; echo "$pass ok, $fail failed"; [ $fail -eq 0 ]
