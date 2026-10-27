# LOCAL ONLY. Smart Tips (2026-10-27): in-person tip at Deliver (Yes / No / nothing,
# cash amount, who received it) → audited ledger; double tap / two devices / retry;
# car card Tips (correct with reason, add later, Stripe separate); manual delivery
# message (mock SMS, only with an active Valet Pass link); Closing Report cash
# reconciliation (empty / reconciled / Other Tips / short + review); Valet Pass
# thank-you without amount (iPhone). Replaces e2e_delivery_in_person_tip_browser.py (v85).
# Needs 20261113 applied to the LOCAL stack. App served by serve_root.py (APP_ROOT = this
# worktree); send-sms in AIRVALET_SMS_MODE=mock; every other host is aborted.
#   APP=http://127.0.0.1:8797/ ENGINE=chromium|webkit SHOT_DIR=… python3 tests/portal/e2e_smart_tips_browser.py <dir with test_password.txt>
import asyncio, json, os, subprocess, sys
from playwright.async_api import async_playwright

DIR = sys.argv[1]
APP = os.environ.get('APP', 'http://127.0.0.1:8797/')
ENGINE = os.environ.get('ENGINE', 'chromium')
SHOT = os.environ.get('SHOT_DIR', '/tmp')
FN_ORIGIN = 'http://127.0.0.1:8781'   # the origin the local functions allow (CORS)
PW = open(DIR + '/test_password.txt').read().strip()
oks, fails = 0, 0
IDS = range(970101, 970113)


def sql(q):
    r = subprocess.run(['docker', 'exec', '-i', 'supabase_db_airvalet-portal-local', 'psql', '-U', 'postgres', '-d', 'postgres', '-qAt', '-c', q], capture_output=True, text=True)
    if r.returncode: raise RuntimeError(r.stderr)
    return r.stdout.strip()


def check(cond, msg, extra=''):
    global oks, fails
    if cond: oks += 1; print('ok  ', msg)
    else: fails += 1; print('FAIL', msg, extra)


TODAY = "(now() at time zone 'America/New_York')::date"
CLEAN = """
delete from public.daily_closing_reports where report_date = %(t)s and created_by like 'localipad%%';
delete from public.airvalet_tip_records where passenger_id between 970101 and 970112;
delete from public.valet_shifts where valet_name = 'JOAO SILVA E2E';
delete from public.payments where passenger_id between 970101 and 970112;
delete from public.airvalet_sms_messages where passenger_id between 970101 and 970112;
delete from public.airvalet_sms_consents where passenger_id between 970101 and 970112 or disclosure_version = 'e2e-smart-tips';
delete from public.airvalet_notify_log where dedupe_key like '%%9701%%';
delete from public.airvalet_pass_links where passenger_id between 970101 and 970112;
delete from public.airvalet_sms_enrollments where passenger_id between 970101 and 970112;
delete from public.vehicle_location_history where passenger_id between 970101 and 970112;
delete from public.activity_log where passenger_id between 970101 and 970112;
delete from public.passengers where id between 970101 and 970112;
""" % {'t': TODAY}
FIX = """
insert into public.passengers (id, ts, checkin_date, name, phone, ticket, status, ret, loc, car, color, return_operator) values
""" + ',\n'.join("(%d, 'x', now(), 'SMART TIP %d', '30555572%02d', 'ST-%d', 'PENDING', to_char(%s, 'FMMM/FMDD/YYYY'), 'HANGAR 16', 'BMW X5', 'Black', 'MAKERS')"
                 % (i, i - 970100, i - 970100, i - 970100, TODAY) for i in IDS) + """;
insert into public.airvalet_sms_enrollments (passenger_id, phone_e164, device_id, consent_id)
select p.id, public.airvalet_sms_normalize_phone(p.phone), (select id from public.airvalet_sms_devices where status = 'approved' order by decided_at limit 1), gen_random_uuid()
  from public.passengers p where p.id between 970101 and 970111;   -- 970112 = older ticket, never enrolled
insert into public.airvalet_sms_consents (phone_e164, passenger_id, status, method, disclosure_version)
select public.airvalet_sms_normalize_phone(p.phone), p.id, 'granted', 'checkin_attendant', 'e2e-smart-tips'
  from public.passengers p where p.id between 970101 and 970111;
insert into public.valet_shifts (valet_name, business_date, clock_in_at) values ('JOAO SILVA E2E', %s, now() - interval '3 hours');
""" % TODAY


