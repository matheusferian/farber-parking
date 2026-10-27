#!/bin/bash
# LOCAL ONLY: 20261115 apply → safe rollback → re-apply (twice). v87 search / profile / lookup must come
# back byte-identical (production md5); corrections survive the safe rollback; the full rollback refuses
# with data; existing data never changes; the SQL tests pass on top.   bash tests/portal/rollback_1115_test.sh
set -u
W="$(cd "$(dirname "$0")/../.." && pwd)/migrations"; T="$(cd "$(dirname "$0")" && pwd)"
DB="docker exec -i supabase_db_airvalet-portal-local psql -U postgres -d postgres -v ON_ERROR_STOP=1 -q"
V87="airvalet_guest_search=ac426f37381fbe2e759094df831504cf airvalet_guest_profile=b5865ff59f1d99829b06047f89834478 airvalet_guest_lookup_phone=f1fdc77b00d673751df700fc8ece8a2f"
pass=0; fail=0; ck() { if [ "$1" = "$2" ]; then pass=$((pass+1)); echo "ok   $3"; else fail=$((fail+1)); echo "FAIL $3 ($1 vs $2)"; fi; }
apply() { $DB < "$W/$1.sql" > /dev/null 2>&1 || { echo "  FAILED $1"; $DB < "$W/$1.sql" 2>&1 | grep ERROR; fail=$((fail+1)); }; }
v87md5() { for f in airvalet_guest_search airvalet_guest_profile airvalet_guest_lookup_phone; do echo -n "$f=$(echo "select md5(pg_get_functiondef(p.oid) || chr(10)) from pg_proc p where proname = '$f'" | $DB -tA) "; done | sed 's/ $//'; }
FP="select md5(string_agg(x, '|' order by x)) from (
  select 'f:' || p.oid::regprocedure::text || ':' || md5(pg_get_functiondef(p.oid)) || ':' || coalesce((select string_agg(a::text, ',' order by a::text) from unnest(p.proacl) a), '') x
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.prokind = 'f'
  union all select 'c:' || table_name || '.' || column_name || ':' || data_type from information_schema.columns where table_schema = 'public'
  union all select 'i:' || indexname from pg_indexes where schemaname = 'public'
  union all select 'p:' || tablename || '.' || policyname from pg_policies where schemaname = 'public') s"
fp() { echo "$FP" | $DB -tA | tail -1; }
DATA="select md5(string_agg(t, '|' order by t)) from (
  select md5(coalesce(string_agg(x::text, '' order by x.id), '')) t from public.passengers x
  union all select md5(coalesce(string_agg(x::text, '' order by x.id), '')) from public.payments x
  union all select md5(coalesce(string_agg(x::text, '' order by x.id), '')) from public.airvalet_tip_records x
  union all select md5(coalesce(string_agg(x::text, '' order by x.id), '')) from public.activity_log x
  union all select md5(coalesce(string_agg(x::text, '' order by x.id), '')) from public.airvalet_pass_links x
  union all select md5(coalesce(string_agg(x::text, '' order by x.id), '')) from public.daily_closing_reports x
  union all select md5(coalesce(string_agg(x::text, '' order by x.id), '')) from public.airvalet_sms_messages x) s"
dfp() { echo "$DATA" | $DB -tA | tail -1; }

apply 20261115_airvalet_guest_edit_rollback_safe
ck "$(v87md5)" "$V87" "baseline: search / profile / lookup = production v87 definitions"
BASE=$(fp); D0=$(dfp)
apply 20261115_airvalet_guest_edit; A1=$(fp)
ck "$(dfp)" "$D0" "apply: existing data unchanged"
for round in 1 2; do
  apply 20261115_airvalet_guest_edit_rollback_safe
  ck "$(v87md5)" "$V87" "round $round: safe rollback → v87 functions byte-identical"
  apply 20261115_airvalet_guest_edit; apply 20261115_airvalet_guest_edit; ck "$(fp)" "$A1" "round $round: re-apply ×2 → identical"
done
# with corrections saved
echo "insert into public.airvalet_guest_profiles (guest_key, display_name, phone, updated_by) values ('rb:test', 'RB NAME', '3055550101', 'rb');
insert into public.airvalet_guest_changes (action_key, guest_key, field, old_value, new_value, changed_by) values (gen_random_uuid(), 'rb:test', 'guest_name', 'A', 'RB NAME', 'rb');" | $DB > /dev/null
OUT=$($DB < "$W/20261115_airvalet_guest_edit_rollback.sql" 2>&1); echo "$OUT" | grep -q "refused: 1 corrected guests and 1 change records" && { pass=$((pass+1)); echo "ok   full rollback REFUSES while corrections exist"; } || { fail=$((fail+1)); echo "FAIL full rollback: $OUT"; }
apply 20261115_airvalet_guest_edit_rollback_safe
ck "$(echo "select count(*) from public.airvalet_guest_profiles where guest_key = 'rb:test'" | $DB -tA)|$(echo "select count(*) from public.airvalet_guest_changes where guest_key = 'rb:test'" | $DB -tA)" "1|1" "safe rollback keeps corrections and their history"
ck "$(v87md5)" "$V87" "safe rollback with data: v87 functions byte-identical"
apply 20261115_airvalet_guest_edit; ck "$(fp)" "$A1" "re-apply after the safe rollback → identical"
echo "delete from public.airvalet_guest_changes where guest_key = 'rb:test'; delete from public.airvalet_guest_profiles where guest_key = 'rb:test';" | $DB > /dev/null
ck "$(dfp)" "$D0" "end: existing data identical to the start"
OUT=$( (echo '\set ON_ERROR_STOP 1'; echo 'begin;'; cat "$T/sql_guest_edit_1115_tests.sql"; echo 'rollback;') | docker exec -i supabase_db_airvalet-portal-local psql -U postgres -d postgres 2>&1)
echo "$OUT" | grep -q "all 1115 checks passed" && { pass=$((pass+1)); echo "ok   1115 SQL tests ($(echo "$OUT" | grep -c 'NOTICE:  ok') checks)"; } || { fail=$((fail+1)); echo "FAIL 1115 SQL tests"; echo "$OUT" | grep -E "ERROR|FAIL" | head -3; }
OUT=$( (echo '\set ON_ERROR_STOP 1'; echo 'begin;'; cat "$T/sql_guests_1114_tests.sql"; echo 'rollback;') | docker exec -i supabase_db_airvalet-portal-local psql -U postgres -d postgres 2>&1)
echo "$OUT" | grep -q "all 1114 checks passed" && { pass=$((pass+1)); echo "ok   v87 (1114) SQL tests still pass on top ($(echo "$OUT" | grep -c 'NOTICE:  ok') checks)"; } || { fail=$((fail+1)); echo "FAIL 1114 SQL tests on top"; echo "$OUT" | grep -E "ERROR|FAIL" | head -3; }
echo; echo "$pass ok, $fail failed"; [ $fail -eq 0 ]
