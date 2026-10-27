# LOCAL ONLY (2026-10-26). Alerts card: an ADMIN phone with alerts on can turn
# on "Every new check-in" / "Every Stripe tip"; an iPad login never sees them.
# Reminder categories: ADMIN 7 (incl. "No return date"), iPad / iPhone 6, TV none;
# saved per device, kept after reopening, reverted when the save fails (offline).
# The browser has no real push service here, so an active subscription is
# simulated in the page and its row is created in the local database.
#   APP=http://127.0.0.1:8786/ python3 tests/portal/e2e_staff_alerts_browser.py <scratch portal dir> [engine]
import asyncio, os, subprocess, sys
from playwright.async_api import async_playwright

DIR = sys.argv[1]; ENGINE = sys.argv[2] if len(sys.argv) > 2 else 'chromium'
APP = os.environ.get('APP', 'http://127.0.0.1:8786/')
PW = open(DIR + '/test_password.txt').read().strip()
oks, fails = 0, 0
def sql(q):
    r = subprocess.run(['docker', 'exec', '-i', 'supabase_db_airvalet-portal-local', 'psql', '-U', 'postgres', '-d', 'postgres', '-qAt', '-c', q], capture_output=True, text=True)
    if r.returncode: raise RuntimeError(r.stderr)
    return r.stdout.strip()
def check(c, m, e=''):
    global oks, fails
    if c: oks += 1; print('ok  ', f'[{ENGINE}]', m)
    else: fails += 1; print('FAIL', f'[{ENGINE}]', m, e)

FAKE_PUSH = """() => {
  if (!('PushManager' in window)) window.PushManager = function () {};       // headless WebKit has no Push API (iOS 16.4+ home-screen app has it)
  if (!('Notification' in window)) window.Notification = { permission: 'granted', requestPermission: async () => 'granted' };
  const fake = { pushManager: { getSubscription: async () => ({ endpoint: 'https://web.push.apple.com/e2e', toJSON: () => ({}) }) } };
  Object.defineProperty(navigator.serviceWorker, 'ready', { get: () => Promise.resolve(fake), configurable: true });
  Object.defineProperty(Notification, 'permission', { get: () => 'granted', configurable: true });
}"""

async def session(b, user, vp=(820, 1180), register=True):
    ctx = await b.new_context(viewport={'width': vp[0], 'height': vp[1]}); page = await ctx.new_page(); errs = []
    page.on('pageerror', lambda e: errs.append(str(e)))
    await page.goto(APP); await page.wait_for_selector('#loginEmail', state='visible', timeout=20000); await page.wait_for_timeout(1500)
    await page.fill('#loginEmail', user); await page.fill('#loginPwd', PW); await page.press('#loginPwd', 'Enter')
    await page.wait_for_function('typeof _currentUserRole !== "undefined" && !!_currentUserRole && Array.isArray(data)', timeout=30000)
    if not register:
        await page.evaluate(FAKE_PUSH); return ctx, page, errs, None
    key = await page.evaluate("""async () => { const k = smsDeviceKey(true);
      await smsApi('/rest/v1/rpc/airvalet_sms_device_request', { method: 'POST', body: JSON.stringify({ p_device_key: k, p_label: 'E2E ALERTS', p_user_agent: 'e2e' }) });
      await resolveSmsProvider(); return k; }""")
    sql("insert into public.airvalet_push_subs (device_id, endpoint, p256dh, auth, show_preview) select d.id, 'https://web.push.apple.com/e2e-' || substr(md5(random()::text),1,12), repeat('p', 87), repeat('a', 22), true from public.airvalet_sms_devices d where d.key_hash = public.airvalet_sms_device_key_hash('%s')" % key)
    sql("update public.airvalet_portal_settings set push_enabled = true")
    await page.evaluate(FAKE_PUSH)
    return ctx, page, errs, key

async def card(page):
    await page.evaluate("renderVpAlertsCard()"); await page.wait_for_timeout(1500)
    await page.evaluate("(() => { const d = document.querySelector('#vpAlertsCard details'); if (d) d.open = true; document.getElementById('vpAlertsCard').style.display = ''; })()")

