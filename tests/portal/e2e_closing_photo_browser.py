# LOCAL ONLY. Closing Report image v93 (owner 2026-10-29): 1080 px JPEG, wide + short, numbers on top,
# shared as files only (no title / text, so WhatsApp treats it as a photo), Leaving Tomorrow JPEG too.
# Uses the 10/28 production numbers as a fixture object (nothing written to any database).
#   APP=http://127.0.0.1:8798/ ENGINE=chromium|webkit SHOT_DIR=… python3 tests/portal/e2e_closing_photo_browser.py <dir with test_password.txt>
import asyncio, base64, os, sys
from playwright.async_api import async_playwright

DIR = sys.argv[1]
APP = os.environ.get('APP', 'http://127.0.0.1:8798/')
ENGINE = os.environ.get('ENGINE', 'chromium')
SHOT = os.environ.get('SHOT_DIR', '/tmp')
PW = open(DIR + '/test_password.txt').read().strip()
oks, fails = 0, 0
REPORT = """{report_date:'2026-10-28', checked_in_today:3, delivered_today:1, in_custody_count:32, stripe_tips_cents:0,
  other_tips_cents:3000, total_tips_cents:7000, cash_counted_cents:7000, ticket_cash_tips_cents:4000, cash_difference_cents:3000,
  cash_reconciliation:'OTHER_TIPS', leaving_tomorrow_count:4, cash_custodian_name:'DIEGO', closed_at:'2026-10-28T21:58:00Z',
  attendants:[{name:'MATHEUS F', time_in:'05:05', time_out:'10:25'}, {name:'DIEGO', time_in:'09:55', time_out:'18:05'}]}"""


def check(cond, msg, extra=''):
    global oks, fails
    if cond: oks += 1; print('ok  ', msg)
    else: fails += 1; print('FAIL', msg, extra)


async def guard(route):
    u = route.request.url
    if u.startswith('http://127.0.0.1') or 'fonts.g' in u or 'cdnjs' in u or 'jsdelivr' in u: await route.continue_()
    else: await route.abort()


async def main():
    async with async_playwright() as pw:
        kw = {'executable_path': os.environ['WEBKIT_PATH']} if ENGINE == 'webkit' and os.environ.get('WEBKIT_PATH') else {}
        b = await getattr(pw, ENGINE).launch(**kw)
        ctx = await b.new_context(viewport={'width': 390, 'height': 844}, service_workers='block', has_touch=True)
        await ctx.route('**/*', guard)
        page = await ctx.new_page()
        errs = []; page.on('pageerror', lambda e: errs.append(str(e)))
        await page.goto(APP)
        await page.wait_for_selector('#loginEmail', state='visible', timeout=20000)
        for attempt in range(3):
            await page.wait_for_timeout(2000)
            await page.fill('#loginEmail', 'localiphone'); await page.fill('#loginPwd', PW); await page.press('#loginPwd', 'Enter')
            try:
                await page.wait_for_function('typeof _currentUserEmail !== "undefined" && !!_currentUserEmail', timeout=15000); break
            except Exception:
                if attempt == 2: raise
        await page.wait_for_function('typeof html2canvas === "function"', timeout=20000)
        r = await page.evaluate('''async () => {
          const rep = %s;
          const c = await crCaptureCanvas(rep);
          const blob = await crJpegBlob(c);
          const url = c.toDataURL('image/jpeg', 0.9);
          const host = document.createElement('div'); host.innerHTML = crBuildExportMarkup(rep); document.body.appendChild(host);
          const txt = host.innerText; host.remove();
          return { w: c.width, h: c.height, type: blob.type, kb: Math.round(blob.size / 1024), url: url, txt: txt };
        }''' % REPORT)
        open(SHOT + '/closing_photo_%s.jpg' % ENGINE, 'wb').write(base64.b64decode(r['url'].split(',')[1]))
        check(r['w'] == 1080, 'image is 1080 px wide (was 3240)', r['w'])
        check(r['type'] == 'image/jpeg' and r['kb'] < 600, 'JPEG, small file (%d KB, was 2.1 MB PNG)' % r['kb'], r['kb'])
        check(r['h'] / r['w'] <= 1.6, 'wide and short enough for the WhatsApp preview (%.2f : 1)' % (r['h'] / r['w']))
        t = r['txt']
        for s in ['Wednesday, Oct 28', '32', '$70.00', 'Cash counted', 'Cash tips on tickets', 'Other tips', 'Stripe (online)', 'MATHEUS F', 'DIEGO', 'Cash with', '5:58 PM']:
            check(s in t, 'image shows: ' + s)
        check(t.find('$70.00') < t.find('Cash with'), 'totals come before the team section')
        # Share: files only, JPEG, no text / title
        got = await page.evaluate('''async () => {
          window._crSavedReport = %s; _crSavedReport = window._crSavedReport; _crCanvas = null; _crBusinessDate = '2026-10-28'; _crLtCount = 0;
          let args = null;
          navigator.canShare = () => true;
          navigator.share = async (a) => { args = a; };
          await crShareAll();
          return args ? { keys: Object.keys(args), n: args.files.length, type: args.files[0].type, name: args.files[0].name } : null;
        }''' % REPORT)
        check(got and got['keys'] == ['files'] and got['type'] == 'image/jpeg' and got['name'].endswith('.jpg'), 'Share sends only the JPEG file (no title / text)', got)
        check(errs == [], 'no page errors', errs)
        await ctx.close(); await b.close()
    print('\n%s: %d ok, %d failed' % (ENGINE, oks, fails))
    sys.exit(1 if fails else 0)


asyncio.run(main())
