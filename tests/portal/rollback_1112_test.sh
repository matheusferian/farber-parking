#!/bin/bash
# LOCAL ONLY: 20261112 apply → rollback → re-apply ×2 → rollback ×2 (twice), schema fingerprint must match;
# airvalet_portal_view must come back to the production md5 after rollback. Also runs the SQL tests
# on top of 20261107 (abuse limits, not in production yet) inside a rolled-back transaction.
#   bash tests/portal/rollback_1112_test.sh
set -u
W="$(cd "$(dirname "$0")/../.." && pwd)/migrations"; T="$(cd "$(dirname "$0")" && pwd)"
DB="docker exec -i supabase_db_airvalet-portal-local psql -U postgres -d postgres -v ON_ERROR_STOP=1 -q"
PROD_VIEW_MD5=95b3d51697fcfcf963dfffa0655a88f5
FP="select md5(string_agg(x, '|' order by x)) from (
  select 'f:' || p.oid::regprocedure::text || ':' || md5(pg_get_functiondef(p.oid)) || ':' || coalesce(array_to_string(p.proacl, ','), '') x
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.prokind = 'f'
  union all select 'c:' || table_name || '.' || column_name || ':' || data_type || ':' || coalesce(column_default, '') || ':' || is_nullable from information_schema.columns where table_schema = 'public'
  union all select 'k:' || conrelid::regclass || '.' || conname || ':' || pg_get_constraintdef(oid) from pg_constraint where connamespace = 'public'::regnamespace
  union all select 'g:' || grantee || ':' || table_name || '.' || column_name || ':' || privilege_type from information_schema.column_privileges where table_schema = 'public'
  union all select 't:' || tgrelid::regclass || '.' || tgname from pg_trigger where not tgisinternal) s"
fp() { echo "$FP" | $DB -tA 2>&1 | tail -1; }
vmd5() { echo "select md5(pg_get_functiondef('public.airvalet_portal_view(text,text)'::regprocedure))" | $DB -tA; }
pass=0; fail=0; ck() { if [ "$1" = "$2" ]; then pass=$((pass+1)); echo "ok   $3"; else fail=$((fail+1)); echo "FAIL $3 ($1 vs $2)"; fi; }
apply() { $DB < "$W/$1.sql" > /dev/null 2>&1 || { echo "  FAILED $1"; $DB < "$W/$1.sql" 2>&1 | grep ERROR; fail=$((fail+1)); }; }

apply 20261112_airvalet_pass_gratuity_rollback          # start from production (idempotent)
BASE=$(fp); ck "$(vmd5)" "$PROD_VIEW_MD5" "baseline: portal_view = production definition"
apply 20261112_airvalet_pass_gratuity; A1=$(fp)
[ "$A1" != "$BASE" ] && { pass=$((pass+1)); echo "ok   apply changes the schema"; } || { fail=$((fail+1)); echo "FAIL apply changed nothing"; }
for round in 1 2; do
  apply 20261112_airvalet_pass_gratuity_rollback; ck "$(fp)" "$BASE" "round $round: rollback → identical to baseline"
  ck "$(vmd5)" "$PROD_VIEW_MD5" "round $round: portal_view back to the production md5"
  apply 20261112_airvalet_pass_gratuity; apply 20261112_airvalet_pass_gratuity; ck "$(fp)" "$A1" "round $round: re-apply ×2 → identical to first apply"
  apply 20261112_airvalet_pass_gratuity_rollback; apply 20261112_airvalet_pass_gratuity_rollback; ck "$(fp)" "$BASE" "round $round: rollback ×2 → identical to baseline"
  apply 20261112_airvalet_pass_gratuity
done
# SQL tests with 20261107 underneath (rolled back: the local DB keeps its current state)
OUT=$( (echo '\set ON_ERROR_STOP 1'; echo 'begin;'; sed '/^begin;$/d;/^commit;$/d' "$W/20261112_airvalet_pass_gratuity_rollback.sql";
  sed '/^begin;$/d;/^commit;$/d;/^set local lock_timeout/d' "$W/20261107_airvalet_portal_abuse_limits.sql"; sed '/^begin;$/d;/^commit;$/d' "$W/20261112_airvalet_pass_gratuity.sql";
  cat "$T/sql_pass_gratuity_1112_tests.sql"; echo 'rollback;') | docker exec -i supabase_db_airvalet-portal-local psql -U postgres -d postgres 2>&1)
echo "$OUT" | grep -q "all 1112 checks passed" && { pass=$((pass+1)); echo "ok   SQL tests also pass on top of 20261107 ($(echo "$OUT" | grep -c 'NOTICE:  ok') checks)"; } || { fail=$((fail+1)); echo "FAIL SQL tests on top of 1107"; echo "$OUT" | grep -E "ERROR|FAIL" | head -3; }
ck "$(echo "select to_regclass('public.airvalet_pass_rate_long') is null" | $DB -tA)" "t" "1107 left unapplied locally (as in production)"
echo; echo "$pass ok, $fail failed"; [ $fail -eq 0 ]