def cats(key):
    return sql("select array_to_string(reminder_categories, ',') from public.airvalet_push_subs s join public.airvalet_sms_devices d on d.id = s.device_id where d.key_hash = public.airvalet_sms_device_key_hash('%s') and s.revoked_at is null" % key)
async def boxes(page):
    return await page.evaluate("Array.from(document.querySelectorAll('#vpaRem input[data-cat]')).map(i => i.getAttribute('data-cat') + (i.checked ? '+' : '-'))")
async def tap(page, cat):
    await page.evaluate("document.querySelector('#vpaRem input[data-cat=\"%s\"]').click()" % cat); await page.wait_for_timeout(1200)

async def main():
    sql("delete from public.airvalet_push_subs where endpoint like 'https://web.push.apple.com/e2e-%'")
    async with async_playwright() as pw:
        kw = {'executable_path': os.environ['WEBKIT_PATH']} if ENGINE == 'webkit' and os.environ.get('WEBKIT_PATH') else {}
        b = await getattr(pw, ENGINE).launch(**kw)
        # ADMIN phone
        ctx, page, errs, key = await session(b, 'localadmin')
        await card(page)
        check(await page.locator('#vpaCheckin').count() == 1 and await page.locator('#vpaTip').count() == 1, 'ADMIN with alerts on: sees "Every new check-in" and "Every Stripe tip"')
        check(not await page.evaluate("document.getElementById('vpaCheckin').checked") and not await page.evaluate("document.getElementById('vpaTip').checked"), 'both start off')
        await page.evaluate("document.getElementById('vpaCheckin').click()"); await page.wait_for_timeout(1200)
        flags = sql("select notify_checkins || '|' || notify_tips || '|' || cardinality(reminder_categories) from public.airvalet_push_subs s join public.airvalet_sms_devices d on d.id = s.device_id where d.key_hash = public.airvalet_sms_device_key_hash('%s') and s.revoked_at is null" % key)
        check(flags == 'true|false|0', 'tap "Every new check-in" → saved for this phone only (tips / reminders untouched)', flags)
        await page.evaluate("document.getElementById('vpaTip').click()"); await page.wait_for_timeout(1200)
        await page.reload(); await page.wait_for_function('typeof _currentUserRole !== "undefined" && !!_currentUserRole', timeout=30000)
        await page.evaluate(FAKE_PUSH); await card(page)
        check(await page.evaluate("document.getElementById('vpaCheckin').checked") and await page.evaluate("document.getElementById('vpaTip').checked"), 'after reopening the app both stay on (read from the server)')
        await page.evaluate("document.getElementById('vpaCheckin').click()"); await page.wait_for_timeout(1200)
        flags = sql("select notify_checkins || '|' || notify_tips from public.airvalet_push_subs s join public.airvalet_sms_devices d on d.id = s.device_id where d.key_hash = public.airvalet_sms_device_key_hash('%s') and s.revoked_at is null" % key)
        check(flags == 'false|true', 'turning check-ins off keeps tips on', flags)
        b0 = await boxes(page)
        check(len(b0) == 8 and 'NODATE_ADMIN-' in b0 and 'CARWASH_ADMIN-' in b0 and all(x.endswith('-') for x in b0), 'ADMIN: 8 reminder choices incl. "No return date" and "Car wash 3 days before", all off', b0)
        await tap(page, 'CARWASH'); await tap(page, 'CARWASH_ADMIN'); await tap(page, 'NODATE_ADMIN')
        check(cats(key) == 'CARWASH,CARWASH_ADMIN,NODATE_ADMIN', 'ADMIN: car wash (incl. 3 days before) + no-return-date saved for this phone', cats(key))
        await page.reload(); await page.wait_for_function('typeof _currentUserRole !== "undefined" && !!_currentUserRole', timeout=30000)
        await page.evaluate(FAKE_PUSH); await card(page)
        b1 = await boxes(page)
        check('CARWASH+' in b1 and 'CARWASH_ADMIN+' in b1 and 'NODATE_ADMIN+' in b1 and 'DAILY-' in b1, 'after reopening, the reminder choices are read back from the server', b1)
        await page.context.set_offline(True)
        await tap(page, 'DAILY')
        b2 = await boxes(page)
        await page.context.set_offline(False)
        check('DAILY-' in b2 and cats(key) == 'CARWASH,CARWASH_ADMIN,NODATE_ADMIN', 'offline: the tap is reverted and nothing changes on the server', (b2, cats(key)))
        check(not errs, 'ADMIN: no page errors', errs[:3])
        await ctx.close()
        # iPad login
        ctx, page, errs, key = await session(b, 'localipad')
        await card(page)
        check(await page.locator('#vpaCheckin').count() == 0 and await page.locator('#vpaTip').count() == 0, 'iPad login never sees the admin alerts')
        r = await page.evaluate("vpRpc('airvalet_push_alerts_set', { p_device_key: smsDeviceKey(false), p_kind: 'TIP', p_on: true })")
        check(r.get('result') == 'FORBIDDEN', 'iPad login calling the server directly: refused', r)
        b0 = await boxes(page)
        check(len(b0) == 6 and not any(x.startswith(('NODATE_ADMIN', 'CARWASH_ADMIN')) for x in b0), 'iPad: 6 reminder choices, no admin-only one', b0)
        for c in ['CARWASH', 'FOLLOWUP', 'CUSTOMS', 'WELCOME_BACK', 'POSITION', 'DAILY']: await tap(page, c)
        check(cats(key) == 'CARWASH,CUSTOMS,DAILY,FOLLOWUP,POSITION,WELCOME_BACK', 'iPad: all operational reminders saved', cats(key))
        r = await page.evaluate("vpRpc('airvalet_push_reminders_set', { p_device_key: smsDeviceKey(false), p_categories: ['NODATE_ADMIN'] })")
        check(r.get('result') == 'FORBIDDEN' and cats(key).startswith('CARWASH'), 'iPad calling the server for the admin-only reminder: refused, nothing changed', r)
        await tap(page, 'FOLLOWUP')
        check(cats(key) == 'CARWASH,CUSTOMS,DAILY,POSITION,WELCOME_BACK', 'iPad: one reminder off, the others stay', cats(key))
        check(not errs, 'iPad: no page errors', errs[:3])
        await ctx.close()
        # iPhone login, phone screen
        ctx, page, errs, key = await session(b, 'localiphone', (390, 844))
        await card(page)
        b0 = await boxes(page)
        check(len(b0) == 6 and not any(x.startswith(('NODATE_ADMIN', 'CARWASH_ADMIN')) for x in b0) and await page.locator('#vpaCheckin').count() == 0, 'iPhone: 6 reminder choices, no admin alerts', b0)
        await tap(page, 'CARWASH'); await tap(page, 'FOLLOWUP')
        check(cats(key) == 'CARWASH,FOLLOWUP', 'iPhone: car wash + follow-up saved', cats(key))
        wide = await page.evaluate("document.documentElement.scrollWidth <= window.innerWidth + 1")
        check(wide, 'iPhone 390 px: no sideways scroll with the reminder list open')
        await page.evaluate('vpOpenMessages()'); await card(page); await page.locator('#vpAlertsCard').scroll_into_view_if_needed(); await page.locator('#vpAlertsCard').screenshot(path=DIR + '/alerts_card_iphone_%s.png' % ENGINE)
        check(not errs, 'iPhone: no page errors', errs[:3])
        await ctx.close()
        # TV login
        ctx, page, errs, key = await session(b, 'localtv', register=False)
        await card(page)
        check(await page.locator('#vpaRem').count() == 0, 'TV: no reminder choices')
        check(not errs, 'TV: no page errors', errs[:3])
        await ctx.close(); await b.close()
    sql("delete from public.airvalet_push_subs where endpoint like 'https://web.push.apple.com/e2e-%'")
    print('%d passed, %d failed' % (oks, fails))
asyncio.run(main())
