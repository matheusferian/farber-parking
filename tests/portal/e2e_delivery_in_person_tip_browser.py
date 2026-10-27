# LOCAL ONLY. Staff delivery flow with the optional in-person tip (Stage 1,
# 2026-10-27): never asked, never blocks Deliver, informational in the Closing
# Report (totals unchanged), the delivered text still carries the digital
# gratuity, and two devices delivering the same car deliver it once.
# App served by serve_root.py; send-sms in AIRVALET_SMS_MODE=mock; other hosts aborted.
#   APP=http://127.0.0.1:8795/ ENGINE=chromium|webkit python3 tests/portal/e2e_delivery_in_person_tip_browser.py <scratch portal dir>
import asyncio, os, subprocess, sys
from playwright.async_api import async_playwright

DIR = sys.argv[1]
APP = os.environ.get('APP', 'http://127.0.0.1:8795/')
ENGINE = os.environ.get('ENGINE', 'chromium')
PW = open(DIR + '/test_password.txt').read().strip()
oks, fails = 0, 0
IDS = range(960101, 960107)


def sql(q):
    r = subprocess.run(['docker', 'exec', '-i', 'supabase_db_airvalet-portal-local', 'psql', '-U', 'postgres', '-d', 'postgres', '-qAt', '-c', q], capture_output=True, text=True)
    if r.returncode: raise RuntimeError(r.stderr)
    return r.stdout.strip()


def check(cond, msg, extra=''):
    global oks, fails
    if cond: oks += 1; print('ok  ', msg)
    else: fails += 1; print('FAIL', msg, extra)


CLEAN = """
delete from public.airvalet_sms_messages where passenger_id between 960101 and 960106;
delete from public.airvalet_notify_log where dedupe_key like '%%96010%%';
delete from public.airvalet_pass_links where passenger_id between 960101 and 960106;
delete from public.airvalet_sms_enrollments where passenger_id between 960101 and 960106;
delete from public.vehicle_location_history where passenger_id between 960101 and 960106;
delete from public.activity_log where passenger_id between 960101 and 960106;
delete from public.passengers where id between 960101 and 960106;
"""
FIX = """
insert into public.passengers (id, ts, checkin_date, name, phone, ticket, status, ret, loc, car, color, return_operator) values
""" + ',\n'.join("(%d, 'x', now(), 'TIP TEST %d', '30555561%02d', 'S1T-%d', 'PENDING', to_char((now() at time zone 'America/New_York')::date, 'FMMM/FMDD/YYYY'), 'HANGAR 16', 'BMW X5', 'Black', 'MAKERS')" % (i, i - 960100, i - 960100, i - 960100) for i in IDS) + """;
insert into public.airvalet_sms_enrollments (passenger_id, phone_e164, device_id, consent_id)
select p.id, public.airvalet_sms_normalize_phone(p.phone), (select id from public.airvalet_sms_devices where status = 'approved' order by decided_at limit 1), gen_random_uuid()
  from public.passengers p where p.id between 960101 and 960106;
"""


async def guard(route):
    u = route.request.url
    if u.startswith('http://127.0.0.1') or 'fonts.g' in u or 'cdnjs' in u or 'jsdelivr' in u: await route.continue_()
    else: await route.abort()


async def login(b):
    ctx = await b.new_context(viewport={'width': 820, 'height': 1180}, service_workers='block')
    await ctx.route('**/*', guard)
    page = await ctx.new_page()
    page.on('dialog', lambda d: asyncio.ensure_future(d.dismiss()))
    await page.goto(APP + '?checkin=v2')
    await page.wait_for_selector('#loginEmail', state='visible', timeout=20000)
    for attempt in range(3):
        await page.wait_for_timeout(2000)
        await page.fill('#loginEmail', 'localipad'); await page.fill('#loginPwd', PW); await page.press('#loginPwd', 'Enter')
        try:
            await page.wait_for_function('typeof _currentUserEmail !== "undefined" && !!_currentUserEmail && Array.isArray(data) && data.length > 0', timeout=15000); break
        except Exception:
            if attempt == 2: raise
    await page.wait_for_timeout(1500)
    await page.evaluate('''async () => {
      const key = smsDeviceKey(true);
      await smsApi('/rest/v1/rpc/airvalet_sms_device_request', { method: 'POST', body: JSON.stringify({ p_device_key: key, p_label: 'E2E iPad', p_user_agent: 'e2e' }) });
      await resolveSmsProvider();
      window.epsonSend = async () => true;
    }''')
    return ctx, page


async def reload_data(page):
    await page.evaluate('loadData()'); await page.wait_for_function('data.some(function(r){return r.id===960101})', timeout=15000)


async def deliver(page, pid, tip=None, amount=None):
    await page.evaluate('openTipModal(%d, "NORMAL")' % pid)
    await page.wait_for_selector('#tipOv.on', timeout=5000)
    if tip:
        await page.click('#tipIpYes')
        if amount is not None: await page.fill('#tipIpAmt', amount)
    await page.click('#tipYesBtn')
    await page.wait_for_function('!document.getElementById("tipOv").classList.contains("on")', timeout=15000)
    await page.wait_for_timeout(1200)
    await page.evaluate('''() => { document.querySelectorAll('.ov.on').forEach(function(o){ o.classList.remove('on'); }); }''')


def row(pid):
    return sql("select status || '|' || coalesce(tip_received::text, 'null') || '|' || coalesce(tip_in_person_cents::text, 'null') from public.passengers where id = %d" % pid)


