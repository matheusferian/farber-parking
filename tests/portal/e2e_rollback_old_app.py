# LOCAL ONLY. Rollback rehearsal: the app BEFORE the 2026-10-25 audit deploy
# (main 14e191d, SW v65b) running against the database AFTER it (1104-1106).
# This is what production looks like if the app is rolled back by git and
# the migrations stay. Fictional data only; cleans up after itself.
#   APP_ROOT=<git archive 14e191d> python3 <scratch>/portal/serve_root.py 8783
#   python3 tests/portal/e2e_rollback_old_app.py <scratch portal dir>
import asyncio, subprocess, sys, time
from playwright.async_api import async_playwright

DIR = sys.argv[1]
OLD = 'http://127.0.0.1:8783/'
PW = open(DIR + '/test_password.txt').read().strip()
RUN = str(int(time.time()) % 900 + 100)
TAG = 'E2E RB '
oks, fails = 0, 0


def sql(q):
    r = subprocess.run(['docker', 'exec', '-i', 'supabase_db_airvalet-portal-local', 'psql', '-U', 'postgres', '-d', 'postgres', '-qAt', '-c', q],
                       capture_output=True, text=True)
    if r.returncode:
        raise RuntimeError(r.stderr)
    return r.stdout.strip()


def check(cond, msg, extra=''):
    global oks, fails
    if cond:
        oks += 1; print('ok  ', msg)
    else:
        fails += 1; print('FAIL', msg, extra)


async def guard(route):
    u = route.request.url
    if u.startswith('http://127.0.0.1') or 'fonts.g' in u or 'cdnjs' in u or 'jsdelivr' in u:
        await route.continue_()
    else:
        await route.abort()


async def login(page, user):
    await page.goto(OLD)
    await page.wait_for_selector('#loginEmail', state='visible', timeout=20000)
    for attempt in range(3):
        await page.wait_for_timeout(1500)
        await page.fill('#loginEmail', user); await page.fill('#loginPwd', PW); await page.press('#loginPwd', 'Enter')
        try:
            await page.wait_for_function('typeof _currentUserEmail !== "undefined" && !!_currentUserEmail && Array.isArray(data) && data.length > 0', timeout=20000)
            break
        except Exception:
            if attempt == 2: raise
    await page.wait_for_timeout(1500)
    await page.evaluate('() => { window.epsonSend = async () => true; window.confirm = () => true; window.alert = () => {}; }')


