# LOCAL ONLY. Closing Report lists the cars leaving tomorrow with their time (owner 2026-10-27), in the
# preview and in the shared image, rebuilt from the tickets for report date + 1 (a report closed outside
# the form, or opened later, still shows it).   APP=... ENGINE=chromium|webkit python3 tests/portal/e2e_closing_lt_browser.py <dir with test_password.txt>
import asyncio, base64, os, subprocess, sys
from playwright.async_api import async_playwright

DIR = sys.argv[1]
APP = os.environ.get('APP', 'http://127.0.0.1:8797/')
ENGINE = os.environ.get('ENGINE', 'chromium')
SHOT = os.environ.get('SHOT_DIR', '/tmp')
PW = open(DIR + '/test_password.txt').read().strip()
oks, fails = 0, 0
def sql(q):
    r = subprocess.run(['docker', 'exec', '-i', 'supabase_db_airvalet-portal-local', 'psql', '-U', 'postgres', '-d', 'postgres', '-qAt', '-c', q], capture_output=True, text=True)
    if r.returncode: raise RuntimeError(r.stderr)
    return r.stdout.strip()
def check(cond, msg, extra=''):
    global oks, fails
    if cond: oks += 1; print('ok  ', msg)
    else: fails += 1; print('FAIL', msg, str(extra)[:400])
async def guard(route):
    u = route.request.url
    if u.startswith('http://127.0.0.1') or 'fonts.g' in u or 'cdnjs' in u or 'jsdelivr' in u: await route.continue_()
    else: await route.abort()

TODAY = sql("select (now() at time zone 'America/New_York')::date")
T = "to_char((now() at time zone 'America/New_York')::date + %d, 'FMMM/FMDD/YYYY')"
CLEAN = "delete from public.activity_log where passenger_id between 984001 and 984009; delete from public.passengers where id between 984001 and 984009;"
FIX = """insert into public.passengers (id, ts, checkin_date, name, phone, ticket, status, ret, loc, car, color, departure_time) values
 (984001, 'x', now() - interval '3 days', 'ANNA LATEFLIGHTX', '3055558401', 'LT-1', 'PENDING', %(t1)s, 'HANGAR 18', 'Range Rover', 'Black', '17:02'),
 (984002, 'x', now() - interval '3 days', 'BRUNO EARLYX', '3055558402', 'LT-2', 'PENDING', %(t1)s, 'HANGAR 16', 'Audi Q7', 'Gray', '09:30'),
 (984003, 'x', now() - interval '3 days', 'CARLA NOTIMEX', '3055558403', 'LT-3', 'NO DATE', %(t1)s, 'HANGAR 19', 'Tesla Model Y', 'White', ''),
 (984004, 'x', now() - interval '3 days', 'DAN ARCHIVEDX', '3055558404', 'LT-4', 'ARCHIVED', %(t1)s, 'HANGAR 19', 'Mini', 'Green', '10:00'),
 (984005, 'x', now() - interval '3 days', 'EVA LATERX', '3055558405', 'LT-5', 'PENDING', %(t2)s, 'HANGAR 19', 'BMW X5', 'Black', '11:00');""" % {'t1': T % 1, 't2': T % 2}

