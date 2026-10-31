# LOCAL ONLY. "Print flight tag for … ?" offer (owner 2026-10-31): it showed and never went away on the iPad.
# Checks: appears; Not now closes at once (computed style, not just the attribute); closes by itself after
# 10 s; Print sends the tag and closes on success, stays on failure; re-render / loadData / Realtime-style
# refresh never brings a dismissed offer back; one offer on screen at a time; the Deliver button under it is
# tappable once it is gone; iPad, iPhone and desktop. The printer is stubbed (never a real print).
#   APP=http://127.0.0.1:8798/ ENGINE=chromium|webkit python3 tests/portal/e2e_flight_tag_offer_browser.py <dir with test_password.txt>
import asyncio, os, subprocess, sys
from playwright.async_api import async_playwright

DIR = sys.argv[1]
APP = os.environ.get('APP', 'http://127.0.0.1:8798/')
ENGINE = os.environ.get('ENGINE', 'chromium')
SHOT = os.environ.get('SHOT_DIR', '/tmp')
PW = open(DIR + '/test_password.txt').read().strip()
oks, fails = 0, 0
TODAY = "to_char((now() at time zone 'America/New_York')::date, 'FMMM/FMDD/YYYY')"


def sql(q):
    r = subprocess.run(['docker', 'exec', '-i', 'supabase_db_airvalet-portal-local', 'psql', '-U', 'postgres', '-d', 'postgres', '-qAt', '-c', q], capture_output=True, text=True)
    if r.returncode: raise RuntimeError(r.stderr)
    return r.stdout.strip()


def check(cond, msg, extra=''):
    global oks, fails
    if cond: oks += 1; print('ok  ', msg)
    else: fails += 1; print('FAIL', msg, extra)


CLEAN = "delete from public.activity_log where passenger_id between 972001 and 972003; delete from public.passengers where id between 972001 and 972003;"
FIX = ("insert into public.passengers (id, ts, checkin_date, name, phone, ticket, status, ret, loc, car, color, return_operator, return_flight) values "
       "(972001,'x',now(),'DOMINIQUE TESTE','3055559001','FT-1','PENDING'," + TODAY + ",'HANGAR 19','Mercedes','Black','MAKERS','AH'),"
       "(972002,'x',now(),'SECOND TESTE','3055559002','FT-2','PENDING'," + TODAY + ",'HANGAR 18','BMW','White','MAKERS','N123'),"
       "(972003,'x',now(),'THIRD TESTE','3055559003','FT-3','PENDING'," + TODAY + ",'HANGAR 18','Audi','Gray','MAKERS','N777');")


async def guard(route):
    u = route.request.url
    if u.startswith('http://127.0.0.1') or 'fonts.g' in u or 'cdnjs' in u or 'jsdelivr' in u: await route.continue_()
    else: await route.abort()


async def offer(page):
    return await page.evaluate('''() => { const e = document.getElementById('flightTagOffer');
      if (!e) return { exists: false, shown: false, n: 0 };
      const cs = getComputedStyle(e), r = e.getBoundingClientRect();
      return { exists: true, shown: cs.display !== 'none' && cs.visibility !== 'hidden' && r.height > 0, text: e.innerText,
               n: document.querySelectorAll('#flightTagOffer').length, right: r.right, left: r.left, w: innerWidth }; }''')


