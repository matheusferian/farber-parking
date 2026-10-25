# LOCAL ONLY. Staff-app regressions from the 2026-10-25 full-system audit, in
# Chromium against the local stack (app on http://127.0.0.1:8781, send-sms in
# AIRVALET_SMS_MODE=mock). Hosts other than 127.0.0.1 / fonts are aborted and
# epsonSend is stubbed, so nothing reaches a printer or Twilio.
#   python3 tests/portal/e2e_audit_fixes_browser.py <scratch portal dir>
import asyncio, subprocess, sys, time
from playwright.async_api import async_playwright

DIR = sys.argv[1]
APP = 'http://127.0.0.1:8781/'
PW = open(DIR + '/test_password.txt').read().strip()
RUN = str(int(time.time()) % 900 + 100)
oks, fails = 0, 0


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


async def guard(route):
    u = route.request.url
    if u.startswith('http://127.0.0.1') or 'fonts.g' in u or 'cdnjs' in u or 'jsdelivr' in u:
        await route.continue_()
    else:
        await route.abort()


async def login(page):
    await page.goto(APP + '?checkin=v2')
    await page.wait_for_selector('#loginEmail', state='visible', timeout=15000)
    for attempt in range(3):
        await page.wait_for_timeout(2000)
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
    await page.evaluate('''async () => {
      const key = smsDeviceKey(true);
      await smsApi('/rest/v1/rpc/airvalet_sms_device_request', { method: 'POST', body: JSON.stringify({ p_device_key: key, p_label: 'E2E iPad', p_user_agent: 'e2e' }) });
      await resolveSmsProvider();
      window.__prints = [];
      window.epsonSend = async (xml, label) => { window.__prints.push({ xml, label }); return true; };
    }''')


async def create(page, name, phone):
    await page.evaluate('openAdd()')
    await page.wait_for_selector('#ci2Name', state='visible')
    await page.fill('#ci2Name', name)
    await page.click('#ci2Phone')
    await page.keyboard.type(phone)
    await page.click('#ci2Yes')
    await page.wait_for_selector('#ci2Created:not([hidden])', timeout=15000)
    return await page.evaluate('({ id: _ci.id, ticket: _ci.ticket })')


