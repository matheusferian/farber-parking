# Static check of 20261115_airvalet_guest_edit.sql: the only writes are
#   - the two new tables (airvalet_guest_profiles, airvalet_guest_changes);
#   - INSERT into activity_log (audit line);
#   - UPDATE public.passengers of the operational columns car / color / return_flight /
#     departure_time / obs only (never name, phone, ret, status, tip, payment columns).
# No TRUNCATE / ALTER / DELETE on existing tables; no indexes on existing tables.
#   python3 tests/portal/static_1115_check.py migrations/20261115_airvalet_guest_edit.sql
import re, sys
src = open(sys.argv[1]).read()
NEW = ('airvalet_guest_profiles', 'airvalet_guest_changes')
OPS = {'car', 'color', 'return_flight', 'departure_time', 'obs'}
fails = []
code = re.sub(r'--[^\n]*', '', src)
bodies = '\n'.join(re.findall(r'\$\$(.*?)\$\$', code, re.S))
top = re.sub(r'\$\$.*?\$\$', '$$', code, flags=re.S)
allsql = top + '\n' + bodies
for m in re.finditer(r'\b(insert\s+into|update|delete\s+from|truncate|alter\s+table)\s+(?:only\s+)?(?:if\s+exists\s+)?public\.(\w+)', allsql, re.I):
    verb, t = m.group(1).lower().split()[0], m.group(2)
    if t in NEW: continue
    if verb == 'insert' and t == 'activity_log': continue
    if verb == 'update' and t == 'passengers': continue
    fails.append('%s public.%s' % (m.group(1), t))
# every UPDATE of passengers: only operational columns
for m in re.finditer(r'update\s+public\.passengers\s+set\s+(.*?)\s+where', allsql, re.I | re.S):
    cols = set(re.findall(r'(?:^|,)\s*(\w+)\s*=', m.group(1)))
    dyn = 'format(' in m.group(1) or '%I' in m.group(1)
    bad = cols - OPS
    if bad and not dyn: fails.append('passengers columns written: %s' % sorted(bad))
# dynamic UPDATE (format %I): the column must come from the allow-list guard
if re.search(r"update\s+public\.passengers\s+set\s+%I", allsql, re.I):
    if not re.search(r"array\['car',\s*'color',\s*'return_flight',\s*'departure_time',\s*'obs'\]", allsql):
        fails.append('dynamic passengers update without the 5-column allow-list')
for m in re.finditer(r'create\s+(?:unique\s+)?index[^;]*?\son\s+public\.(\w+)', top, re.I):
    if m.group(1) not in NEW: fails.append('index on existing table ' + m.group(1))
writes = sorted(set(re.findall(r'\b(?:insert\s+into|update|delete\s+from)\s+public\.(\w+)', allsql, re.I)))
print('tables written:', writes)
for f in fails: print('FAIL', f)
print('static check:', 'PASSED' if not fails else 'FAILED'); sys.exit(1 if fails else 0)
