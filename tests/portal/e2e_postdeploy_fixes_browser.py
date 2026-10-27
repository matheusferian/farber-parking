# LOCAL ONLY. Fixes from the post-deploy audit (2026-10-25), in a real browser
# against the local stack (send-sms in mock, printer stubbed). Fictional data.
#   F1  guest consent / welcome survive a network blip during the upload
#   F2  hangar / vehicle added on the V2 card while the record is uploading
#   F3  failed duplicate lookup → retry, never "Not uploaded"
#   L   older records: the confirm lists what is on the device right now;
#       the Debug test record is never uploaded
#   C   Inbox marks messages read only while someone is looking at them
#   G   Closing Report: "Other Tips" starts empty; tips read again at preview
#   M   Debug "Test Append" is for admins only
#   K   passenger chat: text edited after a lost answer is not dropped
#   python3 tests/portal/e2e_postdeploy_fixes_browser.py <scratch portal dir> [engine]
import asyncio, os, subprocess, sys, time
from playwright.async_api import async_playwright

DIR = sys.argv[1]
ENGINE = sys.argv[2] if len(sys.argv) > 2 else 'chromium'
APP = 'http://127.0.0.1:8781/'
PW = open(DIR + '/test_password.txt').read().strip()
RUN = str(int(time.time()) % 900 + 100)
TAG = 'E2E PDF ' + ENGINE[:2].upper() + ' '
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


def n_pax(name_like):
    return int(sql("select count(*) from passengers where name like '%s'" % name_like))


def pid_of(name):
    v = sql("select id from passengers where name = '%s'" % name)
    return int(v) if v else 0


async def guard(route):
    u = route.request.url
    if u.startswith('http://127.0.0.1') or 'fonts.g' in u or 'cdnjs' in u or 'jsdelivr' in u:
        await route.continue_()
    else:
        await route.abort()


# Fault injection inside the page (same in Chromium and WebKit):
# window.__faults = [{ re, method, n, mode: 'throw' | 'status' | 'lose' | 'delay', status, ms }]
FAULTS = '''() => {
  if (window.__fx) return; window.__fx = true;
  const real = window.fetch; window.__faults = [];
  window.fetch = async (u, o) => {
    const m = (o && o.method) || 'GET';
    const f = window.__faults.find(x => x.n > 0 && new RegExp(x.re).test(String(u)) && (!x.method || x.method === m) && (!x.body || String(o && o.body || '').includes(x.body)));
    if (f) {
      f.n--;
      if (f.mode === 'throw') throw new TypeError('Failed to fetch (test)');
      if (f.mode === 'status') return new Response(JSON.stringify({ message: 'test ' + f.status }), { status: f.status, headers: { 'content-type': 'application/json' } });
      if (f.mode === 'lose') { await real(u, o); throw new TypeError('answer lost (test)'); }
      if (f.mode === 'delay') { await new Promise(r => setTimeout(r, f.ms || 3000)); }
    }
    return real(u, o);
  };
}'''


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
    await page.evaluate(FAULTS)


async def offline(ctx, page):
    await ctx.set_offline(True); await page.evaluate("window.dispatchEvent(new Event('offline'))"); await asyncio.sleep(0.3)


async def online(ctx, page):
    await ctx.set_offline(False); await page.evaluate("window.dispatchEvent(new Event('online'))")


async def hold_sync(page):
    await page.evaluate('() => { if (!window.__realSync) window.__realSync = offlineSyncPending; window.offlineSyncPending = async () => ({ skipped: "held by test" }); }')


async def release_sync(page):
    await page.evaluate('() => { window.offlineSyncPending = window.__realSync; }')


async def v2_create(page, name, phone, consent=False, close=True):
    await page.evaluate('openAdd()')
    await page.wait_for_selector('#ci2Name', state='visible')
    await page.fill('#ci2Name', name)
    await page.click('#ci2Phone'); await page.keyboard.type(phone)
    await page.click('#ci2Yes' if consent else '#ci2No')
    if not consent:
        await page.click('#ci2NoText')
    await page.wait_for_selector('#ci2Created:not([hidden])', timeout=20000)
    out = await page.evaluate('({ id: _ci.id, ticket: _ci.ticket, offline: _ci.offline, syncId: _ci.syncId })')
    if close:
        await page.evaluate('closeAll()')
    return out


async def rec(page, sync_id):
    return await page.evaluate('(id) => offlineCheckinGet(id)', sync_id)


