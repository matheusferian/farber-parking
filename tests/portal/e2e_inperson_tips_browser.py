# LOCAL ONLY. In-person tips (owner 2026-10-28): optional tip at check-in V2 ($5 $10 $20 $50 Other),
# at delivery (same chips), several per ticket, + Add tip later on any ticket, per-row Correct
# with reason, DAILY TIPS on the Dashboard (cash recorded + online = total recorded), iPad + iPhone.
# Needs 20261113 + 20261117 applied to the LOCAL stack. App served by serve_root.py (APP_ROOT = this
# worktree); no SMS (check-ins without texts); every other host is aborted.
#   APP=http://127.0.0.1:8798/ ENGINE=chromium|webkit SHOT_DIR=… python3 tests/portal/e2e_inperson_tips_browser.py <dir with test_password.txt>
import asyncio, os, subprocess, sys
from playwright.async_api import async_playwright

DIR = sys.argv[1]
APP = os.environ.get('APP', 'http://127.0.0.1:8798/')
ENGINE = os.environ.get('ENGINE', 'chromium')
SHOT = os.environ.get('SHOT_DIR', '/tmp')
FN_ORIGIN = 'http://127.0.0.1:8781'
PW = open(DIR + '/test_password.txt').read().strip()
oks, fails = 0, 0
TODAY = "(now() at time zone 'America/New_York')::date"
PAX = "(select id from public.passengers where name like 'INPERSON E2E%' or id between 971801 and 971803)"


def sql(q):
    r = subprocess.run(['docker', 'exec', '-i', 'supabase_db_airvalet-portal-local', 'psql', '-U', 'postgres', '-d', 'postgres', '-qAt', '-c', q], capture_output=True, text=True)
    if r.returncode: raise RuntimeError(r.stderr)
    return r.stdout.strip()


def check(cond, msg, extra=''):
    global oks, fails
    if cond: oks += 1; print('ok  ', msg)
    else: fails += 1; print('FAIL', msg, extra)


CLEAN = """
delete from public.airvalet_tip_records where passenger_id in %(p)s;
delete from public.payments where passenger_id in %(p)s;
delete from public.airvalet_sms_messages where passenger_id in %(p)s;
delete from public.airvalet_pass_links where passenger_id in %(p)s;
delete from public.airvalet_sms_enrollments where passenger_id in %(p)s;
delete from public.airvalet_sms_consents where passenger_id in %(p)s;
delete from public.vehicle_location_history where passenger_id in %(p)s;
delete from public.activity_log where passenger_id in %(p)s;
delete from public.passengers where id in %(p)s;
""" % {'p': PAX}
FIX = """
insert into public.passengers (id, ts, checkin_date, name, phone, ticket, status, ret, loc, car, color, return_operator) values
 (971801, 'x', now(), 'PARKED TIP', '3055558811', 'IP-1', 'PENDING', to_char(%(t)s + 3, 'FMMM/FMDD/YYYY'), 'HANGAR 16', 'BMW X5', 'Black', 'MAKERS'),
 (971802, 'x', now(), 'PHONE TIP',  '3055558812', 'IP-2', 'PENDING', to_char(%(t)s, 'FMMM/FMDD/YYYY'), 'HANGAR 16', 'Audi Q7', 'White', 'MAKERS');
""" % {'t': TODAY}


def ledger(pid):
    return sql("select coalesce(string_agg(amount_cents || ':' || stage || ':' || (voided_at is not null), ',' order by id), '') from public.airvalet_tip_records where passenger_id = %d" % pid)


def car(pid):
    return sql("select status || '|' || coalesce(tip_received::text, 'null') || '|' || coalesce(tip_in_person_cents::text, 'null') from public.passengers where id = %d" % pid)


async def guard(route):
    u = route.request.url
    if '/functions/v1/' in u and u.startswith('http://127.0.0.1:56331'):
        h = dict(route.request.headers); h['origin'] = FN_ORIGIN
        try: resp = await route.fetch(headers=h)
        except Exception: return await route.abort()
        rh = dict(resp.headers); rh['access-control-allow-origin'] = APP.rstrip('/')
        return await route.fulfill(response=resp, headers=rh)
    if u.startswith('http://127.0.0.1') or 'fonts.g' in u or 'cdnjs' in u or 'jsdelivr' in u: await route.continue_()
    else: await route.abort()


