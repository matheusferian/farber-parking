# LOCAL ONLY (2026-10-26). Tapping a push opens AirValet on the right screen:
# staff alerts (check-in / tip / reminder) → Dashboard, guest messages → Messages.
# The real service worker runs; the tap is a real `notificationclick` fired in
# it (Chromium only: WebKit cannot evaluate in a service worker). Also checks
# that a fresh start always lands on Dashboard (Chromium + WebKit).
# A browser is not an iPhone: proof on the device is the owner's tap.
#   APP=http://127.0.0.1:8786/ python3 tests/portal/e2e_push_tap_dashboard_browser.py <scratch portal dir> [engine]
import asyncio, os, sys
from playwright.async_api import async_playwright

DIR = sys.argv[1]; ENGINE = sys.argv[2] if len(sys.argv) > 2 else 'chromium'
APP = os.environ.get('APP', 'http://127.0.0.1:8786/')
PW = open(DIR + '/test_password.txt').read().strip()
oks, fails = 0, 0
def check(c, m, e=''):
    global oks, fails
    if c: oks += 1; print('ok  ', f'[{ENGINE}]', m)
    else: fails += 1; print('FAIL', f'[{ENGINE}]', m, e)

async def login(page, user):
    await page.goto(APP); await page.wait_for_selector('#loginEmail', state='visible', timeout=20000); await page.wait_for_timeout(1200)
    await page.fill('#loginEmail', user); await page.fill('#loginPwd', PW); await page.press('#loginPwd', 'Enter')
    await page.wait_for_function('typeof _currentUserRole !== "undefined" && !!_currentUserRole && Array.isArray(data)', timeout=30000)
    await page.evaluate("navigator.serviceWorker.ready"); await page.wait_for_timeout(500)

async def screen(page):
    return await page.evaluate("(document.querySelector('.tab.on') || {}).dataset ? document.querySelector('.tab.on').dataset.t : null")

async def go(page, t):
    await page.evaluate(f"document.querySelector('.tab[data-t=\"{t}\"]').click()"); await page.wait_for_timeout(300)

async def tap(ctx, url):
    """Fire notificationclick in the real service worker (its real handler runs)."""
    sw = ctx.service_workers[0] if ctx.service_workers else await ctx.wait_for_event('serviceworker', timeout=15000)
    return await sw.evaluate("""async (url) => {
      // Same event the system fires on a tap; the notification object carries the push data.
      const ev = new ExtendableEvent('notificationclick');
      Object.defineProperty(ev, 'notification', { value: { data: { url }, close() {} } });
      let done; ev.waitUntil = (p) => { done = p; };
      self.dispatchEvent(ev); try { await done; } catch (e) { return 'error: ' + e; }
      return 'ok';
    }""", url)

