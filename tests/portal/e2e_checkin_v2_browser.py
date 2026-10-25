# LOCAL ONLY. Drives New Check-in v2 in Chromium against the local stack:
# app on http://127.0.0.1:8781 (scratch serve.py pointing at the local
# Supabase), send-sms in AIRVALET_SMS_MODE=mock (no Twilio). Every request to
# a host other than 127.0.0.1 / fonts is aborted, and epsonSend is stubbed in
# the page, so nothing can reach a printer.
#   python3 tests/portal/e2e_checkin_v2_browser.py <scratch portal dir> [screenshot dir]
import asyncio, re, subprocess, sys, time, xml.dom.minidom
from playwright.async_api import async_playwright

DIR = sys.argv[1]
OUT = sys.argv[2] if len(sys.argv) > 2 else None
APP = 'http://127.0.0.1:8781/'
PW = open(DIR + '/test_password.txt').read().strip()
RUN = str(int(time.time()) % 900 + 100)  # fictional 555 phones, unique per run
oks, fails = 0, 0
BLOCKED = []


def sql(q):
    r = subprocess.run(['docker', 'exec', '-i', 'supabase_db_airvalet-portal-local', 'psql', '-U', 'postgres', '-d', 'postgres', '-qAt', '-c', q],
                       capture_output=True, text=True)
    if r.returncode:
        raise RuntimeError(r.stderr)
    return r.stdout.strip()


def check(cond, msg, extra=''):
    global oks, fails
    if cond:
        oks += 1
        print('ok  ', msg)
    else:
        fails += 1
        print('FAIL', msg, extra)


def well_formed(x):
    try:
        xml.dom.minidom.parseString(x)
        return True
    except Exception:
        return False


async def guard(route):
    u = route.request.url
    if u.startswith('http://127.0.0.1') or 'fonts.g' in u or 'cdnjs' in u or 'jsdelivr' in u:
        await route.continue_()
    else:
        BLOCKED.append(u)
        await route.abort()


async def login(page):
    await page.goto(APP)
    await page.wait_for_selector('#loginEmail', state='visible', timeout=15000)
    for attempt in range(3):
        await page.wait_for_timeout(2000)  # the login screen resets its fields once on start
        await page.fill('#loginEmail', 'localipad')
        await page.fill('#loginPwd', PW)
        await page.press('#loginPwd', 'Enter')
        try:
            await page.wait_for_function('typeof _currentUserEmail !== "undefined" && !!_currentUserEmail && Array.isArray(data) && data.length > 0', timeout=15000)
            break
        except Exception:
            if attempt == 2:
                raise
    await page.wait_for_timeout(1500)
    # Approve this browser for AirValet texting (IPAD_OPS is auto-approved by 20261029).
    await page.evaluate('''async () => {
      const key = smsDeviceKey(true);
      await smsApi('/rest/v1/rpc/airvalet_sms_device_request', { method: 'POST', body: JSON.stringify({ p_device_key: key, p_label: 'E2E iPad', p_user_agent: 'e2e' }) });
      await resolveSmsProvider();
      window.__prints = [];
      window.epsonSend = async (xml, label) => { window.__prints.push({ xml, label }); return true; };
    }''')


async def open_new(page):
    await page.evaluate('openAdd()')
    await page.wait_for_selector('#ci2Name', state='visible')


async def fill(page, name, phone):
    await page.fill('#ci2Name', name)
    await page.click('#ci2Phone')
    await page.keyboard.type(phone)


async def create(page, name, phone, consent=True, before=None):
    await open_new(page)
    await fill(page, name, phone)
    if before:
        await before()
    await page.click('#ci2Yes' if consent else '#ci2No')
    if not consent:
        await page.click('#ci2NoText')
    await page.wait_for_selector('#ci2Created:not([hidden])', timeout=15000)
    return await page.evaluate('({ id: _ci.id, ticket: _ci.ticket })')