async def closing(page):
    await page.evaluate('crOpenTab()'); await page.wait_for_timeout(3000)
    return await page.evaluate('''() => ({ stripe: _crStripeTipsCents, other: _crOtherTipsCents, otherInput: (document.getElementById('crOtherTips') || {}).value,
      total: (document.getElementById('crTotalTips') || {}).textContent, hint: (function(e){ return e && !e.hidden ? e.textContent : ''; })(document.getElementById('crInPersonHint')) })''')


async def main():
    sql(CLEAN); sql(FIX)
    try:
        async with async_playwright() as pw:
            kw = {'executable_path': os.environ['WEBKIT_PATH']} if ENGINE == 'webkit' and os.environ.get('WEBKIT_PATH') else {}
            b = await getattr(pw, ENGINE).launch(**kw)
            ctx, page = await login(b)
            await reload_data(page)
            cr0 = await closing(page)
            check(cr0['hint'] == '', 'Closing Report before: no in-person hint', cr0)

            # Modal: optional, unchecked, amount hidden, Deliver enabled.
            await page.evaluate('openTipModal(960101, "NORMAL")'); await page.wait_for_selector('#tipOv.on')
            st = await page.evaluate('''() => ({ checked: document.getElementById('tipIpYes').checked, amtHidden: document.getElementById('tipIpAmt').hidden,
              deliverDisabled: document.getElementById('tipYesBtn').disabled, h: Math.round(document.querySelector('#tipInPerson label').getBoundingClientRect().height) })''')
            check(not st['checked'] and st['amtHidden'] and not st['deliverDisabled'], 'modal: in-person tip unchecked, amount hidden, Deliver enabled', st)
            check(st['h'] >= 44, 'modal: in-person row is a 44 px target', st)
            await page.screenshot(path=os.environ.get('SHOT_DIR', '/tmp') + '/stage1_staff_delivery_modal_%s.png' % ENGINE)
            await page.evaluate('closeTipModal()')

            await deliver(page, 960101)                       # skip (default)
            check(row(960101) == 'DELIVERED|null|null', 'skip: delivered, nothing recorded', row(960101))
            await deliver(page, 960102, tip=True, amount='20')
            check(row(960102) == 'DELIVERED|true|2000', 'in person $20: tip_received true, 2000 cents', row(960102))
            log = sql("select string_agg(detail, ' ') from public.activity_log where passenger_id = 960102")
            check('Tip in person: YES ($20.00)' in (log or ''), 'in person $20: activity log note', log)
            await deliver(page, 960103, tip=True)
            check(row(960103) == 'DELIVERED|true|null', 'in person, no amount: delivered, amount optional', row(960103))
            await deliver(page, 960104, tip=True, amount='abc')
            check(row(960104) == 'DELIVERED|true|null', 'unreadable amount: still delivered, amount not stored', row(960104))

            # Database without the new column (app published first): the delivery still goes through.
            hits = {'n': 0}
            async def no_col(route):
                req = route.request
                if req.method == 'PATCH' and 'tip_in_person_cents' in (req.post_data or ''):
                    hits['n'] += 1
                    return await route.fulfill(status=400, content_type='application/json',
                        body='{"code":"PGRST204","message":"Could not find the \'tip_in_person_cents\' column of \'passengers\' in the schema cache"}')
                await route.fallback()
            await page.route('**/rest/v1/passengers?id=eq.960105*', no_col)
            await deliver(page, 960105, tip=True, amount='15')
            check(hits['n'] == 1 and row(960105) == 'DELIVERED|true|null', 'column missing: delivery not blocked (retried without the amount)', (hits, row(960105)))
            await page.unroute('**/rest/v1/passengers?id=eq.960105*')

            await page.wait_for_timeout(2000)
            types = sql("select string_agg(distinct message_type, ',') from public.airvalet_sms_messages where passenger_id = 960102")
            skip_types = sql("select string_agg(distinct message_type, ',') from public.airvalet_sms_messages where passenger_id = 960101")
            body = sql("select coalesce(string_agg(body, ' '), '') from public.airvalet_sms_messages where passenger_id = 960102")
            check(types and types == skip_types and '/a#' in body, 'in person $20: same delivered text as a skipped tip, with the pass link (digital gratuity still possible) (%s / %s)' % (types, skip_types))

            cr1 = await closing(page)
            check(cr1['stripe'] == cr0['stripe'] and cr1['other'] == cr0['other'] and cr1['otherInput'] == cr0['otherInput'] and cr1['total'] == cr0['total'],
                  'Closing Report: Stripe / Other / Total unchanged by in-person tips', (cr0, cr1))
            check('$20.00' in cr1['hint'] and '1 car' in cr1['hint'] and 'not added' in cr1['hint'], 'Closing Report: informational hint only', cr1['hint'])
            await page.screenshot(path=os.environ.get('SHOT_DIR', '/tmp') + '/stage1_staff_closing_hint_%s.png' % ENGINE)

            # Two devices deliver the same car at the same moment: delivered once.
            ctx2, page2 = await login(b)
            await reload_data(page); await reload_data(page2)
            for p in (page, page2):
                await p.evaluate('openTipModal(960106, "NORMAL")'); await p.wait_for_selector('#tipOv.on')
            await page2.click('#tipIpYes'); await page2.fill('#tipIpAmt', '10')
            await asyncio.gather(page.click('#tipYesBtn'), page2.click('#tipYesBtn'))
            await page.wait_for_timeout(3000)
            n = sql("select count(*) from public.activity_log where passenger_id = 960106 and action like 'DELIVERED%'")
            check(row(960106).startswith('DELIVERED|') and n == '1', 'two devices: one delivery, one history entry (%s, %s)' % (row(960106), n))
            await ctx2.close(); await ctx.close(); await b.close()
    finally:
        sql(CLEAN)
    print('\n%d ok, %d failed' % (oks, fails))
    sys.exit(1 if fails else 0)

asyncio.run(main())