async def main():
    async with async_playwright() as pw:
        kw = {'executable_path': os.environ['WEBKIT_PATH']} if ENGINE == 'webkit' and os.environ.get('WEBKIT_PATH') else {}
        b = await getattr(pw, ENGINE).launch(**kw)
        for user, vp in (('localadmin', (390, 844)), ('localipad', (820, 1180))):
            ctx = await b.new_context(viewport={'width': vp[0], 'height': vp[1]})
            if ENGINE == 'chromium': await ctx.grant_permissions(['notifications'], origin=APP.rstrip('/'))
            page = await ctx.new_page(); errs = []; page.on('pageerror', lambda e: errs.append(str(e)))
            await login(page, user)
            check(await screen(page) == 'day', f'{user}: after login the app is on Dashboard')
            # Fresh start (iOS relaunch / reload) on another screen → Dashboard, login kept, no modal back
            await go(page, 'messages'); await page.evaluate("openAdd && openAdd()"); await page.wait_for_timeout(300)
            await page.reload(); await page.wait_for_function('typeof _currentUserRole !== "undefined" && !!_currentUserRole', timeout=30000); await page.wait_for_timeout(800)
            check(await screen(page) == 'day' and not await page.evaluate("document.getElementById('addOv').classList.contains('on')"),
                  f'{user}: fresh start → Dashboard, no old screen or form restored, still logged in')
            # Normal use is never redirected
            await go(page, 'messages'); await page.evaluate("document.dispatchEvent(new Event('visibilitychange'))"); await page.wait_for_timeout(1500)
            check(await screen(page) == 'messages', f'{user}: normal use / coming back to the app does not jump to Dashboard')
            if ENGINE == 'chromium':
                await page.reload(); await page.wait_for_function('typeof _currentUserRole !== "undefined" && !!_currentUserRole', timeout=30000)
                await page.evaluate("navigator.serviceWorker.controller ? 1 : new Promise(r => navigator.serviceWorker.addEventListener('controllerchange', r))")
                await page.evaluate("window.__sameWindow = 'yes'")
                # App open in the background on Messages → staff alert tap → Dashboard, same window (no reload, login kept)
                await go(page, 'messages')
                r = await tap(ctx, './'); await page.wait_for_timeout(800)
                check(r in ('ok', 'error: InvalidAccessError: Not allowed to open a window.') and await screen(page) == 'day' and await page.evaluate("window.__sameWindow") == 'yes' and len(ctx.pages) == 1,
                      f'{user}: tap on a staff alert with the app open on Messages → Dashboard (same window, no reload, no second window)', (r, await screen(page), len(ctx.pages)))
                # Already on Dashboard → nothing changes (no duplicate navigation)
                clicks = await page.evaluate("(() => { window.__clicks = 0; document.querySelector('.tab[data-t=\"day\"]').addEventListener('click', () => window.__clicks++); return 0; })()")
                await tap(ctx, './'); await page.wait_for_timeout(600)
                check(await screen(page) == 'day' and await page.evaluate("window.__clicks") == 0, f'{user}: tap while already on Dashboard → no extra navigation')
                # Check-in form open with typed text → Dashboard underneath, the form and its text stay
                await go(page, 'messages'); await page.evaluate("openAdd()"); await page.wait_for_timeout(400)
                await page.evaluate("(() => { const i = document.querySelector('#addOv input[type=text], #addOv input:not([type])'); if (i) { i.value = 'TYPED GUEST'; i.setAttribute('data-e2e', '1'); } })()")
                await tap(ctx, './'); await page.wait_for_timeout(800)
                kept = await page.evaluate("(() => { const i = document.querySelector('#addOv [data-e2e]'); return document.getElementById('addOv').classList.contains('on') && !!i && i.value === 'TYPED GUEST'; })()")
                check(await screen(page) == 'day' and kept, f'{user}: tap during a check-in → Dashboard underneath, the form and what was typed stay')
                await page.evaluate("closeAll()")
                # Guest message alert keeps opening Messages (passenger-message flow unchanged)
                r = await tap(ctx, './#messages'); await page.wait_for_timeout(800)
                check(await screen(page) == 'messages', f'{user}: tap on a guest-message alert → Messages (as before)')
                # A TV page open at the same time is never moved
                tv = await ctx.new_page(); await tv.goto(APP + '?mode=tv'); await tv.wait_for_timeout(2500)
                tv_before = await tv.evaluate("location.href + '|' + document.body.className")
                await go(page, 'messages'); await page.bring_to_front()
                await tap(ctx, './'); await page.wait_for_timeout(800)
                check(await tv.evaluate("location.href + '|' + document.body.className") == tv_before and await screen(page) == 'day', f'{user}: TV page untouched; the staff screen goes to Dashboard')
                await tv.close()
                # App closed: the tap opens the start URL './' (a synthetic tap cannot open windows in a test
                # browser, so open that URL as openWindow would) → Dashboard with the saved login.
                await page.close()
                np = await ctx.new_page(); await np.goto(APP)
                await np.wait_for_function('typeof _currentUserRole !== "undefined" && !!_currentUserRole', timeout=30000); await np.wait_for_timeout(800)
                check(await screen(np) == 'day', f'{user}: app closed → opening at the start URL lands on Dashboard, login kept')
                # Session expired → login screen, no redirect loop
                await np.evaluate("Object.keys(localStorage).filter(k => k.startsWith('sb-')).forEach(k => localStorage.removeItem(k))")
                await np.goto(APP); await np.wait_for_selector('#loginEmail', state='visible', timeout=20000); u1 = np.url; await np.wait_for_timeout(3000)
                check(np.url == u1 and await np.is_visible('#loginEmail') and len(ctx.pages) == 1, f'{user}: expired session → the login screen, one window, no redirect loop')
                page = np
            check(not errs, f'{user}: no page errors', errs[:3])
            await ctx.close()
        await b.close()
    print('%d passed, %d failed' % (oks, fails))
asyncio.run(main())