async def shot(page, name):
    if OUT:
        await page.screenshot(path=f'{OUT}/{name}.png', full_page=False)


async def main():
    async with async_playwright() as pw:
        b = await pw.chromium.launch()
        ctx = await b.new_context(viewport={'width': 820, 'height': 1180}, device_scale_factor=2)
        await ctx.route('**/*', guard)
        page = await ctx.new_page()
        errors = []
        page.on('pageerror', lambda e: errors.append(str(e)))
        try:
            await login(page)
        except Exception:
            print('blocked requests:', sorted(set(BLOCKED))[:10])
            raise
        check(await page.evaluate('smsProgramOpen()'), 'device approved and AirValet texting open (local mock)')

        # 1. Typing never sends; editing during the countdown cancels it.
        n0 = int(sql("select count(*) from passengers"))
        await open_new(page)
        await fill(page, 'E2E CANCEL', '30555' + RUN + '01')
        await page.click('#ci2Yes')
        await page.wait_for_timeout(1200)
        await page.click('#ci2Phone')
        await page.keyboard.press('Backspace')
        await page.wait_for_timeout(3000)
        check(await page.is_hidden('#ci2Created'), 'phone edited during the countdown → nothing created')
        check(int(sql("select count(*) from passengers")) == n0, '… and no passenger row')
        await page.evaluate('closeAll()')

        # 2. Happy path: name + phone + Tomorrow + Yes → one ticket, one welcome.
        phone = '30555' + RUN + '02'

        async def tomorrow():
            await page.click('.ci2-retpick[data-n="1"] [data-d]:nth-child(2)')
            await shot(page, 'v2-ipad-1-main')
        r = await create(page, 'E2E GUEST ONE', phone, before=tomorrow)
        await shot(page, 'v2-ipad-2-ticket')
        check(bool(r['id']) and bool(r['ticket']), 'ticket created after the countdown', r)
        row = sql(f"select status || '|' || ret || '|' || coalesce(return_operator,'') from passengers where id = {r['id']}")
        check(row.startswith('PENDING|'), 'return date saved with the check-in (PENDING)', row)
        check(sql(f"select count(*) from airvalet_sms_messages where passenger_id = {r['id']} and message_type = 'CHECK_IN'") == '1', 'exactly one welcome text (CHECK_IN)')
        check(await page.evaluate('_smsEnrolled[_ci.id] === true'), 'ticket enrolled in AirValet texting')
        await page.wait_for_timeout(1500)
        chip = await page.inner_text('#ci2Sms')
        check(re.search(r'sent|delivered', chip, re.I) is not None, 'card shows the text status', chip)
        # Second tap / second create call → still one ticket and one text.
        await page.evaluate('ci2Create(true)')
        await page.wait_for_timeout(800)
        check(sql(f"select count(*) from passengers where phone like '%{phone[-4:]}' and name = 'E2E GUEST ONE'") == '1', 'repeat create call → still one ticket')
        check(sql(f"select count(*) from airvalet_sms_messages where passenger_id = {r['id']} and message_type = 'CHECK_IN'") == '1', 'repeat create call → still one text')

        # 3. Return date changed later → same pass, no new text.
        await page.click('.ci2-row[data-open="ci2SRet"]')
        await page.click('#ci2SRet [data-cal="2"]')
        await page.click('#ci2SRet .ci2-cal-g button:not([disabled]):nth-of-type(5)')
        await page.wait_for_timeout(800)
        newret = sql(f"select ret from passengers where id = {r['id']}")
        check(newret != row.split('|')[1], 'return date changed after check-in (audited RPC)', newret)
        check(sql(f"select count(*) from airvalet_sms_messages where passenger_id = {r['id']}") == '1', 'date change → no new text')
        check(sql(f"select count(*) from airvalet_pass_links where passenger_id = {r['id']} and revoked_at is null") == '1', 'same valet pass link still active')
        await page.click('#ci2SRet [data-nodate]')
        await page.wait_for_timeout(800)
        check(sql(f"select status || '|' || coalesce(ret,'') from passengers where id = {r['id']}") == 'NO DATE|', 'No date → NO DATE, empty date')
        await page.click('#ci2SRet .ci2-other')
        await page.wait_for_timeout(800)
        check(sql(f"select return_operator from passengers where id = {r['id']}") == 'OTHER', 'another airline works with No date (return_operator OTHER)')
        check(sql(f"select coalesce(loc,'') from passengers where id = {r['id']}") == '', 'pickup place / location not changed automatically')
        check(sql(f"select count(*) from airvalet_sms_messages where passenger_id = {r['id']}") == '1', 'still one text after all return edits')

        # 4. Vehicle + hangar + color unlock Print key tag (manual, one tap).
        check(await page.is_disabled('#ci2Print'), 'Print key tag locked before Hangar + Make/Model + Color')
        await page.click('.ci2-sec-h >> text=Hangar')
        await page.click('#ci2Hangars button >> nth=0')
        await page.click('.ci2-row[data-open="ci2SVeh"]')
        await page.fill('#ci2MakeQ', 'cadil')
        await page.click('#ci2Makes button >> text=Cadillac')
        await page.click('#ci2Models button >> text=Escalade')
        check(await page.is_disabled('#ci2Print'), 'still locked without color')
        await page.click('#ci2Colors button >> text=Black')
        await page.wait_for_timeout(700)
        check(not await page.is_disabled('#ci2Print'), 'Print key tag unlocked')
        check(await page.evaluate('window.__prints.length') == 0, 'nothing printed automatically')
        check(sql(f"select car || '|' || color || '|' || loc from passengers where id = {r['id']}") == 'CADILLAC ESCALADE|Black|HANGAR 19', 'vehicle and hangar saved progressively')
        await shot(page, 'v2-ipad-3-details')

        # 5. Authorized pickup on the same ticket; nothing texted to that person.
        await page.click('.ci2-sec-h >> text=Someone else will pick up')
        await page.check('#ci2PickOn')
        await page.fill('#ci2PName', 'ANA SOUZA & CO')
        await page.click('#ci2PPhone')
        await page.keyboard.type('7865550111')
        await page.click('#ci2PLoc button >> text=Customs')
        await page.click('#ci2PSave')
        await page.wait_for_timeout(800)
        check(sql(f"select pickup_auth_name || '|' || pickup_auth_phone || '|' || pickup_auth_location from passengers where id = {r['id']}") == 'ANA SOUZA & CO|7865550111|Customs', 'authorization saved on the same ticket')
        check(sql("select count(*) from airvalet_sms_messages where phone_e164 = '+17865550111'") == '0', 'nothing texted to the pickup person')
        check(int(sql(f"select count(*) from passengers where phone like '%{phone[-4:]}' and name = 'E2E GUEST ONE'")) == 1, 'no second check-in created')
        sms_before = sql(f"select count(*) from airvalet_sms_messages where passenger_id = {r['id']}")
        pre = await page.evaluate('window.__prints.map(p => [p.label, String(p.xml).slice(0, 160)])')
        check(pre == [], 'nothing printed before the tap', pre)
        # Slow simulated printer (300 ms per job) so repeated taps land mid-print.
        await page.evaluate('() => { window.epsonSend = async (xml, label) => { window.__prints.push({ xml, label }); await new Promise(r => setTimeout(r, 300)); return true; } }')
        await page.click('#ci2Print')
        await page.evaluate("document.getElementById('ci2Print').click(); document.getElementById('ci2Print').click();")
        check(await page.inner_text('#ci2Print') == 'Printing…' and await page.is_disabled('#ci2Print'), 'while printing: button shows Printing… and is locked')
        await page.wait_for_timeout(1200)
        prints = await page.evaluate('window.__prints')
        labels = [p['label'] for p in prints]
        check(labels == ['Key', 'Dashboard'], 'Print key tag (3 fast taps) → exactly one Key tag + one Dashboard tag, no customer copy', labels)
        check(all(well_formed(p['xml']) for p in prints), 'print XML well-formed with "&" in the pickup name')
        check('AUTHORIZED PICKUP' in prints[0]['xml'] and 'ANA SOUZA &amp; CO' in prints[0]['xml'], 'key tag shows AUTHORIZED PICKUP + name (escaped)')
        check('DASHBOARD COPY' in prints[1]['xml'] and r['ticket'] in prints[1]['xml'], 'dashboard tag has the ticket number')
        check(await page.inner_text('#ci2Print') == 'Reprint ▾', 'button becomes Reprint')
        check(await page.is_hidden('#ci2Reprint'), 'reprint options closed until tapped')
        await page.click('#ci2Print')
        check(await page.is_visible('#ci2Reprint'), 'Reprint opens three options')
        await shot(page, 'v2-ipad-4-reprint')
        opts = await page.eval_on_selector_all('#ci2Reprint [data-print]', 'els => els.map(e => e.dataset.print)')
        check(opts == ['both', 'key', 'dash'], 'options: Print both / Key tag only / Dashboard tag only', opts)

        async def reprint(kind):
            await page.evaluate('window.__prints = []')
            if await page.is_hidden('#ci2Reprint'):
                await page.click('#ci2Print')
            await page.click(f'#ci2Reprint [data-print="{kind}"]')
            await page.wait_for_timeout(900)
            return [p['label'] for p in await page.evaluate('window.__prints')]
        check(await reprint('key') == ['Key'], 'Reprint → Key tag only')
        check(await page.is_hidden('#ci2Reprint'), 'menu closes after a choice')
        check(await reprint('dash') == ['Dashboard'], 'Reprint → Dashboard tag only')
        check(await reprint('both') == ['Key', 'Dashboard'], 'Reprint → Print both')
        await page.click('#ci2Print')
        await page.click('.ci2-sec-h >> text=Hangar')
        check(await page.is_hidden('#ci2Reprint'), 'tapping elsewhere closes the reprint menu')
        # A failed job is reported and can be reprinted on its own.
        await page.evaluate("() => { window.__prints = []; window.epsonSend = async (xml, label) => { window.__prints.push({ xml, label }); return label !== 'Dashboard'; } }")
        await page.click('#ci2Print'); await page.click('#ci2Reprint [data-print="both"]')
        await page.wait_for_timeout(600)
        check('Dashboard tag did not print' in await page.inner_text('#msg'), 'printer failure on the dashboard tag is reported', await page.inner_text('#msg'))
        await page.evaluate("() => { window.epsonSend = async (xml, label) => { window.__prints.push({ xml, label }); return true; } }")
        check(sql(f"select count(*) from airvalet_sms_messages where passenger_id = {r['id']}") == sms_before, 'printing never sends a text')
        # Data reloaded (as after a refresh of the list) → print uses the server row.
        await page.evaluate('loadData()')
        await page.wait_for_timeout(500)
        check(await reprint('both') == ['Key', 'Dashboard'], 'after reloading data → Print both still works')
        xml_after = (await page.evaluate('window.__prints'))[0]['xml']
        check('CADILLAC ESCALADE' in xml_after and 'ANA SOUZA &amp; CO' in xml_after and well_formed(xml_after), 'reloaded row prints vehicle + escaped pickup name')
        await page.evaluate('closeAll()')

        # 6. Delivery: ID check required; the database refuses a delivery without it.
        await page.evaluate(f'openTipModal({r["id"]}, "NORMAL")')
        await page.wait_for_timeout(300)
        check(await page.is_disabled('#tipYesBtn'), 'Deliver locked until the ID check')
        await shot(page, 'v2-ipad-5-delivery')
        await page.check('#relIdOk')
        check(not await page.is_disabled('#tipYesBtn'), 'ID checked → Deliver unlocked')
        await page.click('#tipYesBtn')
        await page.wait_for_timeout(1200)
        rel = sql(f"select status || '|' || released_to_name || '|' || released_to_kind || '|' || released_id_checked || '|' || coalesce(released_by,'') from passengers where id = {r['id']}")
        check(rel.startswith('DELIVERED|ANA SOUZA & CO|AUTHORIZED|true|localipad'), 'delivered and recorded who took the car + ID check + staff', rel)
        r2 = await create(page, 'E2E GUEST TWO', '30555' + RUN + '03')
        await page.evaluate('closeAll()')
        sql(f"update passengers set pickup_auth_name = 'SOMEONE' where id = {r2['id']}")
        await page.evaluate('loadData()')
        await page.wait_for_timeout(800)
        check(await page.evaluate(f'(data.find(x => x.id === {r2["id"]}) || {{}}).pickup_auth_name') == 'SOMEONE', 'authorization survives a reload (mapPassengerRow)')
        res = await page.evaluate(f'''async () => {{ try {{ await sbUpdate({r2["id"]}, {{ status: 'DELIVERED' }}); return 'updated'; }} catch (e) {{ return String(e.message); }} }}''')
        check('AUTHORIZED_PICKUP_ID_REQUIRED' in res, 'direct delivery without ID check → refused by the database', res)
        await page.evaluate(f'markDel({r2["id"]})')
        await page.wait_for_timeout(300)
        check(await page.is_visible('#tipOv') and await page.is_disabled('#tipYesBtn'), 'Mark as Delivered routes to the ID check')
        await page.evaluate('document.getElementById("tipOv").classList.remove("on")')
        # Revoke from the car panel.
        await page.evaluate(f'showDet({r2["id"]})')
        page.once('dialog', lambda d: asyncio.ensure_future(d.accept()))
        await page.evaluate(f'pickupAuthRevoke({r2["id"]})')
        await page.wait_for_timeout(800)
        dbg = await page.evaluate(f'(() => {{ const r = data.find(x => x.id === {r2["id"]}); return [r && r.pickup_auth_name, document.getElementById("msg").innerText]; }})()')
        check(sql(f"select coalesce(pickup_auth_name,'(none)') from passengers where id = {r2['id']}") == '(none)', 'authorization revoked from the car panel', dbg)
        await page.evaluate('closeAll()')

        # 7. Companion with the same phone → own ticket and own welcome.
        rc = await create(page, 'E2E COMPANION', phone)
        await page.wait_for_timeout(800)
        check(rc['ticket'] != r['ticket'], 'companion gets its own ticket', rc)
        st = sql(f"select status || '|' || coalesce(error_code,'') from airvalet_sms_messages where passenger_id = {rc['id']} and message_type = 'CHECK_IN'")
        check(st != '' and not st.startswith('blocked'), 'companion (same phone, < 2 min) gets its own welcome', st)
        await page.evaluate('closeAll()')

        # 8. No texts → ticket created, zero texts.
        rn = await create(page, 'E2E NO TEXTS', '30555' + RUN + '04', consent=False)
        check(sql(f"select count(*) from airvalet_sms_messages where passenger_id = {rn['id']}") == '0', 'No texts → ticket created, nothing sent')
        await page.evaluate('closeAll()')

        # 9. Provider failure (reserved mock number) → ticket kept, failure shown.
        rf = await create(page, 'E2E TWILIO FAIL', '3055550199')
        await page.wait_for_timeout(1500)
        chip = await page.inner_text('#ci2Sms')
        check(bool(rf['id']), 'provider failure → check-in still saved', rf)
        check(re.search(r'fail|not', chip, re.I) is not None, 'card shows the failure', chip)
        await shot(page, 'v2-ipad-6-twilio-fail')
        await page.evaluate('closeAll()')

        # 10. Offline (no offline device code locally) → NOT saved, form kept.
        n1 = int(sql("select count(*) from passengers"))
        await open_new(page)
        await fill(page, 'E2E OFFLINE', '30555' + RUN + '05')
        await ctx.set_offline(True)
        await page.click('#ci2Yes')
        await page.wait_for_timeout(5000)
        await ctx.set_offline(False)
        saved = await page.evaluate('_ci.created')
        offl = await page.evaluate('_ci.offline')
        if saved:
            check(offl, 'offline → saved in the offline queue, marked "text not sent"')
        else:
            check(await page.input_value('#ci2Name') == 'E2E OFFLINE', 'offline without offline access → NOT saved, typed entry kept')
        check(int(sql("select count(*) from passengers")) == n1, 'offline → nothing written to the server')
        await page.evaluate('closeAll()')

        # 10b. Full page reload: session kept, car panel prints both tags; classic form intact.
        await page.reload()
        await page.wait_for_function('typeof _currentUserEmail !== "undefined" && !!_currentUserEmail && Array.isArray(data) && data.length > 0', timeout=30000)
        await page.evaluate('() => { window.__prints = []; window.epsonSend = async (xml, label) => { window.__prints.push({ xml, label }); return true; } }')
        await page.evaluate(f'(async () => {{ const r = data.find(x => x.id === {r["id"]}); await printKeyTicket(r); await printDashboardTicket(r); }})()')
        await page.wait_for_timeout(400)
        labels = [p['label'] for p in await page.evaluate('window.__prints')]
        check(labels == ['Key', 'Dashboard'] and all(well_formed(p['xml']) for p in await page.evaluate('window.__prints')), 'after a page reload: Key + Dashboard print from the car record', labels)
        await page.evaluate("localStorage.setItem('airvalet_checkin_classic', '1'); openAdd();")
        check(await page.is_visible('#fName') and await page.is_hidden('#ci2') and await page.is_visible('#saveBtnPrint'), 'classic form: shown with its own Save + Print button')
        await page.evaluate('window.__prints = []')
        await page.fill('#fName', 'E2E CLASSIC & SON')
        await page.click('#fPhone'); await page.keyboard.type('30555' + RUN + '07')
        await page.fill('#fCar', 'B&W MINI')
        res = await page.evaluate("(async () => { document.getElementById('fStatus').value = 'NO DATE'; const r = await saveEntry(false, 'both'); return r; })()")
        await page.wait_for_timeout(500)
        labels = [p['label'] for p in await page.evaluate('window.__prints')]
        check(bool(res and res.get('ok')) and labels == ['Key', 'Dashboard'], 'classic Save + Print unchanged: Key + Dashboard', [res, labels])
        check(all(well_formed(p['xml']) for p in await page.evaluate('window.__prints')), 'classic print XML well-formed with "&"')
        check(not await page.evaluate("document.getElementById('addOv').classList.contains('on')"), 'classic save closes the form as before')
        cl = sql("select count(*) from airvalet_sms_messages m join passengers p on p.id = m.passenger_id where p.name = 'E2E CLASSIC & SON'")
        check(cl == '0', 'classic save without SMS sends nothing', cl)
        await page.evaluate("localStorage.removeItem('airvalet_checkin_classic'); closeAll();")

        # 11. iPhone layout smoke.
        await page.set_viewport_size({'width': 390, 'height': 844})
        await open_new(page)
        await fill(page, 'E2E IPHONE', '30555' + RUN + '06')
        await page.click('.ci2-retpick[data-n="1"] [data-cal="1"]')
        sw = await page.evaluate('document.documentElement.scrollWidth')
        check(sw <= 390, 'iPhone: no horizontal scroll', sw)
        await shot(page, 'v2-iphone-1-calendar')
        await page.evaluate('closeAll()')

        check(not errors, 'no page errors', errors)
        await b.close()
    # Let the scratch reseed.sh delete this test device again.
    sql("delete from airvalet_sms_enrollments where device_id in (select id from airvalet_sms_devices where label = 'E2E iPad')")
    print(f'\n{oks} passed, {fails} failed')
    sys.exit(1 if fails else 0)

asyncio.run(main())