async def main():
    async with async_playwright() as pw:
        b = await pw.chromium.launch()
        ctx = await b.new_context(viewport={'width': 820, 'height': 1180})
        await ctx.route('**/*', guard)
        page = await ctx.new_page()
        errors = []
        page.on('pageerror', lambda e: errors.append(str(e)))
        page.on('dialog', lambda d: asyncio.ensure_future(d.accept()))
        await login(page)

        # 1. Printing P1-1: an update that changes 0 rows is an error, never "saved".
        t = await create(page, 'E2E ZERO ROWS', '30555' + RUN + '11')
        await page.evaluate('closeAll()')
        sql("delete from airvalet_sms_messages where passenger_id = %d; delete from airvalet_sms_enrollments where passenger_id = %d; "
            "delete from airvalet_pass_links where passenger_id = %d; delete from passengers where id = %d" % (t['id'], t['id'], t['id'], t['id']))
        msg = await page.evaluate("(async () => { try { await sbUpdate(%d, { obs: 'X' }); return 'saved'; } catch (e) { return e.message; } })()" % t['id'])
        check('not saved' in msg, 'row removed on another device → sbUpdate reports "not saved"', msg)

        # 2. Twilio F1: carrier timeout → "Unconfirmed", never "Not sent".
        t2 = await create(page, 'E2E TIMEOUT', '3055550198')
        await page.wait_for_function("_ci && _ci.smsState && _ci.smsState !== 'sending'", timeout=20000)
        st = await page.evaluate('_ci.smsState')
        txt = await page.inner_text('#ci2Sms')
        check(st == 'unconfirmed' and 'Not sent' not in txt, 'Twilio timeout → card says Unconfirmed, not "Not sent"', (st, txt))
        check(await page.query_selector('#ci2Sms button') is None, '… and offers no "Send from iPhone" (could double-text)')

        # 3. Print P2: when both tags fail, the ticket is not marked printed (Done still warns).
        await page.evaluate("() => { window.__prints = []; window.epsonSend = async (xml, label) => { window.__prints.push({ xml, label }); return false; } }")
        await page.evaluate("() => { _ci.hangar = 'HANGAR 19'; _ci.vehText = 'BMW X5'; _ci.color = 'BLACK'; ci2Need(); }")
        await page.evaluate('ci2Print("both")')
        check(await page.evaluate('_ci.printed') is False, 'both tags failed → not marked printed')
        await page.evaluate("() => { window.epsonSend = async (xml, label) => { window.__prints.push({ xml, label }); return label !== 'Dashboard'; } }")
        await page.evaluate('ci2Print("both")')
        check(await page.evaluate('_ci.printed') is True, 'one tag printed → marked printed (Reprint offered)')

        # 4. Printing P1-2: offline V2 keeps hangar/vehicle on the card and the tags use them.
        await page.evaluate("() => { _ci.offline = true; _ci.hangar = ''; _ci.vehText = ''; _ci.color = ''; _ci.printed = false; ci2RenderHangars(); ci2Need(); }")
        await page.evaluate("() => { document.querySelector('#ci2Hangars button').click(); }")
        await page.wait_for_timeout(300)
        hg = await page.evaluate('_ci.hangar')
        check(bool(hg), 'offline: hangar choice is kept on the card (not reverted)', hg)
        await page.evaluate("() => { _ci.vehText = 'TESLA MODEL Y'; ci2SetColor('WHITE'); }")
        check(await page.evaluate("!document.getElementById('ci2Print').disabled"), 'offline: Print Tags enabled with hangar + vehicle + color')
        await page.evaluate("() => { window.__prints = []; window.epsonSend = async (xml, label) => { window.__prints.push({ xml, label }); return true; } }")
        await page.evaluate('ci2Print("both")')
        key = await page.evaluate("(window.__prints.find(p => p.label === 'Key') || {}).xml || ''")
        check(hg in key and 'TESLA MODEL Y' in key, 'offline: key tag carries the hangar and vehicle from the card')
        await page.evaluate("() => { _ci.offline = false; }")
        await page.evaluate('closeAll()')

        # 5. Printing P2: car-panel print buttons run one job at a time.
        await page.evaluate("() => { window.__prints = []; window.epsonSend = async (xml, label) => { window.__prints.push({ xml, label }); await new Promise(r => setTimeout(r, 400)); return true; } }")
        n = await page.evaluate("""(async () => {
          const btn = document.createElement('button'); document.body.appendChild(btn);
          const p1 = panelPrintOnce(btn, printKeyTicket, %d), p2 = panelPrintOnce(btn, printKeyTicket, %d);
          await Promise.all([p1, p2]); btn.remove(); return window.__prints.length; })()""" % (t2['id'], t2['id']))
        check(n == 1, 'double tap on a car-panel print button → one job', n)

        # 6. Printing P2: Print All reports a failed customer copy even when the last tag works.
        await page.evaluate("() => { window.epsonSend = async (xml, label) => label !== 'Customer'; }")
        ok = await page.evaluate("printAllTickets(data.find(x => x.id === %d))" % t2['id'])
        m = await page.inner_text('#msg')
        check(ok is False and 'Customer copy' in m, 'Print All: failed customer copy is reported', m)

        # 7. Twilio F2: editing a reply after an uncertain attempt sends the NEW words.
        await page.evaluate("() => { _ibx.compose[%d] = { id: 'compose:e2e-fixed', text: 'old', tried: 'Old words' }; }" % t2['id'])
        cid = await page.evaluate("""(async () => {
          const ta = document.createElement('textarea'); ta.id = 'ibxText'; ta.value = 'New words'; document.body.appendChild(ta);
          let sent = null; const orig = window.sendServerSms;
          window.sendServerSms = async (pid, type, o) => { sent = o; return { ok: false, status: 'blocked', error: { code: 'NO_CONSENT' } }; };
          await sendInboxReply(%d); window.sendServerSms = orig; ta.remove(); return sent ? sent.eventRef : null; })()""" % t2['id'])
        check(cid and cid != 'compose:e2e-fixed', 'edited reply after an uncertain attempt → new compose id (new words go out)', cid)

        # 8. Printing P2-16: a car already delivered on another device is not delivered twice.
        t3 = await create(page, 'E2E DOUBLE DELIVER', '30555' + RUN + '13')
        await page.evaluate('closeAll()')
        sql("update passengers set status = 'DELIVERED' where id = %d" % t3['id'])
        n_log = int(sql("select count(*) from activity_log where passenger_id = %d and action like 'DELIVERED%%'" % t3['id']))
        n_sms = int(sql("select count(*) from airvalet_sms_messages where passenger_id = %d and message_type = 'VEHICLE_DELIVERED'" % t3['id']))
        okd = await page.evaluate("deliverWithTip(%d, 'NORMAL')" % t3['id'])
        await page.wait_for_timeout(1500)
        m = await page.inner_text('#msg')
        check('Already delivered on another device' in m, 'second device delivering → "Already delivered on another device"', m)
        check(int(sql("select count(*) from activity_log where passenger_id = %d and action like 'DELIVERED%%'" % t3['id'])) == n_log
              and int(sql("select count(*) from airvalet_sms_messages where passenger_id = %d and message_type = 'VEHICLE_DELIVERED'" % t3['id'])) == n_sms,
              '… no second history entry and no second delivered text')

        # 9. Keyboard: Name → Phone → … → "Yes, agreed" is reachable with Tab, and Enter on it starts the countdown.
        await page.evaluate('openAdd()')
        await page.wait_for_selector('#ci2Name', state='visible')
        await page.focus('#ci2Name')
        await page.keyboard.type('E2E KEYBOARD')
        await page.keyboard.press('Tab')
        f1 = await page.evaluate('document.activeElement.id')
        await page.keyboard.type('30555' + RUN + '14')
        seen = []
        for _ in range(25):
            await page.keyboard.press('Tab')
            fid = await page.evaluate('document.activeElement.id || document.activeElement.textContent.trim().slice(0, 20)')
            seen.append(fid)
            if fid == 'ci2Yes':
                break
        check(f1 == 'ci2Phone' and 'ci2Yes' in seen, 'keyboard: Tab goes Name → Phone and reaches "Yes, agreed"', (f1, seen))
        vis = await page.evaluate("getComputedStyle(document.activeElement).outlineStyle !== 'none' || getComputedStyle(document.activeElement).boxShadow !== 'none'")
        check(vis, 'keyboard: focused button shows a visible focus ring')
        await page.keyboard.press('Enter')
        await page.wait_for_selector('#ci2Created:not([hidden])', timeout=15000)
        check(True, 'keyboard: Enter on "Yes, agreed" creates the ticket after the countdown')
        await page.evaluate('closeAll()')

        check(not errors, 'no page errors', errors)
        await b.close()
    sql("""do $$ declare r record; begin
      create temp table e2e_ids on commit drop as select id from passengers where name like 'E2E %';
      for r in select conrelid::regclass t, a.attname c from pg_constraint k join pg_attribute a on a.attrelid = k.conrelid and a.attnum = any(k.conkey)
               where k.contype = 'f' and k.confrelid = 'public.passengers'::regclass loop
        execute format('delete from %s where %I in (select id from e2e_ids)', r.t, r.c);
      end loop;
      delete from airvalet_sms_messages where passenger_id in (select id from e2e_ids);
      delete from passengers where id in (select id from e2e_ids);
    end $$""")
    sql("delete from airvalet_sms_enrollments where device_id in (select id from airvalet_sms_devices where label = 'E2E iPad')")
    print(f'\n{oks} passed, {fails} failed')
    sys.exit(1 if fails else 0)

asyncio.run(main())