def car(pid):
    return sql("select status || '|' || coalesce(tip_received::text, 'null') || '|' || coalesce(tip_in_person_cents::text, 'null') from public.passengers where id = %d" % pid)


def ledger(pid):
    return sql("select coalesce(string_agg(amount_cents || ':' || source || ':' || recorded_by || ':' || coalesce(received_by_name, '-') || ':' || (voided_at is not null), ',' order by id), '') from public.airvalet_tip_records where passenger_id = %d" % pid)


async def guard(route):
    u = route.request.url
    if '/functions/v1/' in u and u.startswith('http://127.0.0.1:56331'):
        # Test harness only: present the origin the local functions allow, give the answer back to this page.
        h = dict(route.request.headers); h['origin'] = FN_ORIGIN
        try:
            resp = await route.fetch(headers=h)
        except Exception:
            return await route.abort()
        rh = dict(resp.headers); rh['access-control-allow-origin'] = APP.rstrip('/')
        return await route.fulfill(response=resp, headers=rh)
    if u.startswith('http://127.0.0.1') or 'fonts.g' in u or 'cdnjs' in u or 'jsdelivr' in u: await route.continue_()
    else: await route.abort()


async def login(b, viewport=None, user='localipad'):
    ctx = await b.new_context(viewport=viewport or {'width': 820, 'height': 1180}, service_workers='block')
    await ctx.route('**/*', guard)
    page = await ctx.new_page()
    page.on('dialog', lambda d: asyncio.ensure_future(d.accept()))
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
    await page.evaluate('''async () => {
      const key = smsDeviceKey(true);
      await smsApi('/rest/v1/rpc/airvalet_sms_device_request', { method: 'POST', body: JSON.stringify({ p_device_key: key, p_label: 'E2E iPad', p_user_agent: 'e2e' }) });
      await resolveSmsProvider();
      window.epsonSend = async () => true;
      window._msgs = []; var _sm = showMsg; window.showMsg = function (t, e) { window._msgs.push(String(t)); return _sm.apply(this, arguments); };
    }''')
    await reload_data(page)
    return ctx, page


async def reload_data(page):
    await page.evaluate('loadData()'); await page.wait_for_function('data.some(function(r){return r.id===970101})', timeout=15000)
    await page.evaluate('loadSmsEnrollments && loadSmsEnrollments()') if await page.evaluate('typeof loadSmsEnrollments === "function"') else None
    await page.evaluate('''() => { for (var i = 970101; i <= 970111; i++) _smsEnrolled[i] = true; }''')


async def open_modal(page, pid):
    await page.evaluate('openTipModal(%d, "NORMAL")' % pid)
    await page.wait_for_selector('#tipOv.on', timeout=5000)
    await page.wait_for_timeout(500)


async def deliver(page, pid, answer=None, amount=None, who=False):
    await open_modal(page, pid)
    if answer == 'YES': await page.click('#tipIpY')
    if answer == 'NO': await page.click('#tipIpN')
    if amount is not None: await page.fill('#tipIpAmt', amount)
    if who:
        await page.wait_for_selector('#tipIpWho button[data-who="JOAO SILVA E2E"]', timeout=5000)
        await page.click('#tipIpWho button[data-who="JOAO SILVA E2E"]')
    await page.click('#tipYesBtn')
    await page.wait_for_function('!document.getElementById("tipOv").classList.contains("on")', timeout=15000)
    await page.wait_for_timeout(1500)
    msg = await page.evaluate('window._msgs.splice(0).join(" / ")')
    await page.evaluate('''() => { document.querySelectorAll('.ov.on').forEach(function(o){ o.classList.remove('on'); }); }''')
    return msg


async def card(page, pid):
    await page.evaluate('''() => { document.querySelectorAll('.ov.on').forEach(function(o){ o.classList.remove('on'); }); }''')
    await page.evaluate('showDet(%d)' % pid)
    await page.wait_for_function('document.querySelector("#tipsSec .stp-row")', timeout=10000)
    await page.wait_for_timeout(400)
    return await page.evaluate('document.getElementById("tipsSec").innerText')


async def closing_state(page):
    return await page.evaluate('''() => ({ a: _crCashTicketsCents, n: _crCashTicketsN, b: _crCashCountedCents, other: (document.getElementById('crOtherTipsCalc')||{}).textContent,
      total: (document.getElementById('crTotalTips')||{}).textContent, recon: (function(e){ return e && !e.hidden ? e.className + '|' + e.innerText : ''; })(document.getElementById('crRecon')),
      stripe: _crStripeTipsCents, screen: (document.querySelector('#pane-closingreport [id$="Screen"]:not([style*="none"])')||{}).id })''')


