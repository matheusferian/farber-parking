# LOCAL ONLY. DAILY TIPS Show / Hide (owner 2026-10-29): amounts hidden on every app open, the real
# values never in the page text while hidden, Show / Hide toggles, reload hides again, iPad + iPhone.
# Needs 20261117 on the LOCAL stack + a $12.34 cash fixture today (passenger 971901).
#   APP=http://127.0.0.1:8798/ ENGINE=chromium|webkit SHOT_DIR=… python3 tests/portal/e2e_daily_tips_hide_browser.py <dir with test_password.txt>
import asyncio, os, sys
from playwright.async_api import async_playwright

DIR = sys.argv[1]
APP = os.environ.get('APP', 'http://127.0.0.1:8798/')
ENGINE = os.environ.get('ENGINE', 'chromium')
SHOT = os.environ.get('SHOT_DIR', '/tmp')
PW = open(DIR + '/test_password.txt').read().strip()
oks, fails = 0, 0


def check(cond, msg, extra=''):
    global oks, fails
    if cond: oks += 1; print('ok  ', msg)
    else: fails += 1; print('FAIL', msg, extra)


async def guard(route):
    u = route.request.url
    if u.startswith('http://127.0.0.1') or 'fonts.g' in u or 'cdnjs' in u or 'jsdelivr' in u: await route.continue_()
    else: await route.abort()


async def login(b, vp, user):
    ctx = await b.new_context(viewport=vp, service_workers='block', has_touch=vp['width'] < 600)
    await ctx.route('**/*', guard)
    page = await ctx.new_page()
    errs = []; page.on('pageerror', lambda e: errs.append(str(e)))
    await page.goto(APP)
    await page.wait_for_selector('#loginEmail', state='visible', timeout=20000)
    for attempt in range(3):
        await page.wait_for_timeout(2000)
        await page.fill('#loginEmail', user); await page.fill('#loginPwd', PW); await page.press('#loginPwd', 'Enter')
        try:
            await page.wait_for_function('typeof _currentUserEmail !== "undefined" && !!_currentUserEmail', timeout=15000); break
        except Exception:
            if attempt == 2: raise
    await page.wait_for_function('document.getElementById("dtpCash").getAttribute("data-v")', timeout=15000)
    await page.wait_for_timeout(500)
    return ctx, page, errs


async def state(page):
    return await page.evaluate('''() => ({ text: document.getElementById('stripeTipsKpi').innerText,
      cash: dtpCash.textContent, total: dtpTotal.textContent, btn: dtpEye.getAttribute('aria-pressed'), counted: dtpCounted.textContent, sub: dtpBoxSub.textContent,
      over: document.scrollingElement.scrollWidth > innerWidth, h: Math.round(dtpEye.getBoundingClientRect().height) })''')


async def main():
    async with async_playwright() as pw:
        kw = {'executable_path': os.environ['WEBKIT_PATH']} if ENGINE == 'webkit' and os.environ.get('WEBKIT_PATH') else {}
        b = await getattr(pw, ENGINE).launch(**kw)
        for name, vp, user in (('ipad', {'width': 820, 'height': 1180}, 'localipad'), ('iphone', {'width': 390, 'height': 844}, 'localiphone')):
            ctx, page, errs = await login(b, vp, user)
            s = await state(page)
            check('12.34' not in s['text'] and s['cash'] == '$ ••••' and s['btn'] == 'false', name + ': opens hidden, real amount not on the page', s)
            check(s['counted'] == '—' and s['sub'] == 'Not closed yet', name + ': cash counted line: today not closed yet', s)
            await page.screenshot(path=SHOT + '/dtp_hidden_%s_%s.png' % (name, ENGINE), clip={'x': 0, 'y': 0, 'width': vp['width'], 'height': 400})
            await page.click('#dtpEye'); await page.wait_for_timeout(200)
            s = await state(page)
            check(s['cash'] == '$12.34' and s['total'].startswith('$') and '••••' not in s['total'] and s['btn'] == 'true', name + ': Show reveals cash + total', s)
            await page.screenshot(path=SHOT + '/dtp_shown_%s_%s.png' % (name, ENGINE), clip={'x': 0, 'y': 0, 'width': vp['width'], 'height': 400})
            await page.evaluate('refreshStripeTipsKpi()'); await page.wait_for_timeout(1200)
            check((await state(page))['cash'] == '$12.34', name + ': a refresh keeps the choice while the app is open')
            await page.click('#dtpPrev'); await page.wait_for_timeout(1500)
            s2 = await state(page)
            check(s2['cash'] != '$ ••••' and s2['counted'] == '$55.00' and s2['sub'].startswith('Closed'), name + ': yesterday shows the cash counted at closing ($55.00)', s2)
            await page.click('#dtpEye'); await page.wait_for_timeout(200)
            check((await state(page))['counted'] == '$ ••••', name + ': cash counted hides with the rest')
            await page.click('#dtpEye'); await page.wait_for_timeout(200)
            await page.click('#dtpNext'); await page.wait_for_timeout(800)
            await page.click('#dtpEye'); await page.wait_for_timeout(200)
            s = await state(page)
            check('12.34' not in s['text'] and s['btn'] == 'false', name + ': Hide masks again', s)
            check(not s['over'] and s['h'] >= 36, name + ': fits, no side scroll, button tappable', s)
            await page.click('#dtpEye'); await page.reload()
            await page.wait_for_function('document.getElementById("dtpCash").getAttribute("data-v")', timeout=20000); await page.wait_for_timeout(500)
            check((await state(page))['cash'] == '$ ••••', name + ': every app open starts hidden again')
            check(errs == [], name + ': no page errors', errs)
            await ctx.close()
        await b.close()
    print('\n%s: %d ok, %d failed' % (ENGINE, oks, fails))
    sys.exit(1 if fails else 0)


asyncio.run(main())
