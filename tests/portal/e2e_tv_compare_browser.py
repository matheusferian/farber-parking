# LOCAL ONLY (2026-10-26). Same data, two apps side by side: the TV-pending fix
# must give EXACTLY the same Leaving Today / Leaving Tomorrow lists (same cars,
# same order) as the version before it, count only passed / missing / uncertain
# returns as pending (never a confirmed future date) and never list a car twice.
#   BASE_APP=http://127.0.0.1:8781/ NEW_APP=http://127.0.0.1:8784/ python3 tests/portal/e2e_tv_compare_browser.py <scratch portal dir> [engine]
import asyncio, os, subprocess, sys, datetime
from playwright.async_api import async_playwright

DIR = sys.argv[1]; ENGINE = sys.argv[2] if len(sys.argv) > 2 else 'chromium'
BASE = os.environ.get('BASE_APP', 'http://127.0.0.1:8781/'); NEW = os.environ.get('NEW_APP', 'http://127.0.0.1:8784/')
PW = open(DIR + '/test_password.txt').read().strip()
TAG = 'E2E TVC ' + ENGINE[:2].upper() + ' '
oks, fails = 0, 0
def sql(q):
    r = subprocess.run(['docker', 'exec', '-i', 'supabase_db_airvalet-portal-local', 'psql', '-U', 'postgres', '-d', 'postgres', '-qAt', '-c', q], capture_output=True, text=True)
    if r.returncode: raise RuntimeError(r.stderr)
    return r.stdout.strip()
def check(c, m, e=''):
    global oks, fails
    if c: oks += 1; print('ok  ', f'[{ENGINE}]', m)
    else: fails += 1; print('FAIL', f'[{ENGINE}]', m, e)
def d(n):
    x = datetime.date.today() + datetime.timedelta(days=n); return '%d/%d/%d' % (x.month, x.day, x.year)
CASES = [  # key, status, ret, obs, departure time
    ('T1', 'PENDING', d(0), '', '18:30'), ('T2', 'PENDING', d(0), '', '09:15'), ('T3', 'PENDING', d(0), '', ''),
    ('TDEL', 'DELIVERED', d(0), '', '10:00'), ('M1', 'PENDING', d(1), '', '07:00'), ('M2', 'PENDING', d(1), '', ''),
    ('APXT', 'NO DATE', d(0), 'APPROX DATE', ''), ('APXM', 'NO DATE', d(1), 'APPROX DATE', ''),
    ('F3', 'PENDING', d(3), '', ''), ('F30', 'PENDING', d(30), '', ''),
    ('P1', 'PENDING', d(-1), '', ''), ('P9', 'PENDING', d(-9), '', ''), ('NDP', 'PENDING', '', '', ''),
    ('ND', 'NO DATE', '', '', ''), ('NDPAST', 'NO DATE', d(-4), 'APPROX DATE', ''), ('GARBAGE', 'PENDING', 'soon', '', ''),
    ('ARCH', 'ARCHIVED', d(0), '', ''), ('DELOLD', 'DELIVERED', d(-2), '', ''),
]
def seed():
    sql("delete from passengers where name like 'E2E TVC %'")
    vals = ','.join("('%s%s','3055550000','C-%d','%s','%s','HANGAR 19','TEST CAR','%s','MAKERS',now(),%s)" % (TAG, k, i, st, ret, obs, ("'%s'" % dep) if dep else 'null')
                    for i, (k, st, ret, obs, dep) in enumerate(CASES))
    sql("insert into passengers (name, phone, ticket, status, ret, loc, car, obs, return_operator, checkin_date, departure_time) values " + vals)
VM = """(() => { const vm = buildTvViewModel(); const k = r => (r.name||'').replace(%r, ''); const mine = xs => xs.filter(r => (r.name||'').indexOf(%r) === 0).map(k);
  return { today: mine(vm.leavingTodayRemaining), todayDel: mine(vm.leavingTodayDelivered || []), tmrw: mine(vm.leavingTomorrow), fu: mine(vm.followUp), kpi: vm.followUp.length }; })()""" % (TAG, TAG)
async def view(b, app, user):
    ctx = await b.new_context(viewport={'width': 1366, 'height': 900}, service_workers='block'); page = await ctx.new_page(); errs = []
    page.on('pageerror', lambda e: errs.append(str(e)))
    await page.goto(app); await page.wait_for_selector('#loginEmail', state='visible', timeout=20000); await page.wait_for_timeout(1500)
    await page.fill('#loginEmail', user); await page.fill('#loginPwd', PW); await page.press('#loginPwd', 'Enter')
    await page.wait_for_function('typeof data !== "undefined" && Array.isArray(data) && data.some(r => (r.name||"").indexOf(%r) === 0)' % TAG, timeout=30000)
    if user == 'localtv': await page.evaluate("refreshTvData()")
    await page.wait_for_timeout(1200)
    v = await page.evaluate(VM); await ctx.close(); return v, errs
async def main():
    seed()
    async with async_playwright() as pw:
        kw = {'executable_path': os.environ['WEBKIT_PATH']} if ENGINE == 'webkit' and os.environ.get('WEBKIT_PATH') else {}
        b = await getattr(pw, ENGINE).launch(**kw)
        for user in ('localipad', 'localtv'):
            old, e1 = await view(b, BASE, user); new, e2 = await view(b, NEW, user)
            check(old['today'] == new['today'] and old['todayDel'] == new['todayDel'], '%s: Leaving Today identical to the previous version (same cars, same order)' % user, [old['today'], new['today']])
            check(old['tmrw'] == new['tmrw'], '%s: Leaving Tomorrow identical to the previous version' % user, [old['tmrw'], new['tmrw']])
            fu = set(new['fu'])
            check(not ({'F3', 'F30', 'T1', 'T2', 'T3', 'M1', 'M2'} & fu), '%s: pending never counts a confirmed today / tomorrow / future date' % user, sorted(fu))
            check({'P1', 'P9', 'NDP', 'ND', 'NDPAST', 'GARBAGE'} <= fu, '%s: pending counts passed dates, missing / unreadable dates and NO DATE' % user, sorted(fu))
            check(not ({'TDEL', 'ARCH', 'DELOLD'} & fu), '%s: delivered / archived never pending' % user, sorted(fu))
            added = fu - set(old['fu'])
            check(added == {'P1', 'P9', 'NDP', 'GARBAGE'}, '%s: the fix adds exactly the hidden cars (passed / missing / unreadable PENDING)' % user, sorted(added))
            for name, lst in (('today', new['today']), ('tomorrow', new['tmrw']), ('pending', new['fu'])):
                check(len(lst) == len(set(lst)), '%s: no car twice in %s' % (user, name), lst)
            check(not (set(new['today']) & set(new['tmrw'])), '%s: no car in both Today and Tomorrow' % user)
            both = (set(new['today']) | set(new['tmrw'])) & fu
            check(both == (set(old['today']) | set(old['tmrw'])) & set(old['fu']), '%s: Today/Tomorrow ∩ pending unchanged from before (only legacy APPROX cars, as today)' % user, sorted(both))
            check(not e1 and not e2, '%s: no page errors' % user, (e1 + e2)[:3])
        await b.close()
    sql("delete from passengers where name like 'E2E TVC %'")
    print('%d passed, %d failed' % (oks, fails))
asyncio.run(main())