async def main():
    sql(CLEAN); sql(FIX)
    pre = sql("select count(*) from public.daily_closing_reports where report_date = %s" % TODAY)
    if pre != '0':
        print('SKIP: a closing report for today already exists in the local DB; refusing to touch it'); sys.exit(2)
    try:
        async with async_playwright() as pw:
            kw = {'executable_path': os.environ['WEBKIT_PATH']} if ENGINE == 'webkit' and os.environ.get('WEBKIT_PATH') else {}
            b = await getattr(pw, ENGINE).launch(**kw)
            ctx, page = await login(b)

            # ── Deliver modal ───────────────────────────────────────────
            await open_modal(page, 970101)
            st = await page.evaluate('''() => ({ y: document.getElementById('tipIpY').getAttribute('aria-pressed'), n: document.getElementById('tipIpN').getAttribute('aria-pressed'),
              more: document.getElementById('tipIpMore').hidden, deliver: document.getElementById('tipYesBtn').disabled,
              hy: Math.round(document.getElementById('tipIpY').getBoundingClientRect().height) })''')
            check(st['y'] == 'false' and st['n'] == 'false' and st['more'] and not st['deliver'], 'modal: nothing pre-selected, amount hidden, Deliver enabled', st)
            check(st['hy'] >= 44, 'modal: Yes/No are 44 px targets', st)
            await page.click('#tipIpY'); await page.wait_for_selector('#tipIpWho button[data-who]', timeout=5000)
            await page.fill('#tipIpAmt', '20'); await page.click('#tipIpWho button[data-who="JOAO SILVA E2E"]')
            await page.wait_for_timeout(300)
            await page.screenshot(path=SHOT + '/smart_tips_deliver_ipad_%s.png' % ENGINE)
            await page.click('#tipIpY')   # tap again = back to "not answered"
            check(await page.evaluate('document.getElementById("tipIpMore").hidden && document.getElementById("tipIpAmt").value === ""'), 'modal: tapping Yes again clears the answer and the amount')
            await page.evaluate('closeTipModal()')

            await deliver(page, 970101)
            check(car(970101) == 'DELIVERED|null|null' and ledger(970101) == '', 'nothing answered: delivered, tip unknown, no ledger row', (car(970101), ledger(970101)))
            await deliver(page, 970102, 'NO')
            check(car(970102) == 'DELIVERED|false|null' and ledger(970102) == '', 'No: tip_received false, no ledger row', car(970102))
            m = await deliver(page, 970103, 'YES', '20', who=True)
            check(car(970103) == 'DELIVERED|true|2000', 'Yes $20: car mirror 2000', car(970103))
            check(ledger(970103) == '2000:DELIVERY:localipad@airvalet.local:JOAO SILVA E2E:false', 'Yes $20: ledger row (cash, who = login, received by on-shift valet)', ledger(970103))
            check('cash tip $20.00 saved' in m, 'Yes $20: staff see it saved', m)
            hist = sql("select string_agg(action || ' ' || detail, ' / ') from public.activity_log where passenger_id = 970103")
            check('TIP CASH Cash tip recorded: $20.00 | Received by JOAO SILVA E2E' in hist and 'Tip in person: YES (cash' in hist, 'ticket history: delivery note + cash tip line', hist)
            await deliver(page, 970104, 'YES')
            check(car(970104) == 'DELIVERED|true|null' and ledger(970104) == '', 'Yes, no amount: tip received, amount unknown (never $0)', (car(970104), ledger(970104)))
            m = await deliver(page, 970105, 'YES', '0')
            check(car(970105) == 'DELIVERED|true|null' and ledger(970105) == '' and 'not saved' in m, '$0 typed: still delivered, nothing stored, staff warned', (car(970105), m))
            m = await deliver(page, 970106, 'YES', '12.345')
            check(car(970106).startswith('DELIVERED|true') and ledger(970106) == '', 'junk amount: still delivered, nothing stored', car(970106))

            # Double tap on Deliver (same modal): one delivery, one ledger row.
            await open_modal(page, 970107)
            await page.click('#tipIpY'); await page.fill('#tipIpAmt', '15')
            await page.evaluate('''() => { var b = document.getElementById('tipYesBtn'); b.click(); b.click(); b.click(); }''')
            await page.wait_for_timeout(3500)
            nd = sql("select count(*) from public.activity_log where passenger_id = 970107 and action like 'DELIVERED%'")
            check(ledger(970107) == '1500:DELIVERY:localipad@airvalet.local:-:false' and nd == '1', 'triple tap: one delivery, one $15 row', (ledger(970107), nd))
            await page.evaluate('''() => { document.querySelectorAll('.ov.on').forEach(function(o){ o.classList.remove('on'); }); }''')

            # Retry of the same request (network retry): same key → same row.
            k = await page.evaluate('tipNewKey()')
            r1 = await page.evaluate('tipRpc("airvalet_tip_record", {p_passenger_id: 970101, p_amount_cents: 500, p_client_key: "%s", p_received_by: null, p_source: "ADDED_LATER"})' % k)
            r2 = await page.evaluate('tipRpc("airvalet_tip_record", {p_passenger_id: 970101, p_amount_cents: 500, p_client_key: "%s", p_received_by: null, p_source: "ADDED_LATER"})' % k)
            check(r1['result'] == 'OK' and r2.get('duplicate') is True and r1['tip']['id'] == r2['tip']['id'] and ledger(970101).count(':') == 4,
                  'same key twice (retry): one row', (r1.get('result'), r2.get('duplicate')))
            neg = await page.evaluate('tipRpc("airvalet_tip_record", {p_passenger_id: 970102, p_amount_cents: -100, p_client_key: tipNewKey(), p_received_by: null, p_source: "ADDED_LATER"})')
            check(neg['result'] == 'INVALID' and ledger(970102) == '', 'negative amount refused by the server', neg)
            direct = await page.evaluate('''async () => (await fetch(SUPABASE_URL + '/rest/v1/airvalet_tip_records', {method: 'POST', headers: Object.assign({}, sbHeaders(), {'Content-Type': 'application/json'}),
              body: JSON.stringify({passenger_id: 970102, amount_cents: 999, source: 'DELIVERY', business_date: '2026-10-27', recorded_by: 'fake'})})).status''')
            check(direct in (401, 403) and ledger(970102) == '', 'direct REST insert into the ledger refused (%s)' % direct)
            patch = await page.evaluate('''async () => (await fetch(SUPABASE_URL + '/rest/v1/passengers?id=eq.970103', {method: 'PATCH', headers: Object.assign({}, sbHeaders(), {'Content-Type': 'application/json'}),
              body: JSON.stringify({tip_in_person_cents: 99900})})).status''')
            check(patch >= 400 and car(970103) == 'DELIVERED|true|2000', 'direct REST change of a recorded amount refused (%s)' % patch)

            # Two devices deliver the same car at the same moment.
            ctx2, page2 = await login(b)
            await reload_data(page)
            for p in (page, page2):
                await open_modal(p, 970108)
                await p.click('#tipIpY'); await p.fill('#tipIpAmt', '10' if p is page else '12')
            await asyncio.gather(page.click('#tipYesBtn'), page2.click('#tipYesBtn'))
            await page.wait_for_timeout(3500)
            nd = sql("select count(*) from public.activity_log where passenger_id = 970108 and action like 'DELIVERED%'")
            lg = ledger(970108)
            check(car(970108).startswith('DELIVERED|true') and nd == '1' and lg.count(',') == 0 and lg != '', 'two devices: one delivery, one cash row (%s, %s)' % (nd, lg))
            await ctx2.close()
            await page.evaluate('''() => { document.querySelectorAll('.ov.on').forEach(function(o){ o.classList.remove('on'); }); }''')

            # ── Car card: Tips, correction, add later ───────────────────
            await reload_data(page)
            t = await card(page, 970103)
            check('$20.00' in t and 'Recorded by localipad' in t and 'received by JOAO SILVA E2E' in t and 'None confirmed' in t, 'card: cash $20 with who/when, Stripe separate', t)
            await page.locator('#tipsSec').scroll_into_view_if_needed(); await page.wait_for_timeout(300)
            await page.screenshot(path=SHOT + '/smart_tips_card_ipad_%s.png' % ENGINE)
            await page.click('#tipsSec button:has-text("Correct")'); await page.wait_for_selector('#tipFixOv.on')
            await page.fill('#tipFixAmt', '25'); await page.click('#tipFixSave'); await page.wait_for_timeout(600)
            err = await page.evaluate('document.getElementById("tipFixMsg").innerText')
            check('reason' in err.lower() and ledger(970103).count(',') == 0, 'correction without a reason is refused', err)
            await page.fill('#tipFixReason', 'Typed 20, it was 25')
            await page.screenshot(path=SHOT + '/smart_tips_correct_ipad_%s.png' % ENGINE)
            await page.click('#tipFixSave'); await page.wait_for_timeout(1500)
            lg = ledger(970103)
            check(lg == '2000:DELIVERY:localipad@airvalet.local:JOAO SILVA E2E:true,2500:CORRECTION:localipad@airvalet.local:JOAO SILVA E2E:false' and car(970103) == 'DELIVERED|true|2500',
                  'corrected $20 → $25: old row kept + voided, new row, car mirror 2500', lg)
            t = await card(page, 970103)
            await page.locator('#tipsSec').scroll_into_view_if_needed(); await page.wait_for_timeout(300)
            await page.screenshot(path=SHOT + '/smart_tips_card_corrected_ipad_%s.png' % ENGINE)
            check('$25.00' in t and 'Typed 20, it was 25' in t and 'corrected by localipad' in t, 'card shows the history of the correction', t)
            t = await card(page, 970104)
            check('amount not recorded' in t and 'Add amount' in t, 'card: tip received without amount → Add amount', t)
            await page.click('#tipsSec button:has-text("Add amount")'); await page.wait_for_selector('#tipFixOv.on')
            await page.fill('#tipFixAmt', '8'); await page.click('#tipFixSave'); await page.wait_for_timeout(1500)
            check(ledger(970104) == '800:ADDED_LATER:localipad@airvalet.local:-:false', 'add later: $8 audited', ledger(970104))

            # ── Manual delivery message ─────────────────────────────────
            await page.wait_for_timeout(1500)
            sql("update public.airvalet_pass_links set revoked_at = now(), revoke_reason = 'e2e' where passenger_id = 970111 and revoked_at is null")
            sql("update public.passengers set status = 'DELIVERED', checkout_date = now(), deldate = to_char(%s, 'FMMM/FMDD/YYYY'), delivery_type = 'NORMAL' where id in (970111, 970112)" % TODAY)
            await reload_data(page)
            t = await card(page, 970112)
            check('No Valet Pass for this ticket' in t and not await page.is_visible('#tipsSec button:has-text("Send")'), 'older ticket (no pass): no send button, no link created', t)
            t = await card(page, 970111)
            check('link expired' in t and not await page.is_visible('#tipsSec button:has-text("Send")'), 'no active link: nothing to send (no new link)', t)
            links0 = sql("select count(*) from public.airvalet_pass_links where passenger_id in (970111, 970112)")
            # Delivered text already sent at delivery → staff cannot send it again.
            t = await card(page, 970102)
            check('Sent:' in t and 'Only a manager can send it again' in t and not await page.is_visible('#tipsSec button:has-text("Send")'),
                  'already texted at delivery: staff get no second Send', t)
            # Automatic text still in flight, then failed: staff never get a second Send (no duplicate).
            sql("update public.airvalet_sms_messages set status = 'pending' where passenger_id = 970106 and direction = 'outbound'")
            t = await card(page, 970106)
            check('Sent: pending' in t and not await page.is_visible('#tipsSec button:has-text("Send")'), 'automatic text in flight: no manual Send', t)
            sql("update public.airvalet_sms_messages set status = 'failed', error_code = '30003' where passenger_id = 970106 and direction = 'outbound'")
            t = await card(page, 970106)
            check('not delivered' in t and 'Only a manager' in t and not await page.is_visible('#tipsSec button:has-text("Send")'), 'automatic text failed: staff cannot resend (manager only)', t)
            dup = await page.evaluate('sendServerSms(970106, "VEHICLE_DELIVERED")')
            check(dup.get('duplicate') is True and sql("select count(*) from public.airvalet_sms_messages where passenger_id = 970106") == '1', 'staff force-sending anyway: server refuses a duplicate')
            # Delivered text did not go out (e.g. delivered on a device not approved for texting) → staff can send it.
            await deliver(page, 970110)
            sql("delete from public.airvalet_sms_messages where passenger_id = 970110")
            await reload_data(page)
            t = await card(page, 970110)
            check('Not sent yet' in t and await page.is_visible('#tipsSec button:has-text("Send")'), 'not texted at delivery + active pass: Send offered', t)
            await page.click('#tipsSec button:has-text("Send")')
            await page.wait_for_selector('#svPrevOv.on', timeout=8000)
            await page.wait_for_function('!document.getElementById("svPrevSend").disabled', timeout=15000)
            prev = await page.evaluate('document.getElementById("svPrevBody").innerText')
            body = [l for l in prev.split('\n') if 'left you a note' in l]
            check(body and '/a#' in body[0] and not any(w in body[0].lower() for w in ('tip', 'gratuity', 'stripe', 'buy.')), 'preview: exact text with the pass link, no tip ask', prev)
            await page.screenshot(path=SHOT + '/smart_tips_sms_preview_ipad_%s.png' % ENGINE)
            await page.click('#svPrevSend'); await page.wait_for_timeout(3000)
            sent = sql("select string_agg(status || ':' || provider, ',') from public.airvalet_sms_messages where passenger_id = 970110 and idempotency_key = 'pax:970110:VEHICLE_DELIVERED:delivered'")
            check(sent and 'mock' in sent, 'manual send: one mock text (%s)' % sent, await page.evaluate('window._msgs.join(" / ")'))
            t = await card(page, 970110)
            check('Sent:' in t and not await page.is_visible('#tipsSec button:has-text("Send")'), 'after the manual send: no second Send for staff', t)
            again = await page.evaluate('sendServerSms(970110, "VEHICLE_DELIVERED")')
            check(again.get('duplicate') is True and sql("select count(*) from public.airvalet_sms_messages where passenger_id = 970110") == '1', 'tapping again / another device: not sent twice')
            # Manager / ADMIN: send again once.
            sql("update public.airvalet_sms_messages set created_at = created_at - interval '10 minutes' where passenger_id = 970102")
            mctx, mpage = await login(b, user='localadmin')   # ADMIN devices are auto-approved for texting
            t = await card(mpage, 970106)
            check(await mpage.is_visible('#tipsSec button:has-text("Send again")'), 'failed automatic text: ADMIN may send it again', t)
            t = await card(mpage, 970102)
            check(await mpage.is_visible('#tipsSec button:has-text("Send again")'), 'ADMIN: Send again offered', t)
            await mpage.click('#tipsSec button:has-text("Send again")')
            await mpage.wait_for_selector('#svPrevOv.on', timeout=8000)
            await mpage.wait_for_function('!document.getElementById("svPrevSend").disabled', timeout=15000)
            await mpage.click('#svPrevSend'); await mpage.wait_for_timeout(3000)
            rs = sql("select string_agg(status || ':' || provider, ',') from public.airvalet_sms_messages where passenger_id = 970102 and idempotency_key = 'pax:970102:VEHICLE_DELIVERED:resend:delivered-manual'")
            check(rs and 'mock' in rs, 'manager resend: one mock text with its own key (%s)' % rs, await mpage.evaluate('window._msgs.join(" / ")'))
            t = await card(mpage, 970102)
            check('Sent again by a manager' in t and not await mpage.is_visible('#tipsSec button:has-text("Send")'), 'after the resend: no more buttons', t)
            again = await mpage.evaluate('sendServerSms(970102, "VEHICLE_DELIVERED", {eventRef: "resend:delivered-manual"})')
            check(again.get('duplicate') is True, 'second resend: duplicate, not sent again')
            await mctx.close()
            check(sql("select count(*) from public.airvalet_pass_links where passenger_id in (970111, 970112)") == links0, 'no retroactive link created')
            check(sql("select count(*) from public.airvalet_sms_messages where passenger_id between 970101 and 970112 and provider <> 'mock'") == '0', 'no real SMS (mock provider only)')

            # ── Stripe gratuity (as the webhook records it) ─────────────
            sql("insert into public.payments (passenger_id, ticket, amount_cents, type, method, status, stripe_event_id, stripe_checkout_session_id) values "
                "(970110, 'ST-10', 1500, 'TIP', 'STRIPE', 'succeeded', 'evt_e2e_st_1', 'cs_e2e_st_1'), (970109, 'ST-9', 900, 'TIP', 'STRIPE', 'refunded', 'evt_e2e_st_2', 'cs_e2e_st_2')")
            t = await card(page, 970110)
            check('$15.00 · confirmed' in t and 'Not recorded' in t, 'card: Stripe $15 confirmed, separate from cash', t)

            # ── Closing Report ──────────────────────────────────────────
            sql("update public.valet_shifts set clock_out_at = now() where valet_name = 'JOAO SILVA E2E'")
            await page.evaluate('''() => { document.querySelectorAll('.ov.on').forEach(function(o){ o.classList.remove('on'); }); }''')
            await page.evaluate('''() => { var t = document.querySelector('.tab[data-t="closingreport"]'); if (t) t.click(); }''')
            await page.wait_for_timeout(3500)
            a_db = int(sql("select coalesce(sum(amount_cents), 0) from public.airvalet_tip_records where business_date = %s and voided_at is null" % TODAY))
            s0 = await closing_state(page)
            check(s0['a'] == a_db and s0['b'] is None and s0['total'] == '—' and 'type the total' in s0['recon'], 'Closing: A = ledger total ($%.2f), B empty, total waits for B' % (a_db / 100), s0)
            await page.evaluate('crShowPreview()'); await page.wait_for_timeout(800)
            m = await page.evaluate('document.getElementById("msg").innerText')
            check('Total Cash Counted' in m, 'Closing: preview blocked until the cash is counted', m)
            stripe = s0['stripe']
            stripe_db = int(sql("select coalesce(sum(amount_cents), 0) from public.payments where type = 'TIP' and status = 'succeeded' and (created_at at time zone 'America/New_York')::date = %s" % TODAY))
            check(stripe == stripe_db and stripe >= 1500, 'Closing: Stripe Tips = confirmed Stripe only ($%.2f, refunded excluded)' % (stripe / 100), (stripe, stripe_db))
            await page.fill('#crCashCounted', '%.2f' % (a_db / 100))
            s1 = await closing_state(page)
            check('ok|' in s1['recon'] and s1['other'] == '$0.00' and s1['total'] == '$%.2f' % ((stripe + a_db) / 100), 'B = A: reconciled, Other $0, total = Stripe + B', s1)
            await page.fill('#crCashCounted', '%.2f' % ((a_db + 1250) / 100))
            s2 = await closing_state(page)
            check(s2['other'] == '$12.50' and 'info|' in s2['recon'] and s2['total'] == '$%.2f' % ((stripe + a_db + 1250) / 100), 'B > A: Other Tips $12.50; total = Stripe + B (not A + B)', s2)
            await page.screenshot(path=SHOT + '/smart_tips_closing_other_ipad_%s.png' % ENGINE, full_page=True)
            await page.fill('#crCashCounted', '%.2f' % ((a_db - 500) / 100))
            s3 = await closing_state(page)
            check(s3['other'] == '$0.00' and 'bad|' in s3['recon'] and 'Difference −$5.00' in s3['recon'] and 'ST-' in s3['recon'], 'B < A: no negative Other Tips, difference −$5.00 with the tickets to review', s3)
            await page.locator('#crRecon').scroll_into_view_if_needed()
            await page.screenshot(path=SHOT + '/smart_tips_closing_short_ipad_%s.png' % ENGINE)
            await page.evaluate('crShowPreview()'); await page.wait_for_timeout(1000)
            m = await page.evaluate('document.getElementById("msg").innerText')
            check('review' in m.lower(), 'short: preview blocked until the review is confirmed', m)
            await page.check('#crReviewAck')
            await page.evaluate('crShowPreview()'); await page.wait_for_timeout(1500)
            pv = await page.evaluate('(document.getElementById("crPreviewCard")||{}).innerText || ""')
            check('Total Cash Counted' in pv and 'Cash difference' in pv and '−$5.00' in pv, 'preview: cash rows + reviewed difference', pv)
            await page.screenshot(path=SHOT + '/smart_tips_closing_preview_ipad_%s.png' % ENGINE)
            await page.evaluate('crGenerateReport()'); await page.wait_for_timeout(5000)
            row = sql("select cash_counted_cents || '|' || ticket_cash_tips_cents || '|' || other_tips_cents || '|' || cash_difference_cents || '|' || cash_reconciliation || '|' || cash_review_ack || '|' || total_tips_cents || '|' || stripe_tips_cents from public.daily_closing_reports where report_date = %s" % TODAY)
            exp = '%d|%d|0|-500|SHORT|true|%d|%d' % (a_db - 500, a_db, stripe + a_db - 500, stripe)
            check(row == exp, 'saved report: B, A, Other 0, −$5, reviewed, total = Stripe + B', (row, exp))
            png = await page.evaluate('crBuildExportMarkup(_crSavedReport)')
            check('Total Cash Counted' in png and 'Cash difference' in png and 'Cash Tips on tickets' in png, 'shared PNG carries the cash rows')
            late = await page.evaluate('tipRpc("airvalet_tip_record", {p_passenger_id: 970102, p_amount_cents: 700, p_client_key: tipNewKey(), p_received_by: null, p_source: "ADDED_LATER"})')
            check(late['result'] == 'DAY_CLOSED', 'after closing: staff cannot add a tip to the closed day', late)
            await ctx.close()

            # ── iPhone staff login: same modal and card at 390 px ─────
            ictx, ipage = await login(b, viewport={'width': 390, 'height': 844}, user='localiphone')
            await open_modal(ipage, 970109); await ipage.click('#tipIpY'); await ipage.fill('#tipIpAmt', '40')
            await ipage.wait_for_timeout(300)
            w = await ipage.evaluate('Math.round(document.querySelector("#tipOv .modal").getBoundingClientRect().width)')
            check(w <= 390 and await ipage.evaluate('document.documentElement.scrollWidth <= 390'), 'iPhone: modal fits 390 px, no sideways scroll (%s)' % w)
            await ipage.screenshot(path=SHOT + '/smart_tips_deliver_iphone_%s.png' % ENGINE)
            await ipage.evaluate('closeTipModal()')
            await card(ipage, 970103); await ipage.locator('#tipsSec').scroll_into_view_if_needed(); await ipage.wait_for_timeout(300)
            await ipage.screenshot(path=SHOT + '/smart_tips_card_iphone_%s.png' % ENGINE)
            await ictx.close()

            # ── Valet Pass (iPhone): thank-you, never the amount ────────
            tok_tip = sql("select public.airvalet_pass_mint(970103)")
            tok_no = sql("select public.airvalet_pass_mint(970102)")
            sql("update public.airvalet_portal_settings set portal_enabled = true")
            pctx = await b.new_context(viewport={'width': 390, 'height': 844}, device_scale_factor=2, is_mobile=ENGINE == 'chromium', has_touch=True, service_workers='block')
            await pctx.route('**/*', guard)
            pp = await pctx.new_page()
            tok_stripe = sql("select public.airvalet_pass_mint(970110)")
            for tok, label in ((tok_tip, 'tip'), (tok_no, 'notip'), (tok_stripe, 'stripe')):
                await pp.goto(APP + 'a#' + tok); await pp.wait_for_selector('.pass', timeout=20000); await pp.wait_for_timeout(2500)
                txt = await pp.evaluate('document.querySelector("main").innerText')
                grat_card = await pp.evaluate('!!document.querySelector("section.grat")')
                quiet = await pp.evaluate('!!document.querySelector(".list [data-open=\\"gratuity\\"]")')
                if label == 'tip':
                    check('Thank you for your kindness' in txt and not grat_card and quiet and '$25' not in txt and '25.00' not in txt,
                          'pass with tip in person: thank-you, no gratuity card, quiet optional row, no amount', txt[:300])
                elif label == 'stripe':
                    check('Thank you for your kindness' in txt and not grat_card and quiet and '15' not in txt.replace('ST-10', ''),
                          'pass after a confirmed Stripe gratuity: thank-you, no highlighted ask, quiet optional row, no amount', txt[:300])
                    await pp.screenshot(path=SHOT + '/smart_tips_pass_stripe_thanks_iphone_%s.png' % ENGINE, full_page=True)
                    sql("update public.payments set status = 'refunded' where stripe_event_id = 'evt_e2e_st_1'")
                    await pp.reload(); await pp.wait_for_selector('.pass', timeout=20000); await pp.wait_for_timeout(2500)
                    check(await pp.evaluate('!!document.querySelector("section.grat")'), 'Stripe gratuity refunded → pass back to the normal gratuity card')
                else:
                    check('Thank you for trusting us' in txt and grat_card and 'kindness' not in txt, 'pass without tip: unchanged (gratuity card shown)', txt[:200])
                await pp.screenshot(path=SHOT + '/smart_tips_pass_%s_iphone_%s.png' % (label, ENGINE), full_page=True)
            await pctx.close(); await b.close()
    finally:
        sql(CLEAN)
        sql("delete from public.daily_closing_reports where report_date = %s" % TODAY)   # none existed before (checked above)
        sql("update public.airvalet_pass_links set revoked_at = now() where passenger_id between 970101 and 970112 and revoked_at is null")
    print('\n%d ok, %d failed' % (oks, fails))
    sys.exit(1 if fails else 0)

asyncio.run(main())