def cleanup():
    sql("""do $$ declare r record; begin
      create temp table e2e_ids on commit drop as select id from passengers where name like 'E2E PDF %' or id = 951301;
      for r in select conrelid::regclass t, a.attname c from pg_constraint k join pg_attribute a on a.attrelid = k.conrelid and a.attnum = any(k.conkey)
               where k.contype = 'f' and k.confrelid = 'public.passengers'::regclass loop
        execute format('delete from %s where %I in (select id from e2e_ids)', r.t, r.c);
      end loop;
      delete from airvalet_sms_messages where passenger_id in (select id from e2e_ids);
      delete from airvalet_sms_enrollments where passenger_id in (select id from e2e_ids);
      delete from airvalet_pass_links where passenger_id in (select id from e2e_ids);
      delete from passengers where id in (select id from e2e_ids);
    end $$""")
    sql("delete from activity_log where passenger like 'E2E PDF %'")


async def main():
    cleanup()
    async with async_playwright() as pw:
        kw = {'executable_path': os.environ['WEBKIT_PATH']} if ENGINE == 'webkit' and os.environ.get('WEBKIT_PATH') else {}
        browser = await (pw.webkit if ENGINE == 'webkit' else pw.chromium).launch(**kw)
        ctx = await browser.new_context(viewport={'width': 820, 'height': 1180})
        await ctx.route('**/*', guard)
        page = await ctx.new_page()
        errors = []
        page.on('pageerror', lambda e: errors.append(str(e)))
        await login(page)
        await page.evaluate('closeAll()')

        # ── F1a. Consent call gets no answer during the upload ─────────────
        await hold_sync(page); await offline(ctx, page)
        a = await v2_create(page, TAG + 'CONSENT', '30555' + RUN + '11', consent=True)
        await online(ctx, page); await page.wait_for_timeout(1500); await release_sync(page)
        await page.evaluate("() => { window.__faults.push({ re: 'rpc/airvalet_sms_record_consent', method: 'POST', n: 1, mode: 'throw' }); }")
        await page.evaluate('offlineSyncPending(true)')
        pa = pid_of(TAG + 'CONSENT')
        r1 = await rec(page, a['syncId'])
        check(pa and r1 and r1.get('syncState') == 'SYNCED_SMS_PENDING' and r1.get('smsPending') == 'consent',
              'F1: no answer to the consent call → passenger uploaded, consent kept for a retry (not dropped)', r1 and {k: r1.get(k) for k in ('syncState', 'smsPending', 'lastError')})
        check(sql("select count(*) from airvalet_sms_enrollments where passenger_id = %d" % pa) == '0', 'F1: nothing enrolled yet, no text sent yet')
        check(await page.evaluate("data.filter(r => r.isOfflinePending && String(r.name).includes('CONSENT')).length") == 0, 'F1: the car is not listed twice (server row only)')
        await page.evaluate('offlineSyncPending(true)'); await page.wait_for_timeout(1500)
        check(sql("select count(*) from airvalet_sms_enrollments where passenger_id = %d" % pa) == '1', 'F1: retry records the consent (ticket enrolled)')
        check(sql("select count(*) from airvalet_sms_messages where passenger_id = %d and message_type = 'CHECK_IN'" % pa) == '1', 'F1: exactly one welcome after the retry')
        check(await rec(page, a['syncId']) is None, 'F1: record removed from the device once the text went out')

        # ── F1b. Texting state unknown (status check failed) ───────────────
        await hold_sync(page); await offline(ctx, page)
        b = await v2_create(page, TAG + 'DEVSTATE', '30555' + RUN + '12', consent=True)
        await online(ctx, page); await page.wait_for_timeout(1500); await release_sync(page)
        await page.evaluate("() => { window.__faults.push({ re: 'rpc/airvalet_sms_device_status', method: 'POST', n: 1, mode: 'throw' }); }")
        await page.evaluate('offlineSyncPending(true)')
        pb = pid_of(TAG + 'DEVSTATE')
        r2 = await rec(page, b['syncId'])
        check(pb and r2 and r2.get('smsPending') == 'consent', 'F1: device texting state unknown → consent kept, not "send from iPhone"', r2 and r2.get('syncState'))
        await page.evaluate('offlineSyncPending(true)'); await page.wait_for_timeout(1500)
        check(sql("select count(*) from airvalet_sms_enrollments where passenger_id = %d" % pb) == '1'
              and sql("select count(*) from airvalet_sms_messages where passenger_id = %d and message_type = 'CHECK_IN'" % pb) == '1', 'F1: next run enrolls and sends one welcome')

        # ── F1c. Welcome request gets no answer ───────────────────────────
        await hold_sync(page); await offline(ctx, page)
        c = await v2_create(page, TAG + 'WELCOME', '30555' + RUN + '13', consent=True)
        await online(ctx, page); await page.wait_for_timeout(1500); await release_sync(page)
        await page.evaluate("() => { window.__faults.push({ re: 'functions/v1/send-sms', method: 'POST', n: 1, mode: 'throw' }); }")
        await page.evaluate('offlineSyncPending(true)')
        pc = pid_of(TAG + 'WELCOME')
        r3 = await rec(page, c['syncId'])
        check(r3 and r3.get('smsPending') == 'welcome', 'F1: welcome with no answer → kept for a retry', r3 and r3.get('smsPending'))
        await page.evaluate('offlineSyncPending(true)'); await page.wait_for_timeout(1500)
        check(sql("select count(*) from airvalet_sms_messages where passenger_id = %d and message_type = 'CHECK_IN'" % pc) == '1', 'F1: one welcome after the retry (no duplicate)')

        # ── F1d. Lost answer AFTER the server sent the welcome ────────────
        await hold_sync(page); await offline(ctx, page)
        d = await v2_create(page, TAG + 'LOSTWEL', '30555' + RUN + '14', consent=True)
        await online(ctx, page); await page.wait_for_timeout(1500); await release_sync(page)
        await page.evaluate("() => { window.__faults.push({ re: 'functions/v1/send-sms', method: 'POST', n: 1, mode: 'lose' }); }")
        await page.evaluate('offlineSyncPending(true)'); await page.evaluate('offlineSyncPending(true)'); await page.wait_for_timeout(1500)
        pd = pid_of(TAG + 'LOSTWEL')
        check(sql("select count(*) from airvalet_sms_messages where passenger_id = %d and message_type = 'CHECK_IN' and status <> 'blocked'" % pd) == '1', 'F1: welcome sent, answer lost, retried → still one text to the guest')

        # ── F2. Details added on the card while the upload runs ───────────
        await hold_sync(page); await offline(ctx, page)
        e = await v2_create(page, TAG + 'DETAILS', '30555' + RUN + '15', close=False)
        await online(ctx, page); await page.wait_for_timeout(1500); await release_sync(page)
        await page.evaluate("() => { window.__faults.push({ re: '/rest/v1/passengers$', method: 'POST', n: 1, mode: 'delay', ms: 2500 }); }")
        await page.evaluate('() => { window.__syncP = offlineSyncPending(true); }')
        await page.wait_for_timeout(600)
        await page.evaluate("ci2OfflinePatch({ loc: 'HANGAR 19' })")
        await page.evaluate("ci2OfflinePatch({ car: 'TOYOTA SIENNA', color: 'SILVER' })")
        await page.evaluate('window.__syncP')
        row = sql("select coalesce(loc,'') || '|' || coalesce(car,'') || '|' || coalesce(color,'') from passengers where name = '%sDETAILS'" % TAG)
        check(row == 'HANGAR 19|TOYOTA SIENNA|SILVER', 'F2: hangar + vehicle picked during the upload are on the server', row)
        st = await page.evaluate('({ id: _ci.id, offline: _ci.offline })')
        check(st['id'] == pid_of(TAG + 'DETAILS') and st['offline'] is False, 'F2: the open card switches to the server ticket', st)
        await page.evaluate("() => { window.__toasts = []; const o = window.showMsg; window.showMsg = (m, b) => { window.__toasts.push(m); return o(m, b); }; }")
        await page.evaluate("ci2OfflinePatch({ loc: 'HANGAR 25' })"); await page.wait_for_timeout(400)
        toast = ' | '.join(await page.evaluate('window.__toasts'))
        check('just uploaded' in toast or 'save it on the server' in toast, 'F2: a late offline save says it was not saved (no false "Saved")', toast)
        await page.evaluate('closeAll()')

        # ── F3. Duplicate lookup fails once ───────────────────────────────
        await hold_sync(page); await offline(ctx, page)
        f = await v2_create(page, TAG + 'LOOKUP', '30555' + RUN + '16')
        await online(ctx, page); await page.wait_for_timeout(1500)
        pl = (await rec(page, f['syncId']))['payload']
        sql("insert into passengers (name, phone, ticket, status, ts, checkin_date, client_key) values ('%s', '%s', '%s', 'NO DATE', 'x', now(), '%s')"
            % (pl['name'], pl['phone'], pl['ticket'], pl['client_key']))   # the earlier answer was lost
        await release_sync(page)
        await page.evaluate("() => { window.__faults.push({ re: 'client_key=eq', method: 'GET', n: 1, mode: 'status', status: 503 }); }")
        await page.evaluate('offlineSyncPending(true)')
        r4 = await rec(page, f['syncId'])
        check(r4 and r4.get('syncState') == 'SYNC_RETRY', 'F3: lookup 503 → SYNC_RETRY (not "Not uploaded")', r4 and (r4.get('syncState'), r4.get('lastError')))
        await page.evaluate('offlineSyncPending(true)'); await page.wait_for_timeout(800)
        check(await rec(page, f['syncId']) is None and n_pax(TAG + 'LOOKUP') == 1, 'F3: next run finds it, one passenger, record removed')

        # ── L. Older records written after the last refresh / Debug record ─
        await page.evaluate('''async ([tag, run]) => {
          const r = offlineBuildCheckinRecord({ ts: 'x', checkin_date: new Date().toISOString(), name: tag + 'LEG OTHERTAB', phone: '(305) 555-' + run + '7',
             ticket: '93' + run, ret: '', car: '', color: null, loc: '', status: 'NO DATE', block: '', obs: '', deldate: '' }, null);
          delete r.v; await offlineCheckinPut(r);              // no loadData(): the list on screen does not have it
          await offlineCheckinPut(offlineBuildDebugTestRecord());
        }''', [TAG, RUN])
        await page.evaluate('() => { window.__confirms = []; window.confirm = (m) => { window.__confirms.push(m); return false; }; }')
        await page.evaluate('offlineSyncNow()'); await page.wait_for_timeout(800)
        msgs = await page.evaluate('window.__confirms')
        check(len(msgs) == 1 and 'LEG OTHERTAB' in msgs[0], 'L: Sync now confirm lists an older record saved after the last refresh', msgs)
        check(msgs and 'DIAGNOSTIC' not in msgs[0], 'L: the Debug test record is not offered for upload')
        check(n_pax(TAG + 'LEG OTHERTAB') == 0, 'L: Cancel → nothing uploaded')
        await page.evaluate('() => { window.confirm = () => true; }')
        await page.evaluate('offlineSyncNow()'); await page.wait_for_timeout(1500)
        check(n_pax(TAG + 'LEG OTHERTAB') == 1, 'L: OK → uploaded once')
        check(int(sql("select count(*) from passengers where name = 'DIAGNOSTIC TEST RECORD'")) == 0, 'L: no "DIAGNOSTIC TEST RECORD" passenger, even after OK')
        await page.evaluate("(async () => { for (const r of await offlineCheckinGetAll()) if (r.payload && r.payload.name === 'DIAGNOSTIC TEST RECORD') await offlineCheckinDelete(r.offline_sync_id); })()")

        # ── C. Inbox read only while looking ──────────────────────────────
        pi = pid_of(TAG + 'CONSENT')
        ph = sql("select public.airvalet_sms_normalize_phone(phone) from passengers where id = %d" % pi)
        ins = lambda body, sid: sql("insert into airvalet_sms_messages (passenger_id, direction, phone_e164, message_type, provider, status, body, provider_message_sid, received_at) values (%d, 'inbound', '%s', 'INBOUND', 'twilio', 'received', '%s', '%s', now())" % (pi, ph, body, sid))
        ins('E2E first question', 'SME2E%sa' % RUN)
        await page.evaluate('(id) => openInboxThread(id)', pi); await page.wait_for_timeout(2000)
        check(sql("select count(*) from airvalet_sms_messages where passenger_id = %d and direction = 'inbound' and read_at is null" % pi) == '0', 'C: opening the conversation marks it read')
        await page.evaluate("document.querySelector('.tab[data-t=day]').click()"); await page.wait_for_timeout(500)   # Dashboard, thread still "open"
        ins('E2E second question', 'SME2E%sb' % RUN)
        await page.evaluate('loadInbox()'); await page.wait_for_timeout(2000)       # the 15 s poll / realtime refresh
        check(sql("select count(*) from airvalet_sms_messages where passenger_id = %d and direction = 'inbound' and read_at is null" % pi) == '1', 'C: a new message is NOT marked read while staff are on another tab')
        await page.evaluate("document.querySelector('.tab[data-t=messages]').click()"); await page.wait_for_timeout(2500)
        check(sql("select count(*) from airvalet_sms_messages where passenger_id = %d and direction = 'inbound' and read_at is null" % pi) == '0', 'C: back on Messages → marked read')
        await page.evaluate('closeInboxThread()')

        # ── M. Debug Test Append (iPad login = IPAD_OPS) ──────────────────
        before = int(sql("select count(*) from passengers where name = 'TEST PASSENGER'"))
        await page.evaluate('runTestAppend()'); await page.wait_for_timeout(1000)
        check(int(sql("select count(*) from passengers where name = 'TEST PASSENGER'")) == before, 'M: Test Append refused for a non-admin login')
        check(not errors, 'no page errors', errors[:3])
        await ctx.close()

        # ── G. Closing Report on the iPhone login ─────────────────────────
        ctx = await browser.new_context(viewport={'width': 390, 'height': 844})
        await ctx.route('**/*', guard)
        page = await ctx.new_page(); page.on('pageerror', lambda e: errors.append(str(e)))
        await login(page, 'localiphone')
        # Smart Tips (v86): staff type only the cash counted (crCashCounted); Other Tips is calculated.
        await page.evaluate("document.getElementById('crCashCounted').value = '40.00'")
        await page.evaluate('crOpenTab()'); await page.wait_for_timeout(2500)
        v = await page.evaluate("document.getElementById('crCashCounted').value")
        bd = await page.evaluate('_crBusinessDate')
        existing = sql("select coalesce(cash_counted_cents::text, '') from daily_closing_reports where report_date = '%s'" % bd)
        check(v == '' or existing != '', 'G: "Total Cash Counted" does not carry over from the previous open', (v, existing))
        t0 = await page.evaluate('_crStripeTipsCents')
        pay = sql("insert into payments (amount_cents, type, method, status, created_at) values (1234, 'TIP', 'STRIPE', 'succeeded', now()) returning id").splitlines()[0]
        try:
            await page.evaluate('crShowPreview()'); await page.wait_for_timeout(1000)
            t1 = await page.evaluate('_crStripeTipsCents')
            check(t1 == t0 + 1234, 'G: a tip paid after the form opened is in the preview (re-read)', (t0, t1))
        finally:
            sql("delete from payments where id = %s" % pay)
        check(not errors, 'no page errors (iPhone)', errors[:3])
        await ctx.close()

        # ── K. Passenger chat: edited after a lost answer ─────────────────
        sql("delete from passengers where id = 951301")
        sql("""insert into public.passengers (id, ts, checkin_date, name, phone, ticket, status, ret, loc, car, color, return_operator)
               values (951301, 'x', now(), '%sCHAT', '3055551301', 'E2EK-01', 'PENDING', to_char((now() at time zone 'America/New_York')::date + 3, 'FMMM/FMDD/YYYY'), null, 'BMW X5', 'Black', 'MAKERS')""" % TAG)
        sql("""insert into public.airvalet_sms_enrollments (passenger_id, phone_e164, device_id, consent_id)
               select 951301, public.airvalet_sms_normalize_phone('3055551301'), (select id from public.airvalet_sms_devices where status = 'approved' limit 1), gen_random_uuid()""")
        tok = sql("select public.airvalet_pass_mint(951301);").splitlines()[-1]
        chat0 = sql("select chat_enabled from airvalet_portal_settings")
        sql("update airvalet_portal_settings set chat_enabled = true")   # on in production; restored below
        ctx = await browser.new_context(viewport={'width': 390, 'height': 844}, reduced_motion='reduce')
        await ctx.route('**/*', guard)
        p3 = await ctx.new_page()
        await p3.goto(APP + 'a#' + tok); await p3.wait_for_selector('.pass', timeout=20000)
        await p3.evaluate(FAULTS)
        has_chat = await p3.is_visible('[data-open="chat"]')
        if has_chat:
            await p3.click('[data-open="chat"]'); await p3.wait_for_selector('#chatText')
            await p3.evaluate("() => { window.__faults.push({ re: 'functions/v1/valet-pass', method: 'POST', n: 1, mode: 'lose', body: ':\\x22send\\x22' }); }")
            # only the send must lose its answer: the chat refresh also POSTs, so arm it right before Send
            await p3.fill('#chatText', 'E2E question A')
            await p3.click('[data-chatsend]'); await p3.wait_for_timeout(1500)
            await p3.fill('#chatText', 'E2E question A plus gate 7')
            await p3.click('[data-chatsend]'); await p3.wait_for_timeout(2000)
            bodies = sql("select string_agg(body, ' || ' order by created_at) from airvalet_sms_messages where passenger_id = 951301 and direction = 'inbound'")
            check('plus gate 7' in (bodies or ''), 'K: the edited message is stored (not dropped as a repeat)', bodies)
        else:
            print('     skip: chat not offered on this local pass')
        sql("update airvalet_portal_settings set chat_enabled = %s" % ('true' if chat0 == 't' else 'false'))
        await ctx.close()
        await browser.close()

    cleanup()
    print(f'\n{oks} passed, {fails} failed')
    sys.exit(1 if fails else 0)

asyncio.run(main())