async def main():
    async with async_playwright() as pw:
        b = await pw.chromium.launch()
        ctx = await b.new_context(viewport={'width': 820, 'height': 1180})
        await ctx.route('**/*', guard)
        page = await ctx.new_page()
        errors = []
        page.on('pageerror', lambda e: errors.append(str(e)))
        await login(page, 'localipad')
        sw = await page.evaluate("fetch('./service-worker.js').then(r => r.text()).then(t => (t.match(/CACHE_VERSION = '([^']+)'/) || [])[1])")
        check(sw == 'v65b', 'old app served (SW %s)' % sw)
        n0 = await page.evaluate('data.length')
        check(n0 > 0, 'old app loads the passenger list from the new database', n0)

        # Classic check-in (Save Only).
        await page.evaluate('openAdd()')
        await page.wait_for_selector('#fName', state='visible')
        await page.fill('#fName', TAG + 'CLASSIC')
        await page.fill('#fPhone', '30555' + RUN + '01')
        await page.fill('#fTicket', '97' + RUN)
        await page.evaluate("document.getElementById('fStatus').value = 'NO DATE'; onStatusChange('NO DATE')")
        await page.evaluate('saveEntry(false)')
        await page.wait_for_timeout(3000)
        rows = sql("select id, ticket, status from passengers where name = '%sCLASSIC'" % TAG)
        check(len(rows.splitlines()) == 1, 'old app: classic check-in saved once', rows)
        pid = int(rows.split('|')[0]) if rows else 0

        # Move + deliver (classic delivery path, no pickup authorization).
        await page.evaluate('loadData()'); await page.wait_for_timeout(1500)
        ok = await page.evaluate("deliverWithTip(%d, 'NORMAL', null)" % pid)
        await page.wait_for_timeout(1500)
        st = sql("select status || '|' || coalesce(delivery_type,'') from passengers where id = %d" % pid)
        check(ok is True and st.startswith('DELIVERED'), 'old app: delivery works on the new database', (ok, st))
        dlog = sql("select count(*) from activity_log where passenger_id = %d" % pid)
        check(int(dlog) >= 1, 'old app: history entries are written (activity_log stamp trigger accepts them)', dlog)

        # A car with an authorized pickup (new 1104 columns) cannot be delivered by the old app without the ID check.
        sql("insert into passengers (name, phone, ticket, status, ts, checkin_date) values ('%sPICKUP', '(305) 555-%s02', '96%s', 'NO DATE', 'x', now())" % (TAG, RUN, RUN))
        p2 = int(sql("select id from passengers where name = '%sPICKUP'" % TAG))
        try:
            sql("update passengers set pickup_auth_name = 'E2E OTHER PERSON' where id = %d" % p2)
            has_pickup = True
        except Exception as e:
            has_pickup = False; print('     info: could not set pickup columns:', str(e)[:120])
        if has_pickup:
            await page.evaluate('loadData()'); await page.wait_for_timeout(1500)
            ok2 = await page.evaluate("deliverWithTip(%d, 'NORMAL', null)" % p2)
            await page.wait_for_timeout(1500)
            st2 = sql("select status from passengers where id = %d" % p2)
            check(st2 != 'DELIVERED', 'old app: delivery of an authorized-pickup car is refused by the database (no silent release)', (ok2, st2))
            msg = await page.evaluate("(document.getElementById('msg') || {}).textContent || ''")
            print('     info: old app message after refused delivery:', msg[:160], '| returned', ok2)

        # Closing Report on the iPhone login.
        await page.evaluate('doLogout()'); await page.wait_for_timeout(1500)
        await login(page, 'localiphone')
        vis = await page.evaluate("getComputedStyle(document.querySelector('.tab[data-t=\"closingreport\"]')).display")
        check(vis != 'none', 'old app: Closing Report tab visible on the iPhone login', vis)
        await page.evaluate('crOpenTab()'); await page.wait_for_timeout(3000)
        err = await page.evaluate("getComputedStyle(document.getElementById('crErrorScreen')).display")
        check(err == 'none', 'old app: Closing Report loads on the new database', await page.evaluate("document.getElementById('crErrorMsg').textContent"))

        # A check-in saved offline by the NEW app (record v:3) after rolling back.
        await page.evaluate('''async ([tag, run]) => {
          const r = offlineBuildCheckinRecord({ ts: 'x', checkin_date: new Date().toISOString(), name: tag + 'V3 OFFLINE', phone: '(305) 555-' + run + '3',
             ticket: '95' + run, ret: '', car: '', color: null, loc: '', status: 'NO DATE', block: '', obs: '', deldate: '', client_key: 'ck_rb_' + run });
          r.v = 3; r.sms = { consent: false, auto: true, staff: null }; r.nextAttemptAt = null;
          await offlineCheckinPut(r); await loadData();
        }''', [TAG, RUN])
        await page.reload(); await page.wait_for_timeout(1500)
        if await page.is_visible('#loginEmail'):
            await login(page, 'localiphone')
        await page.wait_for_timeout(4000)
        shown = await page.evaluate("data.filter(r => r.isOfflinePending && String(r.name).includes('V3 OFFLINE')).length")
        check(shown == 1, 'old app: a new-app offline check-in is still shown as PENDING SYNC (not lost)', shown)
        up = int(sql("select count(*) from passengers where name = '%sV3 OFFLINE'" % TAG))
        print('     info: new-app offline record uploaded by the old app:', up, '(old app has no automatic upload)')
        check(not errors, 'old app: no page errors', errors[:3])
        await b.close()

    sql("""do $$ declare r record; begin
      create temp table e2e_ids on commit drop as select id from passengers where name like 'E2E RB %';
      for r in select conrelid::regclass t, a.attname c from pg_constraint k join pg_attribute a on a.attrelid = k.conrelid and a.attnum = any(k.conkey)
               where k.contype = 'f' and k.confrelid = 'public.passengers'::regclass loop
        execute format('delete from %s where %I in (select id from e2e_ids)', r.t, r.c);
      end loop;
      delete from passengers where id in (select id from e2e_ids);
    end $$""")
    sql("delete from activity_log where passenger like 'E2E RB %'")
    print(f'\n{oks} passed, {fails} failed')
    sys.exit(1 if fails else 0)

asyncio.run(main())