async def login(b, viewport, user):
    ctx = await b.new_context(viewport=viewport, service_workers='block', has_touch=viewport['width'] < 600)
    await ctx.route('**/*', guard)
    page = await ctx.new_page()
    page.on('dialog', lambda d: asyncio.ensure_future(d.accept()))
    errs = []
    page.on('pageerror', lambda e: errs.append(str(e)))
    await page.goto(APP + '?checkin=v2')
    await page.wait_for_selector('#loginEmail', state='visible', timeout=20000)
    for attempt in range(3):
        await page.wait_for_timeout(2000)
        await page.fill('#loginEmail', user); await page.fill('#loginPwd', PW); await page.press('#loginPwd', 'Enter')
        try:
            await page.wait_for_function('typeof _currentUserEmail !== "undefined" && !!_currentUserEmail && Array.isArray(data) && data.length > 0', timeout=15000); break
        except Exception:
            if attempt == 2: raise
    await page.wait_for_timeout(1500)
    await page.evaluate('''() => { window.epsonSend = async () => true;
      window._msgs = []; var _sm = showMsg; window.showMsg = function (t, e) { window._msgs.push(String(t)); return _sm.apply(this, arguments); }; }''')
    await page.evaluate('loadData()'); await page.wait_for_function('data.some(function(r){return r.id===971801})', timeout=15000)
    return ctx, page, errs


async def closeall(page):
    await page.evaluate('''() => { document.querySelectorAll('.ov.on').forEach(function(o){ o.classList.remove('on'); }); }''')


async def card(page, pid):
    await closeall(page)
    await page.evaluate('showDet(%d)' % pid)
    await page.wait_for_function('document.querySelector("#tipsSec .stp-row")', timeout=10000)
    await page.wait_for_timeout(400)
    return await page.evaluate('document.getElementById("tipsSec").innerText')


async def add_later(page, pid, chip=None, typed=None):
    await card(page, pid)
    await page.click('#tipsSec button:has-text("+ Add tip")')
    await page.wait_for_selector('#tipFixOv.on #tipFixQuick', timeout=5000)
    if chip: await page.click('#tipFixQuick button[data-c="%s"]' % chip)
    if typed is not None:
        await page.click('#tipFixQuick button[data-c="other"]'); await page.fill('#tipFixAmt', typed)
    await page.click('#tipFixSave'); await page.wait_for_timeout(1200)
    return await page.evaluate('({ open: document.getElementById("tipFixOv").classList.contains("on"), msg: document.getElementById("tipFixMsg") ? document.getElementById("tipFixMsg").textContent : "" })')


async def daily(page):
    await closeall(page)
    await page.evaluate('refreshStripeTipsKpi()'); await page.wait_for_timeout(1200)
    return await page.evaluate('({ cash: dtpCash.textContent, online: stripeTipsTodayNum.textContent, total: dtpTotal.textContent, day: dtpDate.textContent, next: dtpNext.disabled })')


def money(c): return '$%.2f' % (int(c) / 100)


