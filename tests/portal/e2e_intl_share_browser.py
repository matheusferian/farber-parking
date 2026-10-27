# LOCAL ONLY. International guests (2026-10-26): a non-US number (or a +1
# Caribbean area code) never goes through Twilio. Check-in v2 creates the
# ticket + valet pass link, and staff send it by WhatsApp or iMessage from the
# device. Real browser against the local stack (send-sms in mock). Fictional data.
#   python3 tests/portal/e2e_intl_share_browser.py <scratch portal dir> [engine]
import asyncio, os, subprocess, sys, time, urllib.parse
from playwright.async_api import async_playwright

DIR = sys.argv[1]
ENGINE = sys.argv[2] if len(sys.argv) > 2 else 'chromium'
APP = os.environ.get('APP', 'http://127.0.0.1:8781/')
PW = open(DIR + '/test_password.txt').read().strip()
RUN = str(int(time.time()) % 900 + 100)
TAG = 'E2E INTL ' + ENGINE[:2].upper() + ' '
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
        oks += 1; print('ok  ', f'[{ENGINE}]', msg)
    else:
        fails += 1; print('FAIL', f'[{ENGINE}]', msg, extra)


def cleanup():
    sql("""do $$ declare r record; begin
      create temp table e2e_ids on commit drop as select id from passengers where name like 'E2E INTL %';
      for r in select conrelid::regclass t, a.attname c from pg_constraint k join pg_attribute a on a.attrelid = k.conrelid and a.attnum = any(k.conkey)
               where k.contype = 'f' and k.confrelid = 'public.passengers'::regclass loop
        execute format('delete from %s where %I in (select id from e2e_ids)', r.t, r.c);
      end loop;
      delete from airvalet_sms_messages where passenger_id in (select id from e2e_ids);
      delete from airvalet_sms_enrollments where passenger_id in (select id from e2e_ids);
      delete from airvalet_pass_links where passenger_id in (select id from e2e_ids);
      delete from passengers where id in (select id from e2e_ids);
    end $$""")


async def login(page, user='localipad'):
    await page.goto(APP + '?checkin=v2')
    await page.wait_for_selector('#loginEmail', state='visible', timeout=20000)
    for attempt in range(3):
        await page.wait_for_timeout(1500)
        await page.fill('#loginEmail', user); await page.fill('#loginPwd', PW); await page.press('#loginPwd', 'Enter')
        try:
            await page.wait_for_function('typeof _currentUserEmail !== "undefined" && !!_currentUserEmail && Array.isArray(data) && data.length > 0', timeout=20000)
            break
        except Exception:
            if attempt == 2: raise
    await page.wait_for_timeout(1500)
    await page.evaluate('''async () => {
      try {
        const key = smsDeviceKey(true);
        await smsApi('/rest/v1/rpc/airvalet_sms_device_request', { method: 'POST', body: JSON.stringify({ p_device_key: key, p_label: 'E2E iPad', p_user_agent: 'e2e' }) });
        await resolveSmsProvider();
      } catch (e) {}
      window.__prints = []; window.epsonSend = async (xml, label) => { window.__prints.push({ xml, label }); return true; };
      window.confirm = () => true;
    }''')


async def v2_fill(page, name, phone):
    await page.evaluate('openAdd()')
    await page.wait_for_selector('#ci2Name', state='visible')
    await page.fill('#ci2Name', name)
    await page.click('#ci2Phone'); await page.keyboard.type(phone)


async def v2_yes(page):
    await page.click('#ci2Yes')
    await page.wait_for_selector('#ci2Created:not([hidden])', timeout=20000)
    return await page.evaluate('({ id: _ci.id, ticket: _ci.ticket })')


def links(page_html_hrefs):
    wa = [h for h in page_html_hrefs if h.startswith('https://wa.me/')]
    im = [h for h in page_html_hrefs if h.startswith('sms:')]
    return wa, im


