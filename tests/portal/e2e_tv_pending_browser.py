# LOCAL ONLY (2026-10-26). Active cars never vanish: a passed / missing return
# date goes to the TV "Return Follow-Up" count + page and to the Day view
# "Return passed — not delivered" list, while Today / Tomorrow stay exactly as
# before and future cars stay off the TV. Fictional data, mock SMS.
#   python3 tests/portal/e2e_tv_pending_browser.py <scratch portal dir> [engine]
import asyncio, os, subprocess, sys, time, datetime
from playwright.async_api import async_playwright

DIR = sys.argv[1]
ENGINE = sys.argv[2] if len(sys.argv) > 2 else 'chromium'
APP = os.environ.get('TVP_APP', 'http://127.0.0.1:8781/')
PW = open(DIR + '/test_password.txt').read().strip()
TAG = 'E2E TVP ' + ENGINE[:2].upper() + ' '
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
    x = datetime.date.today() + datetime.timedelta(days=n)
    return '%d/%d/%d' % (x.month, x.day, x.year)


CASES = [  # key, status, ret, obs
    ('PAST15', 'PENDING', d(-15), ''), ('PAST1', 'PENDING', d(-1), ''), ('NODATEP', 'PENDING', '', ''),
    ('NODATE', 'NO DATE', '', ''), ('TODAY', 'PENDING', d(0), ''), ('TMRW', 'PENDING', d(1), ''),
    ('FUTURE', 'PENDING', d(5), ''), ('DELIV', 'DELIVERED', d(-3), ''), ('ARCH', 'ARCHIVED', d(-20), ''),
]


def seed():
    sql("delete from passengers where name like 'E2E TVP %'")
    vals = ','.join("('%s%s', '3055550000', 'T-%d', '%s', '%s', 'HANGAR 19', 'TEST CAR', '%s', 'MAKERS', now())" % (TAG, k, i, st, ret, obs) for i, (k, st, ret, obs) in enumerate(CASES))
    sql("insert into passengers (name, phone, ticket, status, ret, loc, car, obs, return_operator, checkin_date) values " + vals)


async def login(page, user):
    await page.goto(APP)
    await page.wait_for_selector('#loginEmail', state='visible', timeout=20000)
    await page.wait_for_timeout(1500)
    await page.fill('#loginEmail', user); await page.fill('#loginPwd', PW); await page.press('#loginPwd', 'Enter')
    await page.wait_for_function('typeof data !== "undefined" && Array.isArray(data) && data.some(r => (r.name||"").indexOf(%r) === 0)' % TAG, timeout=30000)
    await page.wait_for_timeout(1000)


VM = """(() => { const vm = buildTvViewModel(); const n = r => r.name.replace(%r, '');
  return { today: vm.leavingTodayRemaining ? vm.leavingTodayRemaining.map(n) : [], tmrw: vm.leavingTomorrow.map(n), fu: vm.followUp.map(n),
           chips: Object.fromEntries(vm.followUp.map(r => [n(r), tvFollowUpChip(r).text])) }; })()""" % TAG


async def main():
    seed()
    async with async_playwright() as pw:
        kw = {'executable_path': os.environ['WEBKIT_PATH']} if ENGINE == 'webkit' and os.environ.get('WEBKIT_PATH') else {}
        b = await getattr(pw, ENGINE).launch(**kw)
        for user in ('localipad', 'localtv'):
            ctx = await b.new_context(viewport={'width': 1366, 'height': 900}, service_workers='block')
            page = await ctx.new_page(); errs = []
            page.on('pageerror', lambda e: errs.append(str(e)))
            await login(page, user)
            if user == 'localtv':
                await page.evaluate("typeof refreshTvData === 'function' ? refreshTvData() : null"); await page.wait_for_timeout(1500)
            v = await page.evaluate(VM)
            keys = set(k for k, _, _, _ in CASES); mine = lambda xs: sorted(x for x in xs if x in keys)
            fu, today, tmrw = mine(v['fu']), mine(v['today']), mine(v['tmrw'])
            check(set(['PAST15', 'PAST1', 'NODATEP', 'NODATE']) <= set(fu), '%s: passed / missing dates are in Return Follow-Up' % user, fu)
            check(not set(['TODAY', 'TMRW', 'FUTURE', 'DELIV', 'ARCH']) & set(fu), '%s: today / tomorrow / future / delivered / archived are NOT in Follow-Up' % user, fu)
            check(today == ['TODAY'] and tmrw == ['TMRW'], '%s: Leaving Today / Tomorrow unchanged (no passed or future cars added)' % user, [today, tmrw])
            check('FUTURE' not in today + tmrw + fu, '%s: a car returning in 5 days stays off the TV' % user)
            check(v['chips'].get('PAST15', '').startswith('RETURN PASSED — WAS'), '%s: passed date chip says RETURN PASSED — WAS <date>' % user, v['chips'].get('PAST15'))
            check(v['chips'].get('NODATEP') == 'NO DATE — FOLLOW UP', '%s: PENDING without a date: NO DATE — FOLLOW UP' % user, v['chips'].get('NODATEP'))
            if user == 'localipad':
                await page.evaluate("typeof renderDay === 'function' ? renderDay() : null"); await page.wait_for_timeout(500)
                t = await page.text_content('#titleForgot'); body = await page.text_content('#dForgot')
                check('Return passed' in t and TAG + 'PAST15' in body and TAG + 'PAST1' in body, 'Day view: every passed return date is listed (15 days and yesterday)', t)
                check(TAG + 'TODAY' not in body and TAG + 'FUTURE' not in body and TAG + 'DELIV' not in body, 'Day view: today / future / delivered not in that list')
            check(not errs, '%s: no page errors' % user, errs[:3])
            await ctx.close()
        await b.close()
    sql("delete from passengers where name like 'E2E TVP %'")
    print('%d passed, %d failed' % (oks, fails))

asyncio.run(main())
