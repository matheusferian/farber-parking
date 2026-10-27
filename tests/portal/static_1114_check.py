# Static check of 20261114_airvalet_guests.sql: nothing outside the three new guest tables is
# ever written — no INSERT / UPDATE / DELETE / TRUNCATE / ALTER on existing tables, at the top
# level or inside any function. Indexes on passengers are expression indexes only (no data).
#   python3 tests/portal/static_1114_check.py migrations/20261114_airvalet_guests.sql
import re, sys
src = open(sys.argv[1]).read()
GUEST = ('airvalet_guest_identity', 'airvalet_guest_notes', 'airvalet_guest_note_revisions')
fails = []
code = re.sub(r'--[^\n]*', '', src)
bodies = re.findall(r'\$\$(.*?)\$\$', code, re.S)
top = re.sub(r'\$\$.*?\$\$', '$$', code, flags=re.S)
for m in re.finditer(r'\b(insert\s+into|update|delete\s+from|truncate|alter\s+table)\s+(?:only\s+)?(?:if\s+exists\s+)?public\.(\w+)', top + '\n'.join(bodies), re.I):
    if m.group(2) not in GUEST and not (m.group(1).lower() == 'update' and m.group(2) in GUEST):
        fails.append('%s public.%s' % (m.group(1), m.group(2)))
for m in re.finditer(r'create\s+(unique\s+)?index[^;]*?\son\s+public\.(\w+)\s*\(([^;]*)\);', top, re.I):
    if m.group(2) == 'passengers' and not re.match(r'\s*public\.airvalet_guest_\w+\(', m.group(3)):
        fails.append('non-expression index on passengers: ' + m.group(3))
    elif m.group(2) not in GUEST + ('passengers',):
        fails.append('index on ' + m.group(2))
writes = sorted(set(re.findall(r'\b(?:insert\s+into|update|delete\s+from)\s+public\.(\w+)', '\n'.join(bodies), re.I)))
print('tables written by the migration or its functions:', writes)
print('expression indexes on passengers:', len(re.findall(r'on public\.passengers \(public\.airvalet_guest_', top)))
for f in fails: print('FAIL', f)
print('static check:', 'PASSED' if not fails else 'FAILED'); sys.exit(1 if fails else 0)