async def main():
    sql(CLEAN); sql(FIX)
    async with async_playwright() as p:
        b = await (p.webkit.launch(executable_path=os.environ['WEBKIT_PATH']) if ENGINE == 'webkit' and os.environ.get('WEBKIT_PATH') else getattr(p, ENGINE).launch())
        try:
            ctx = await b.new_context(viewport={'width': 820, 'height': 1180}, service_workers='block'); await ctx.route('**/*', guard)
            page = await ctx.new_page(); errs = []; page.on('pageerror', lambda e: errs.append(str(e)))
            await page.goto(APP); await page.wait_for_selector('#loginEmail', state='visible', timeout=20000)
            for attempt in range(3):
                await page.wait_for_timeout(2000)
                await page.fill('#loginEmail', 'localadmin'); await page.fill('#loginPwd', PW); await page.press('#loginPwd', 'Enter')
                try: await page.wait_for_function('typeof _currentUserEmail !== "undefined" && !!_currentUserEmail && Array.isArray(data) && data.length > 0', timeout=15000); break
                except Exception:
                    if attempt == 2: raise
            rows = await page.evaluate('crLtRowsFor(%r).map(r => r.ticket)' % TODAY)
            check(rows == ['LT-2', 'LT-1', 'LT-3'], 'tomorrow: the 3 cars, by time; archived and day-after left out', rows)
            # A report closed outside the form (count only, like 10/27) — the image still lists every car.
            rep = {'report_date': TODAY, 'checked_in_today': 5, 'delivered_today': 3, 'in_custody_count': 30, 'stripe_tips_cents': 300, 'other_tips_cents': 1200,
                   'total_tips_cents': 4500, 'cash_counted_cents': 4200, 'ticket_cash_tips_cents': 3000, 'cash_difference_cents': 1200, 'cash_reconciliation': 'OTHER_TIPS',
                   'attendants': [{'name': 'DIEGO', 'time_in': '04:55', 'time_out': '10:00'}, {'name': 'MATHEUS F', 'time_in': '10:00', 'time_out': '18:00'}],
                   'cash_custodian_name': 'MATHEUS F', 'leaving_tomorrow_count': 1, 'closed_at': '2026-10-27T22:20:00Z'}
            await page.evaluate('''(r) => { var h = document.createElement('div'); h.id = 'ltTestHost'; h.style.cssText = 'position:fixed;left:0;top:0;z-index:99999;background:#011532';
                                     h.innerHTML = crBuildExportMarkup(r); document.body.appendChild(h); }''', rep)
            txt = await page.evaluate('document.getElementById("ltTestHost").innerText')
            check('LEAVING TOMORROW' in txt.upper() and '9:30 AM' in txt and '5:02 PM' in txt and 'No time' in txt, 'image: each car with its time (missing time flagged)', txt[-400:])
            check('Bruno Earlyx' in txt and '#LT-2' in txt and 'Gray Audi Q7' in txt and 'Hangar 16' in txt, 'image: passenger, ticket, car and hangar', txt[-300:])
            check('Archivedx' not in txt and 'Laterx' not in txt, 'image: archived / day-after cars not listed')
            check(txt.index('9:30 AM') < txt.index('5:02 PM') < txt.index('No time'), 'image: sorted by time, no-time last')
            await page.locator('#ltTestHost').screenshot(path=SHOT + '/closing_leaving_tomorrow_%s.png' % ENGINE)
            await page.evaluate('document.getElementById("ltTestHost").remove()')
            png = await page.evaluate('''async (r) => { var c = await crCaptureCanvas(r); return c.toDataURL('image/png'); }''', rep)
            open(SHOT + '/closing_image_%s.png' % ENGINE, 'wb').write(base64.b64decode(png.split(',')[1]))
            check(len(png) > 20000, 'shared image builds (html2canvas) with the list')
            await page.evaluate('_crBusinessDate = %r; _crLtCount = 0; _crValets = []; _crCashCustodian = ""' % TODAY)
            pv = await page.evaluate('(() => { var d = document.createElement("div"); d.innerHTML = crBuildPreviewHTML(); return d.innerText; })()')
            check('9:30 AM' in pv and '5:02 PM' in pv and 'Bruno Earlyx' in pv, 'preview lists the cars with their time too', pv[-300:])
            check(not errs, 'no page errors', errs[:3])
            await ctx.close()
        finally:
            await b.close(); sql(CLEAN)
    print('\n%s: %d ok, %d failed' % (ENGINE, oks, fails)); sys.exit(1 if fails else 0)
asyncio.run(main())
