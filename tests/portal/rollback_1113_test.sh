#!/bin/bash
# LOCAL ONLY: 20261113 apply → rollback → re-apply ×2 → rollback ×2 (twice), schema fingerprint must match;
# airvalet_portal_view must come back to the production md5 after rollback; the SQL tests pass on top.
#   bash tests/portal/rollback_1113_test.sh
set -u
W="$(cd "$(dirname "$0")/../.." && pwd)/migrations"; T="$(cd "$(dirname "$0")" && pwd)"
DB="docker exec -i supabase_db_airvalet-portal-local psql -U postgres -d postgres -v ON_ERROR_STOP=1 -q"
PROD_VIEW_MD5=caf314d92eea95c5629754a9679e2646
FP="select md5(string_agg(x, '|' order by x)) from (
  select 'f:' || p.oid::regprocedure::text || ':' || md5(pg_get_functiondef(p.oid)) || ':' || coalesce(array_to_string(p.proacl, ','), '') x
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.prokind = 'f'
  union all select 'c:' || table_name || '.' || column_name || ':' || data_type || ':' || coalesce(column_default, '') || ':' || is_nullable from information_schema.columns where table_schema = 'public'
  union all select 'k:' || conrelid::regclass || '.' || conname || ':' || pg_get_constraintdef(oid) from pg_constraint where connamespace = 'public'::regnamespace
  union all select 'g:' || grantee || ':' || table_name || '.' || column_name || ':' || privilege_type from information_schema.column_privileges where table_schema = 'public'
  union all select 'i:' || indexname || ':' || indexdef from pg_indexes where schemaname = 'public'
  union all select 'p:' || tablename || '.' || policyname from pg_policies where schemaname = 'public'
  union all select 't:' || tgrelid::regclass || '.' || tgname from pg_trigger where not tgisinternal) s"
fp() { echo "$FP" | $DB -tA 2>&1 | tail -1; }
vmd5() { echo "select md5(pg_get_functiondef('public.airvalet_portal_view(text,text)'::regprocedure))" | $DB -tA; }
pass=0; fail=0; ck() { if [ "$1" = "$2" ]; then pass=$((pass+1)); echo "ok   $3"; else fail=$((fail+1)); echo "FAIL $3 ($1 vs $2)"; fi; }
apply() { $DB < "$W/$1.sql" > /dev/null 2>&1 || { echo "  FAILED $1"; $DB < "$W/$1.sql" 2>&1 | grep ERROR; fail=$((fail+1)); }; }

apply 20261113_airvalet_cash_tips_rollback          # start from production (idempotent)
BASE=$(fp); ck "$(vmd5)" "$PROD_VIEW_MD5" "baseline: portal_view = production definition"
apply 20261113_airvalet_cash_tips; A1=$(fp)
[ "$A1" != "$BASE" ] && { pass=$((pass+1)); echo "ok   apply changes the schema"; } || { fail=$((fail+1)); echo "FAIL apply changed nothing"; }
for round in 1 2; do
  apply 20261113_airvalet_cash_tips_rollback; ck "$(fp)" "$BASE" "round $round: rollback → identical to baseline"
  ck "$(vmd5)" "$PROD_VIEW_MD5" "round $round: portal_view back to the production md5"
  apply 20261113_airvalet_cash_tips; apply 20261113_airvalet_cash_tips; ck "$(fp)" "$A1" "round $round: re-apply ×2 → identical to first apply"
  apply 20261113_airvalet_cash_tips_rollback; apply 20261113_airvalet_cash_tips_rollback; ck "$(fp)" "$BASE" "round $round: rollback ×2 → identical to baseline"
  apply 20261113_airvalet_cash_tips
done
OUT=$( (echo '\set ON_ERROR_STOP 1'; echo 'begin;'; cat "$T/sql_cash_tips_1113_tests.sql"; echo 'rollback;') | docker exec -i supabase_db_airvalet-portal-local psql -U postgres -d postgres 2>&1)
echo "$OUT" | grep -q "all 1113 checks passed" && { pass=$((pass+1)); echo "ok   SQL tests on the applied migration ($(echo "$OUT" | grep -c 'NOTICE:  ok') checks)"; } || { fail=$((fail+1)); echo "FAIL SQL tests"; echo "$OUT" | grep -E "ERROR|FAIL" | head -3; }
echo; echo "$pass ok, $fail failed"; [ $fail -eq 0 ]