async def main():
    sql(CLEAN); sql(FIX)
    if sql("select count(*) from public.daily_closing_reports where report_date = %s and closed_at is not null" % TODAY) != '0':
        print('SKIP: today is closed in the local DB'); sys.exit(2)
    pay0 = sql('select count(*) from public.payments')
    async with async_playwright() as pw:
        kw = {'executable_path': os.environ['WEBKIT_PATH']} if ENGINE == 'webkit' and os.environ.get('WEBKIT_PATH') else {}
        b = await getattr(pw, ENGINE).launch(**kw)

        # ══ iPad (IPAD_OPS) ══════════════════════════════════════════════
        ctx, page, errs = await login(b, {'width': 820, 'height': 1180}, 'localipad')

        # ── Check-in V2: create (no texts), the Tip section is optional ──
        await page.evaluate('openAdd()'); await page.wait_for_selector('#ci2Name', state='visible')
        await page.fill('#ci2Name', 'INPERSON E2E ONE'); await page.click('#ci2Phone'); await page.keyboard.type('3055558801')
        check(await page.evaluate('!document.getElementById("ci2STip") || document.getElementById("ci2Details").hidden'), 'check-in: no tip step before the ticket exists (nothing extra to do)')
        await page.click('#ci2No'); await page.click('#ci2NoText')
        await page.wait_for_selector('#ci2Created:not([hidden])', timeout=15000)
        pid = await page.evaluate('_ci.id')
        check(bool(pid) and ledger(pid) == '', 'check-in saved without any tip → nothing recorded', ledger(pid))
        v = await page.evaluate('ci2STipV.textContent')
        check(v == '+ Add tip', 'Tip section collapsed, reads "+ Add tip"', v)
        await page.click('#ci2STip .ci2-sec-h'); await page.wait_for_timeout(300)
        st = await page.evaluate('''() => { const bs=[...document.querySelectorAll('#ci2Tip .stp-qrow button')];
            return { labels: bs.map(b=>b.textContent).join(' '), pressed: bs.filter(b=>b.getAttribute('aria-pressed')==='true').length, h: Math.min(...bs.map(b=>b.getBoundingClientRect().height)) }; }''')
        check(st['labels'] == '$5 $10 $20 $50 Other' and st['pressed'] == 0, 'chips $5 $10 $20 $50 Other, none pre-selected', st)
        check(st['h'] >= 44, 'chips are 44 px tap targets', st)
        await page.click('#ci2TipSave'); await page.wait_for_timeout(500)
        m = await page.evaluate('ci2TipMsg.textContent')
        check('Pick an amount' in m and ledger(pid) == '', 'Save with nothing picked → nothing recorded, asks for an amount', m)
        await page.click('#ci2Tip button[data-c="1000"]')
        check(await page.evaluate('document.querySelector("#ci2Tip input").value') == '10.00', '$10 chip fills 10.00')
        await page.screenshot(path=SHOT + '/inperson_checkin_ipad_%s.png' % ENGINE)
        await page.click('#ci2TipSave'); await page.wait_for_function('ci2TipMsg.textContent.indexOf("saved") >= 0', timeout=8000)
        check(ledger(pid) == '1000:CHECKIN:false', '$10 at check-in recorded (CHECK-IN stage)', ledger(pid))
        check(car(pid).endswith('|null|null'), 'check-in tip does not touch the car''s delivery answer', car(pid))
        v = await page.evaluate('ci2STipV.textContent')
        check(v == '$10.00 recorded', 'section header shows the amount recorded', v)
        # double tap on Save ($5): one row
        await page.click('#ci2Tip button[data-c="500"]')
        await page.evaluate('ci2TipSave(); ci2TipSave();')
        await page.wait_for_function('ci2TipMsg.textContent.indexOf("$5.00 cash saved") >= 0', timeout=8000)
        check(ledger(pid) == '1000:CHECKIN:false,500:CHECKIN:false', 'double tap on Save → one $5 row', ledger(pid))
        # Other: decimal amount
        await page.click('#ci2Tip button[data-c="other"]'); await page.fill('#ci2Tip input', '7.5')
        check(await page.evaluate('document.querySelector("#ci2Tip button[data-c=other]").getAttribute("aria-pressed")') == 'true', 'typed amount marks Other')
        await page.click('#ci2TipSave'); await page.wait_for_function('ci2TipMsg.textContent.indexOf("$7.50") >= 0', timeout=8000)
        check(ledger(pid).endswith(',750:CHECKIN:false'), 'Other $7.50 recorded (decimal)', ledger(pid))
        await page.fill('#ci2Tip input', '12.345'); await page.click('#ci2TipSave'); await page.wait_for_timeout(500)
        check(ledger(pid).count(',') == 2 and 'amount' in (await page.evaluate('ci2TipMsg.textContent')).lower(), 'invalid amount refused on screen, nothing recorded', ledger(pid))
        await page.fill('#ci2Tip input', '0'); await page.click('#ci2TipSave'); await page.wait_for_timeout(500)
        check(ledger(pid).count(',') == 2, '$0 never recorded')
        # offline ticket: the tip waits for the car card
        await page.evaluate('_ci.offline = true'); await page.fill('#ci2Tip input', '5'); await page.click('#ci2TipSave'); await page.wait_for_timeout(300)
        check('offline' in (await page.evaluate('ci2TipMsg.textContent')) and ledger(pid).count(',') == 2, 'offline ticket: no tip write, told to add it from the car card')
        await page.evaluate('_ci.offline = false')
        await page.screenshot(path=SHOT + '/inperson_checkin_saved_ipad_%s.png' % ENGINE)
        await closeall(page); await page.evaluate('loadData()'); await page.wait_for_timeout(1500)

        # ── Delivery: same chips; adds a CHECKOUT row ───────────────────
        await page.evaluate('openTipModal(%d, "NORMAL")' % pid); await page.wait_for_selector('#tipOv.on', timeout=5000); await page.wait_for_timeout(400)
        await page.click('#tipIpY'); await page.click('#tipIpQuick button[data-c="2000"]')
        check(await page.evaluate('tipIpAmt.value') == '20.00', 'delivery: $20 chip fills the amount')
        await page.screenshot(path=SHOT + '/inperson_delivery_ipad_%s.png' % ENGINE)
        await page.click('#tipYesBtn'); await page.wait_for_function('!document.getElementById("tipOv").classList.contains("on")', timeout=15000); await page.wait_for_timeout(1500)
        check(ledger(pid) == '1000:CHECKIN:false,500:CHECKIN:false,750:CHECKIN:false,2000:CHECKOUT:false', 'delivery $20 added, check-in tips kept (nothing overwritten)', ledger(pid))
        check(car(pid) == 'DELIVERED|true|2000', 'car: delivered, tip received, mirror = delivery $20', car(pid))

        # ── Car card: every amount, total, + Add tip, Correct per row ──
        t = await card(page, pid)
        check('at check-in' in t.lower() and 'at delivery' in t.lower() and '$42.50' in t, 'card lists every cash tip by stage + total $42.50', t[:300])
        await page.screenshot(path=SHOT + '/inperson_card_ipad_%s.png' % ENGINE)
        r = await add_later(page, pid, chip='500')
        check(not r['open'] and ledger(pid).endswith(',500:LATER:false'), '+ Add tip later ($5) after delivery', (r, ledger(pid)))
        r = await add_later(page, pid, chip='500')
        check(r['open'] and 'just recorded' in r['msg'] and ledger(pid).count('LATER') == 1, 'same $5 again within 2 min → warned, not doubled', r)
        await closeall(page)
        await card(page, pid)
        rid = sql("select id from public.airvalet_tip_records where passenger_id = %d and amount_cents = 1000 and voided_at is null" % pid)
        await page.evaluate('tipFixOpen("CORRECT", %s)' % rid); await page.wait_for_selector('#tipFixOv.on', timeout=5000)
        await page.fill('#tipFixAmt', '12'); await page.click('#tipFixSave'); await page.wait_for_timeout(500)
        check(await page.evaluate('tipFixOv.classList.contains("on")'), 'correction without a reason is refused')
        await page.fill('#tipFixReason', 'Counted again: 12'); await page.click('#tipFixSave'); await page.wait_for_timeout(1500)
        check(sql("select amount_cents || ':' || stage || ':' || source from public.airvalet_tip_records where supersedes_id = %s" % rid) == '1200:CHECKIN:CORRECTION', 'check-in $10 → $12 corrected, stage kept, old row kept', ledger(pid))
        t = await card(page, pid)
        check('Counted again: 12' in t and '$49.50' in t, 'card shows the history line and the new total $49.50 (12 + 5 + 7.50 + 20 + 5)', t)
        check(car(pid) == 'DELIVERED|true|2500', 'car mirror = delivery + later ($25)', car(pid))

        # ── Active ticket: + Add tip (LATER) ────────────────────────────
        r = await add_later(page, 971801, typed='15')
        check(not r['open'] and ledger(971801) == '1500:LATER:false', 'parked car: + Add tip $15 (LATER)', (r, ledger(971801)))
        check(car(971801) == 'PENDING|true|1500', 'parked car: status untouched', car(971801))

        # ── DAILY TIPS ───────────────────────────────────────────────────
        exp = sql("select (d->'cash'->>'cents') || '|' || (d->'online'->>'cents') || '|' || (d->>'total_recorded_cents') from (select public.airvalet_daily_tips(%s) d) x" % TODAY).split('|')
        d = await daily(page)
        check(d['cash'] == money(exp[0]) and d['online'] == money(exp[1]) and d['total'] == money(exp[2]), 'DAILY TIPS = server numbers (cash + online = total recorded)', (d, exp))
        check(d['day'] == 'Today' and d['next'], 'today, next day disabled')
        note = await page.evaluate('dtpNote.textContent')
        check('only what the team recorded' in note, 'note: cash = only what the team recorded', note)
        await page.screenshot(path=SHOT + '/inperson_daily_ipad_%s.png' % ENGINE, clip={'x': 0, 'y': 0, 'width': 820, 'height': 420})
        await page.click('#dtpPrev'); await page.wait_for_timeout(1200)
        check(await page.evaluate('dtpDate.textContent') == 'Yesterday' and not await page.evaluate('dtpNext.disabled'), 'previous day: Yesterday, next enabled')
        await page.click('#dtpNext'); await page.wait_for_timeout(800)
        check(errs == [], 'iPad: no page errors', errs)
        await ctx.close()

        # ══ iPhone (IPHONE_OPS) ═════════════════════════════════════════
        ctx, page, errs = await login(b, {'width': 390, 'height': 844}, 'localiphone')
        d = await daily(page)
        lay = await page.evaluate('''() => ({ over: document.scrollingElement.scrollWidth > innerWidth,
            clip: [...document.querySelectorAll('.dtp-grid dd')].some(e => e.scrollWidth > e.clientWidth + 1) })''')
        check(not lay['over'] and not lay['clip'], 'iPhone: DAILY TIPS fits (no clipping, no side scroll)', lay)
        await page.screenshot(path=SHOT + '/inperson_daily_iphone_%s.png' % ENGINE, clip={'x': 0, 'y': 0, 'width': 390, 'height': 420})
        r = await add_later(page, 971802, chip='5000')
        check(not r['open'] and ledger(971802) == '5000:LATER:false', 'iPhone: + Add tip $50', (r, ledger(971802)))
        await page.click('#tipsSec button:has-text("+ Add tip")'); await page.wait_for_selector('#tipFixOv.on', timeout=5000)
        lay = await page.evaluate('''() => { const bs=[...document.querySelectorAll('#tipFixQuick .stp-qrow button')], m=document.querySelector('#tipFixOv .modal').getBoundingClientRect();
            return { h: Math.min(...bs.map(b=>b.getBoundingClientRect().height)), inside: bs.every(b=>b.getBoundingClientRect().right <= m.right + 0.5), over: document.scrollingElement.scrollWidth > innerWidth }; }''')
        check(lay['h'] >= 44 and lay['inside'] and not lay['over'], 'iPhone: 5 chips in one row, 44 px, inside the sheet', lay)
        await page.screenshot(path=SHOT + '/inperson_add_iphone_%s.png' % ENGINE)
        await closeall(page)
        d2 = await daily(page)
        check(d2['cash'] != d['cash'], 'DAILY TIPS updates after a new tip', (d, d2))
        check(errs == [], 'iPhone: no page errors', errs)
        await ctx.close(); await b.close()

    check(sql('select count(*) from public.payments') == pay0, 'no Stripe / payment row created by any cash tip')
    sql(CLEAN)
    print('\n%s: %d ok, %d failed' % (ENGINE, oks, fails))
    sys.exit(1 if fails else 0)


asyncio.run(main())