async def run(b, name, vp, user):
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
            await page.wait_for_function('typeof _currentUserEmail !== "undefined" && !!_currentUserEmail && Array.isArray(data) && data.some(function(r){return r.id===972001})', timeout=20000); break
        except Exception:
            if attempt == 2: raise
    await page.evaluate('''() => { window._prints = []; window._printOk = true;
      window.epsonSend = async (xml, label) => { window._prints.push(label); await new Promise(r => setTimeout(r, 300)); return window._printOk; }; }''')

    # 1. appears after saving a return time (real save path, local DB)
    await page.evaluate('saveDepartureTime(972001, "11:20")'); await page.wait_for_timeout(1200)
    o = await offer(page)
    check(o['shown'] and 'DOMINIQUE' in o.get('text', '') and 'AH 11:20' in o.get('text', ''), name + ': offer appears after the time is saved', o)
    check(o.get('left', 0) >= 0 and o.get('right', 0) <= o.get('w', 0), name + ': offer fits the screen', o)
    await page.screenshot(path=SHOT + '/flight_offer_%s_%s.png' % (name, ENGINE))

    # 2. Not now closes immediately (what the eye sees, not just the attribute)
    await page.click('#flightTagOffer button:has-text("Not now")'); await page.wait_for_timeout(150)
    o = await offer(page)
    check(not o['shown'], name + ': Not now closes it immediately', o)

    # 3. re-render / data reload / Realtime-style refresh / same save again never bring it back
    await page.evaluate('render(); renderDay && renderDay();'); await page.evaluate('loadData()'); await page.wait_for_timeout(2500)
    await page.evaluate('suggestFlightTag(data.find(function(r){return r.id===972001}))'); await page.wait_for_timeout(200)
    o = await offer(page)
    check(not o['shown'], name + ': dismissed offer stays closed after render / reload / same values', o)

    # 4. closes by itself after 10 s
    await page.evaluate('saveDepartureTime(972002, "13:45")'); await page.wait_for_timeout(1200)
    check((await offer(page))['shown'], name + ': new legitimate offer (other car) appears')
    await page.wait_for_timeout(10300)
    o = await offer(page)
    check(not o['shown'], name + ': closes by itself after 10 s', o)

    # 5. one at a time: two offers in a row → one element, the latest
    await page.evaluate('saveDepartureTime(972002, "14:00")'); await page.wait_for_timeout(900)
    await page.evaluate('saveDepartureTime(972003, "15:30")'); await page.wait_for_timeout(1200)
    o = await offer(page)
    check(o['n'] == 1 and o['shown'] and 'THIRD' in o.get('text', '') and 'SECOND' not in o.get('text', ''), name + ': never two offers on screen (latest wins)', o)

    # 6. Print: sends the flight tag, closes after success
    await page.click('#flightTagOffer button:has-text("Print")'); await page.wait_for_timeout(800)
    o = await offer(page); prints = await page.evaluate('window._prints.slice()')
    check(prints == ['Flight Tag'] and not o['shown'], name + ': Print sends the tag once and closes after success', (prints, o))

    # 7. Print failure: stays so the team can try again
    await page.evaluate('window._printOk = false'); await page.evaluate('saveDepartureTime(972003, "16:00")'); await page.wait_for_timeout(1200)
    await page.click('#flightTagOffer button:has-text("Print")'); await page.wait_for_timeout(800)
    o = await offer(page)
    check(o['shown'], name + ': failed print keeps the offer to try again', o)
    await page.click('#flightTagOffer button:has-text("Not now")'); await page.wait_for_timeout(150)

    # 8. nothing left on top of the Dashboard buttons
    hit = await page.evaluate('''() => { const y = innerHeight - 40, xs = [innerWidth / 2, 60, innerWidth - 60];
      return xs.map(x => { const e = document.elementFromPoint(x, y); return e ? (e.closest('#flightTagOffer') ? 'OFFER' : 'ok') : 'none'; }); }''')
    check('OFFER' not in hit, name + ': after closing, nothing of the offer is over the Dashboard', hit)
    check(errs == [], name + ': no page errors', errs)
    await ctx.close()


async def main():
    sql(CLEAN); sql(FIX)
    try:
        async with async_playwright() as pw:
            kw = {'executable_path': os.environ['WEBKIT_PATH']} if ENGINE == 'webkit' and os.environ.get('WEBKIT_PATH') else {}
            b = await getattr(pw, ENGINE).launch(**kw)
            for name, vp, user in (('ipad', {'width': 1180, 'height': 820}, 'localipad'), ('iphone', {'width': 390, 'height': 844}, 'localiphone'), ('desktop', {'width': 1440, 'height': 900}, 'localadmin')):
                sql("update public.passengers set departure_time = null where id between 972001 and 972003")
                await run(b, name, vp, user)
            await b.close()
    finally:
        sql(CLEAN)
    print('\n%s: %d ok, %d failed' % (ENGINE, oks, fails))
    sys.exit(1 if fails else 0)


asyncio.run(main())