async def main():
    cleanup()
    async with async_playwright() as pw:
        kw = {'executable_path': os.environ['WEBKIT_PATH']} if ENGINE == 'webkit' and os.environ.get('WEBKIT_PATH') else {}
        b = await getattr(pw, ENGINE).launch(**kw)
        ctx = await b.new_context(viewport={'width': 820, 'height': 1180}, service_workers='block')
        page = await ctx.new_page(); errs = []
        page.on('pageerror', lambda e: errs.append(str(e)))
        await login(page)
        check(await page.evaluate('smsRouteFor(-1) === "native" && isServerSms()'), 'device is in AirValet texting (server SMS)')

        # A/B — German number, typed with +
        name = TAG + 'GER ' + RUN
        await v2_fill(page, name, '+49 151 61461188')
        v = await page.input_value('#ci2Phone')
        check(v == '+4915161461188', 'typed +49 number keeps its country code', v)
        hint = await page.text_content('#ci2PhoneHint')
        check('International' in hint, 'hint says international, no SMS', hint)
        check(await page.evaluate("document.getElementById('ci2PhoneOk').classList.contains('on')"), 'number shown as valid')
        cd = []
        await page.click('#ci2Yes'); await page.wait_for_timeout(400)
        cd.append(await page.text_content('#ci2CdText'))
        check('valet pass link' in cd[0] and 'sending' not in cd[0], 'countdown says "valet pass link", not "sending"', cd[0])
        await page.wait_for_selector('#ci2Created:not([hidden])', timeout=20000)
        g = await page.evaluate('({ id: _ci.id, ticket: _ci.ticket })')
        await page.wait_for_selector('#ci2Sms.share', timeout=20000)
        hrefs = await page.eval_on_selector_all('#ci2Sms a', 'as => as.map(a => a.getAttribute("href"))')
        wa, im = links(hrefs)
        check(len(wa) == 1 and wa[0].startswith('https://wa.me/4915161461188?text='), 'WhatsApp button goes to his number', hrefs)
        check(len(im) == 1 and im[0].startswith('sms:+4915161461188&body='), 'iMessage / Text button goes to +49 number', hrefs)
        body = urllib.parse.unquote(wa[0].split('?text=', 1)[1]) if wa else ''
        check('Welcome to Makers Air Valet!' in body and '/a#' in body and 'STOP' not in body, 'message = welcome + valet pass link, no STOP line', body)
        tok = body.split('/a#', 1)[1].strip() if '/a#' in body else ''
        pid = g['id']
        check(sql("select phone from passengers where id=%d" % pid) == '+4915161461188', 'phone stored with country code')
        check(sql("select count(*) from airvalet_sms_enrollments where passenger_id=%d" % pid) == '1', 'consent + enrollment recorded')
        check(sql("select count(*) from airvalet_pass_links where passenger_id=%d and revoked_at is null and token_hash = extensions.digest('%s','sha256')" % (pid, tok)) == '1', 'the shared link is the active valet pass link')
        check(sql("select count(*) from airvalet_sms_messages where passenger_id=%d" % pid) == '0', 'no SMS row at all (nothing to Twilio)')
        check(await page.evaluate('smsRouteFor(%d)' % pid) == 'native', 'later texts for this guest never use the server')
        r = await page.evaluate("sendServerSms(%d, 'REPLY', { eventRef: 'e2e-intl-%s', customBody: 'hello' })" % (pid, RUN))
        check(r.get('error', {}).get('code') == 'INTERNATIONAL_NO_TWILIO', 'server refuses a Twilio text to this number', r)
        check(sql("select count(*) from airvalet_sms_messages where passenger_id=%d" % pid) == '0', 'still no SMS row after a direct server try')
        await page.evaluate('closeAll()')

        # F — ticket panel: new link + buttons
        await page.evaluate('showDet(%d); document.getElementById("detOv").classList.add("on")' % pid)
        await page.wait_for_selector('#vpStaffSec .vps', timeout=15000)
        check(await page.locator('#vpStaffSec', has_text='Send pass link').count() == 1, 'ticket shows the Valet Pass panel with "Send pass link"')
        check(await page.locator('#vpStaffSec', has_text='Ready to Go').count() == 1, 'Ready / Customs / Lockbox controls still there for this guest')
        await page.click('#vpStaffSec button:has-text("Send pass link")')
        await page.wait_for_function("/just created/.test(document.getElementById('vpShare').textContent)", timeout=15000)
        check(sql("select count(*) from airvalet_pass_links where passenger_id=%d" % pid) == '1', 'double tap right after check-in: no new link (the sent one keeps working)')
        sql("update airvalet_pass_links set created_at = created_at - interval '3 minutes' where passenger_id=%d" % pid)
        await page.click('#vpStaffSec button:has-text("Send pass link")')
        await page.wait_for_selector('#vpShare a.share-wa', timeout=15000)
        h2 = await page.eval_on_selector_all('#vpShare a', 'as => as.map(a => a.getAttribute("href"))')
        wa2, im2 = links(h2)
        check(len(wa2) == 1 and len(im2) == 1, 'panel shows WhatsApp + iMessage buttons', h2)
        check(sql("select count(*) from airvalet_pass_links where passenger_id=%d and revoked_at is null" % pid) == '1'
              and sql("select count(*) from airvalet_pass_links where passenger_id=%d" % pid) == '2', 'new link replaces the old one (1 active)')
        check(sql("select count(*) from activity_log where passenger_id=%d and detail like 'Valet pass link created to share%% · device %%'" % pid) == '2', 'each link is in the activity log, with the device')
        r = await page.evaluate("(async () => { const h = sbHeaders(); const res = await fetch(SUPABASE_URL + '/functions/v1/pass-share', { method: 'POST', headers: h, body: JSON.stringify({ passenger_id: %d }) }); return res.json(); })()" % pid)
        check((r.get('error') or {}).get('code') == 'DEVICE_NOT_AUTHORIZED', 'pass-share refuses a device that is not approved', r)
        await page.evaluate('document.getElementById("detOv").classList.remove("on")')

        # G — any other text to this guest: chooser WhatsApp / iMessage
        await page.evaluate("sendNativeSms({ passengerId: %d, passengerName: 'GER', phone: '+4915161461188', body: 'Your car is ready.' })" % pid)
        await page.wait_for_selector('#shareOv a.share-wa', timeout=5000)
        h3 = await page.eval_on_selector_all('#shareOv a', 'as => as.map(a => a.getAttribute("href"))')
        check(any(h.startswith('https://wa.me/4915161461188?text=Your%20car') for h in h3) and any(h.startswith('sms:+4915161461188&body=Your%20car') for h in h3),
              'other texts to him open a WhatsApp / iMessage chooser', h3)
        await page.click('#shareOv .share-x')
        check(await page.locator('#shareOv').count() == 0, 'chooser closes on Cancel')

        check('🇩🇪' in (await page.evaluate("guestPhoneCountry('+4915161461188').flag")), 'Germany flag for +49')

        # C — Jamaica (+1 876): international (Twilio bills it as international)
        name2 = TAG + 'JAM ' + RUN
        await v2_fill(page, name2, '8765550' + RUN[-3:].rjust(3, '0'))
        hint = await page.text_content('#ci2PhoneHint')
        check('International' in hint and 'Jamaica' in hint and '🇯🇲' in hint, 'Jamaica 876 recognised as international, with flag', hint)
        g2 = await v2_yes(page)
        await page.wait_for_selector('#ci2Sms.share', timeout=20000)
        h4 = await page.eval_on_selector_all('#ci2Sms a', 'as => as.map(a => a.getAttribute("href"))')
        check(any(h.startswith('https://wa.me/1876555') for h in h4), 'Jamaica: WhatsApp with +1 876', h4)
        check(sql("select count(*) from airvalet_sms_messages where passenger_id=%d" % g2['id']) == '0', 'Jamaica: no SMS row')
        await page.evaluate('closeAll()')

        # C2 — Bahamas (+1 242): texted by AirValet like the US (owner 2026-10-26)
        name5 = TAG + 'BAH ' + RUN
        await v2_fill(page, name5, '2423270' + RUN[-3:].rjust(3, '0'))
        hint = await page.text_content('#ci2PhoneHint')
        badge = await page.text_content('#ci2PhoneOk')
        check('Bahamas' in hint and 'International' not in hint and '🇧🇸' in badge, 'Bahamas: flag + "texted by AirValet"', [hint, badge])
        g5 = await v2_yes(page)
        await page.wait_for_function("document.querySelector('#ci2Sms') && /Sent|Sending/.test(document.querySelector('#ci2Sms').textContent)", timeout=20000)
        check(await page.locator('#ci2Sms a.share-wa').count() == 0, 'Bahamas: no WhatsApp buttons')
        await page.wait_for_timeout(1500)
        check(sql("select count(*) from airvalet_sms_messages where passenger_id=%d and message_type='CHECK_IN'" % g5['id']) == '1', 'Bahamas: welcome SMS by the server')
        await page.evaluate('closeAll()')

        # E — typed without +: never guessed as another country (audit v77 P1-a); the hint asks for +
        await v2_fill(page, TAG + 'AUTO ' + RUN, '4915161461188')
        v = await page.input_value('#ci2Phone')
        await page.evaluate("document.getElementById('ci2Phone').blur()")
        hint = await page.text_content('#ci2PhoneHint')
        check(v == '4915161461188' and 'start with +' in hint, 'number without + is not guessed; hint says to start with +', [v, hint])
        await page.evaluate('closeAll()')

        # P1-a: one extra digit never turns a US number into another country
        await v2_fill(page, TAG + 'TYPO ' + RUN, '30555501019')
        v = await page.input_value('#ci2Phone'); hint = await page.text_content('#ci2PhoneHint')
        check(v == '30555501019' and 'International' not in hint and not await page.evaluate("ci2PhoneValid(document.getElementById('ci2Phone').value)"),
              'US number + 1 extra digit: stays US and invalid (no Greece)', [v, hint])
        await page.evaluate('closeAll()')
        # P2-d: 00 typed digit by digit
        await v2_fill(page, TAG + 'ZERO ' + RUN, '004915161461188')
        v = await page.input_value('#ci2Phone')
        check(v == '+4915161461188', '00 + country code typed key by key becomes +', v)
        await page.evaluate('closeAll()')
        # P2-a: +1 with 9 digits is not valid
        check(not await page.evaluate("ci2PhoneValid('+1305555010')") and await page.evaluate("ci2PhoneValid('+13055550101')"), '+1 needs exactly 10 more digits')
        check(await page.evaluate("fmtP('+4915161461188')") == '+4915161461188' and await page.evaluate("fmtP('3055550101')") == '(305) 555-0101', 'international number displayed as typed (not as a US number)')

        # D — US number unchanged: welcome SMS through the server (mock)
        name3 = TAG + 'US ' + RUN
        await v2_fill(page, name3, '305555' + RUN[-3:] + '7')
        v = await page.input_value('#ci2Phone')
        check(v.startswith('(305) 555-'), 'US number keeps the (305) 555-0142 format', v)
        hint = await page.text_content('#ci2PhoneHint')
        check('International' not in hint and '🇺🇸' in hint, 'US number: US flag, no international hint', hint)
        g3 = await v2_yes(page)
        await page.wait_for_function("document.querySelector('#ci2Sms') && !document.querySelector('#ci2Sms.share') && /Sent|Sending/.test(document.querySelector('#ci2Sms').textContent)", timeout=20000)
        check(await page.locator('#ci2Sms a.share-wa').count() == 0, 'US number: no WhatsApp buttons')
        await page.wait_for_timeout(1500)
        check(sql("select count(*) from airvalet_sms_messages where passenger_id=%d and message_type='CHECK_IN'" % g3['id']) == '1', 'US number: welcome SMS sent by the server as before')
        await page.evaluate('closeAll()')

        # classic form accepts the international format too
        await page.evaluate("localStorage.removeItem('airvalet_checkin_v2'); openAdd()")
        await page.wait_for_selector('#fPhone', state='visible')
        await page.click('#fPhone'); await page.keyboard.type('+44 20 7946 0958')
        v = await page.input_value('#fPhone')
        check(v == '+442079460958', 'classic form keeps the + country code', v)
        # P1-b: classic check-in with consent → WhatsApp / iMessage with the valet pass link
        await page.fill('#fName', TAG + 'CLASSIC ' + RUN)
        await page.evaluate("(()=>{ const c = document.getElementById('fSmsConsent'); if (c) c.checked = true; })()")
        res = await page.evaluate("saveEntry(true, null, {}).then(r => r && { ok: r.ok, id: r.id })")
        await page.wait_for_selector('#shareOv a.share-wa', timeout=20000)
        h5 = await page.eval_on_selector_all('#shareOv a', 'as => as.map(a => a.getAttribute("href"))')
        check(any(h.startswith('https://wa.me/442079460958?text=') and '%2Fa%23' in h for h in h5), 'classic form: WhatsApp with the valet pass link', h5)
        await page.click('#shareOv .share-x')
        await page.evaluate("closeAll(); localStorage.setItem('airvalet_checkin_v2','1')")

        check(not errs, 'no page errors', errs[:3])
        await ctx.close(); await b.close()
    cleanup()
    print('%d passed, %d failed' % (oks, fails))

asyncio.run(main())
