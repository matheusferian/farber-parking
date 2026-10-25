# LOCAL ONLY. Offline check-in + automatic sync (Phase 3), in a real browser
# against the local stack (app on http://127.0.0.1:8781, send-sms in mock).
# Hosts other than 127.0.0.1 / fonts are aborted; epsonSend is stubbed.
#   python3 tests/portal/e2e_offline_sync_browser.py <scratch portal dir> [engine]
# engine: chromium (default) or webkit.
import asyncio, subprocess, sys, time
from playwright.async_api import async_playwright

DIR = sys.argv[1]
ENGINE = sys.argv[2] if len(sys.argv) > 2 else 'chromium'
APP = 'http://127.0.0.1:8781/'
PW = open(DIR + '/test_password.txt').read().strip()
RUN = str(int(time.time()) % 900 + 100)
TAG = 'E2E OFF ' + ENGINE[:2].upper() + ' '
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
        print('ok  ', f'[{ENGINE}]', msg)
    else:
        fails += 1
        print('FAIL', f'[{ENGINE}]', msg, extra)


async def guard(route):
    u = route.request.url
    if u.startswith('http://127.0.0.1') or 'fonts.g' in u or 'cdnjs' in u or 'jsdelivr' in u:
        await route.continue_()
    else:
        await route.abort()


async def login(page, user='localipad'):
    await page.goto(APP + '?checkin=v2')
    await page.wait_for_selector('#loginEmail', state='visible', timeout=20000)
    for attempt in range(3):
        await page.wait_for_timeout(2000)
        await page.fill('#loginEmail', user)
        await page.fill('#loginPwd', PW)
        await page.press('#loginPwd', 'Enter')
        try:
            await page.wait_for_function('typeof _currentUserEmail !== "undefined" && !!_currentUserEmail && Array.isArray(data) && data.length > 0', timeout=20000)
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
      window.confirm = () => true;
    }''')


async def v2_create(page, name, phone, consent=True):
    await page.evaluate('openAdd()')
    await page.wait_for_selector('#ci2Name', state='visible')
    await page.fill('#ci2Name', name)
    await page.click('#ci2Phone')
    await page.keyboard.type(phone)
    await page.click('#ci2Yes' if consent else '#ci2No')
    if not consent:
        await page.click('#ci2NoText')
    await page.wait_for_selector('#ci2Created:not([hidden])', timeout=20000)
    return await page.evaluate('({ id: _ci.id, ticket: _ci.ticket, offline: _ci.offline, syncId: _ci.syncId })')


async def idb(page):
    return await page.evaluate('offlineCheckinGetAll()')


async def go_online(page, ctx):
    await ctx.set_offline(False)
    await page.evaluate("window.dispatchEvent(new Event('online'))")


async def wait_synced(page, timeout=45000):
    # evaluate() awaits the Promise (wait_for_function would not).
    t0 = time.time()
    while True:
        left = await page.evaluate("(async () => (await offlineCheckinGetAll()).filter(r => offlineIsUnsynced(r)).length)()")
        busy = await page.evaluate("_offlineSync.running")
        if left == 0 and not busy:
            break
        if (time.time() - t0) * 1000 > timeout:
            raise TimeoutError('offline records still pending: %s' % left)
        await page.wait_for_timeout(500)
    await page.wait_for_timeout(800)


def n_pax(name_like):
    return int(sql("select count(*) from passengers where name like '%s'" % name_like))


async def main():
    async with async_playwright() as pw:
        import os
        kw = {'executable_path': os.environ['WEBKIT_PATH']} if ENGINE == 'webkit' and os.environ.get('WEBKIT_PATH') else {}
        browser = await (pw.webkit if ENGINE == 'webkit' else pw.chromium).launch(**kw)
        ctx = await browser.new_context(viewport={'width': 820, 'height': 1180})
        await ctx.route('**/*', guard)
        page = await ctx.new_page()
        errors = []
        page.on('pageerror', lambda e: errors.append(str(e)))
        await login(page)
        await page.evaluate('closeAll()')

        # ── 1. Internet drops during check-in ───────────────────────────
        await ctx.set_offline(True)
        await page.evaluate("window.dispatchEvent(new Event('offline'))")
        await page.wait_for_timeout(300)
        banner = await page.inner_text('#offlineModeBanner')
        check('OFFLINE MODE' in banner, 'offline: banner says OFFLINE MODE', banner)
        before_srv = n_pax(TAG + '%')
        sms0 = int(sql("select count(*) from airvalet_sms_messages"))
        a = await v2_create(page, TAG + 'ALPHA', '30555' + RUN + '01', consent=True)
        check(a['offline'] and a['syncId'] and a['id'] < 0, 'offline V2 check-in saved on the device (local id, sync id)', a)
        card = await page.inner_text('#ci2Sms')
        check('Not sent' in card and 'after it uploads' in card, 'offline card never says Sent; says the text goes out after upload', card)
        # hangar + vehicle on the offline ticket go into the device record and print
        await page.evaluate("() => { document.querySelector('#ci2Hangars button').click(); }")
        await page.wait_for_timeout(500)
        await page.evaluate("() => { _ci.vehText = 'TESLA MODEL Y'; ci2SetColor('WHITE'); ci2VehSum(true); }")
        await page.wait_for_timeout(600)
        rec = [r for r in await idb(page) if r['offline_sync_id'] == a['syncId']][0]
        check(bool(rec['payload'].get('loc')) and rec['payload'].get('car') == 'TESLA MODEL Y' and rec['payload'].get('color') == 'WHITE',
              'offline: hangar / vehicle / color stored in the device record', rec['payload'])
        check(rec.get('sms', {}).get('consent') is True and rec['sms'].get('auto') is True, 'offline: SMS intent stored (consent, auto), nothing sent', rec.get('sms'))
        await page.evaluate("() => { window.__prints = []; }")
        await page.evaluate('ci2Print("both")')
        labels = await page.evaluate("window.__prints.map(p => p.label)")
        check(labels == ['Key', 'Dashboard'], 'offline: Print Tags prints Key + Dashboard (printer is on the local network)', labels)
        await page.evaluate('closeAll()')
        b = await v2_create(page, TAG + 'BRAVO', '30555' + RUN + '02', consent=False)
        await page.evaluate('closeAll()')
        c = await v2_create(page, TAG + 'CHARLIE', '3055550198', consent=True)   # Twilio mock: timeout
        await page.evaluate('closeAll()')
        check(n_pax(TAG + '%') == before_srv, 'offline: nothing written to the server')
        check(int(sql("select count(*) from airvalet_sms_messages")) == sms0, 'offline: no SMS row created')
        pending = await page.evaluate("offlinePendingRecordsInData().length")
        check(pending >= 3, 'offline: 3 check-ins listed as PENDING SYNC', pending)
        tickets = [a['ticket'], b['ticket'], c['ticket']]
        check(len(set(tickets)) == 3, 'offline: three different ticket numbers on this device', tickets)

        # ── 2. Ticket collision: another device uses BRAVO's number meanwhile ──
        sql("insert into passengers (ts, checkin_date, name, phone, ticket, status, client_key) values ('x', now(), '%sOTHER DEVICE', '3055559000', '%s', 'PENDING', 'ck_e2e_other_%s')" % (TAG, b['ticket'], RUN))

        # ── 3. Browser closed and reopened while offline ────────────────
        await page.reload()
        await page.wait_for_function("typeof offlineCheckinGetAll === 'function'", timeout=20000)
        await page.wait_for_timeout(2500)
        await page.evaluate("() => { window.__prints = []; window.epsonSend = async (xml, label) => { window.__prints.push({ xml, label }); return true; }; window.confirm = () => true; }")
        left = [r for r in await idb(page) if r['payload'].get('name', '').startswith(TAG)]
        check(len(left) == 3, 'reopened offline: the 3 check-ins are still on the device', len(left))

        # ── 4. Session expired while offline → sync waits for sign-in ───
        await page.evaluate("() => { window.__realToken = _authToken; _authToken = 'expired.' + btoa(JSON.stringify({exp: 1})) + '.x'; window.__origRefresh = _supaClient.auth.refreshSession; _supaClient.auth.refreshSession = async () => ({ data: { session: null } }); }")
        await go_online(page, ctx)
        await page.wait_for_timeout(6000)
        st = await page.evaluate("({ auth: _offlineSync.authNeeded, n: offlinePendingRecordsInData().length })")
        check(st['auth'] and n_pax(TAG + '%') == before_srv + 1, 'expired session: nothing uploaded, records kept, sign-in asked', st)
        banner = await page.inner_text('#offlineModeBanner')
        check('Sign in to upload' in banner, 'expired session: banner asks to sign in', banner)

        # ── 5. Transient server error (500) → retry with backoff ────────
        # Fault injection inside the page (works the same in Chromium and WebKit).
        await page.evaluate("""() => {
          window.__realFetch = window.__realFetch || window.fetch;
          window.__failPost = { status: 500, n: 1, body: JSON.stringify({ message: 'temporary' }) };
          window.fetch = function(u, o) {
            if (window.__failPost && window.__failPost.n > 0 && o && o.method === 'POST' && /\/rest\/v1\/passengers$/.test(String(u))) {
              window.__failPost.n--;
              return Promise.resolve(new Response(window.__failPost.body, { status: window.__failPost.status, headers: { 'content-type': 'application/json' } }));
            }
            return window.__realFetch(u, o);
          };
        }""")
        await page.evaluate("() => { _supaClient.auth.refreshSession = window.__origRefresh; _authToken = window.__realToken; }")
        r1 = await page.evaluate('offlineSyncNow()')
        check(r1.get('failed', 0) >= 1, 'server 500: upload kept for retry', r1)
        recs = [r for r in await idb(page) if r['payload'].get('name', '').startswith(TAG)]
        check(any(r['syncState'] == 'SYNC_RETRY' and r.get('nextAttemptAt') for r in recs), 'server 500: record marked SYNC_RETRY with a next attempt time')

        # ── 6. Back online: automatic upload, double trigger, no duplicates ──
        res = await page.evaluate('Promise.all([offlineSyncNow(), offlineSyncNow()])')
        await wait_synced(page)
        check(n_pax(TAG + 'ALPHA') == 1 and n_pax(TAG + 'BRAVO') == 1 and n_pax(TAG + 'CHARLIE') == 1, 'sync: each offline check-in exists exactly once on the server', res)
        row = sql("select loc || '|' || car || '|' || color from passengers where name = '%sALPHA'" % TAG)
        check('TESLA MODEL Y' in row and 'WHITE' in row and not row.startswith('|'), 'sync: hangar / vehicle / color uploaded with the check-in', row)
        ids = {k: sql("select id from passengers where name = '%s%s'" % (TAG, k)) for k in ['ALPHA', 'BRAVO', 'CHARLIE']}
        # renumber
        bt = sql("select ticket from passengers where name = '%sBRAVO'" % TAG)
        check(bt != b['ticket'], 'collision: server gave BRAVO the next free number (%s → %s)' % (b['ticket'], bt))
        banner = await page.inner_text('#offlineModeBanner')
        check(b['ticket'] in banner and bt in banner and 'Reprint' in banner, 'collision: banner asks to reprint with the new number', banner)
        await page.evaluate("() => { window.__prints = []; }")
        await page.click('#offlineModeBanner .off-sync-btn:not(.ghost)')
        await page.wait_for_timeout(800)
        px = await page.evaluate("window.__prints.map(p => p.xml).join(' ')")
        check(bt in px and b['ticket'] not in px.replace(bt, ''), 'collision: Reprint prints the new ticket number')
        await page.click('#offlineModeBanner .off-sync-btn.ghost')
        await page.wait_for_timeout(800)
        dbg = await page.evaluate("(async () => JSON.stringify({ren: _offlineSync.renumbered, idb: (await offlineCheckinGetAll()).map(r => r.syncState), banner: document.getElementById('offlineModeBanner').innerHTML.slice(0, 300), msg: document.getElementById('msg').textContent}))()")
        check(await page.evaluate("_offlineSync.renumbered.length") == 0, 'collision: Done clears the reprint notice', dbg)
        # SMS: only after the server row; once; consent respected
        sa = int(sql("select count(*) from airvalet_sms_messages where passenger_id = %s and message_type = 'CHECK_IN'" % ids['ALPHA']))
        sb = int(sql("select count(*) from airvalet_sms_messages where passenger_id = %s" % ids['BRAVO']))
        check(sa == 1, 'sms: ALPHA (consent) got exactly one welcome after upload', sa)
        check(sb == 0, 'sms: BRAVO (no consent) got no text', sb)
        sc = sql("select string_agg(status, ',') from airvalet_sms_messages where passenger_id = %s and message_type = 'CHECK_IN'" % ids['CHARLIE'])
        check(sc == 'send_unknown', 'sms: Twilio timeout for CHARLIE stays unconfirmed (one attempt, no retry)', sc)
        logs = int(sql("select count(*) from activity_log where passenger_id in (%s) and action = 'CREATED'" % ','.join(ids.values())))
        check(logs == 3, 'sync: one CREATED history entry per check-in', logs)
        check(len([r for r in await idb(page) if r['payload'].get('name', '').startswith(TAG)]) == 0, 'sync: nothing personal left on the device after upload')
        # another sync never resends
        await page.evaluate('offlineSyncNow()')
        sa2 = int(sql("select count(*) from airvalet_sms_messages where passenger_id = %s and message_type = 'CHECK_IN'" % ids['ALPHA']))
        check(sa2 == 1, 'duplicate sync: no second welcome', sa2)

        # ── 7. Lost answer: the server already has the row (same client key) ──
        await ctx.set_offline(True)
        await page.evaluate("window.dispatchEvent(new Event('offline'))")
        d = await v2_create(page, TAG + 'DELTA', '30555' + RUN + '04', consent=False)
        await page.evaluate('closeAll()')
        drec = [r for r in await idb(page) if r['offline_sync_id'] == d['syncId']][0]
        ck = drec['payload']['client_key']
        sql("insert into passengers (ts, checkin_date, name, phone, ticket, status, client_key) values ('x', now(), '%sDELTA', '30555%s04', '%s', 'NO DATE', '%s')" % (TAG, RUN, d['ticket'], ck))
        await go_online(page, ctx)
        await wait_synced(page)
        check(n_pax(TAG + 'DELTA') == 1, 'lost answer: same client key → no duplicate passenger')

        # ── 8. Permanent rejection (400) → SYNC_ERROR, then retried ──────
        await ctx.set_offline(True)
        await page.evaluate("window.dispatchEvent(new Event('offline'))")
        e = await v2_create(page, TAG + 'ECHO', '30555' + RUN + '05', consent=False)
        await page.evaluate('closeAll()')

        await page.evaluate("() => { window.__failPost = { status: 400, n: 99, body: JSON.stringify({ message: 'invalid input' }) }; }")
        await ctx.set_offline(False)
        await page.evaluate("window.dispatchEvent(new Event('online'))")
        await page.evaluate('offlineSyncNow()')
        recs = [r for r in await idb(page) if r['offline_sync_id'] == e['syncId']]
        check(recs and recs[0]['syncState'] == 'SYNC_ERROR' and 'invalid input' in (recs[0].get('lastError') or ''), 'server 400: kept as SYNC_ERROR with the reason', recs[0]['syncState'] if recs else None)
        await page.evaluate('updateOfflinePendingPanel()')
        panel = await page.inner_text('#offlinePendingPanelBody')
        check('Not uploaded' in panel, 'server 400: Pending Sync panel shows the reason', panel[:120])
        await page.evaluate("() => { window.__failPost = null; }")
        rr = await page.evaluate('offlineSyncNow()')
        await wait_synced(page)
        dbg = await page.evaluate("(async () => JSON.stringify({net: _offlineNet, st: (await offlineCheckinGetAll()).map(r => [r.payload.name, r.syncState, r.lastError])}))()")
        check(n_pax(TAG + 'ECHO') == 1, 'server 400: Sync now after the fix uploads it once', (rr, dbg, sql("select string_agg(name||':'||ticket, ',') from passengers where name like '%sECHO%%'" % TAG)))

        check(not errors, 'no page errors', errors)

        # ── 9. Two devices offline at the same time, same ticket number ──
        ctx2 = await browser.new_context(viewport={'width': 390, 'height': 844})
        await ctx2.route('**/*', guard)
        p2 = await ctx2.new_page()
        await login(p2, 'localiphone')
        await p2.evaluate('closeAll()')
        for cx, pg in ((ctx, page), (ctx2, p2)):
            await cx.set_offline(True)
            await pg.evaluate("window.dispatchEvent(new Event('offline'))")
        f1 = await v2_create(page, TAG + 'FOX IPAD', '30555' + RUN + '06', consent=False)
        f2 = await v2_create(p2, TAG + 'FOX IPHONE', '30555' + RUN + '07', consent=False)
        await page.evaluate('closeAll()'); await p2.evaluate('closeAll()')
        check(f1['ticket'] == f2['ticket'], 'two devices offline picked the same next number (%s / %s)' % (f1['ticket'], f2['ticket']))
        await go_online(page, ctx); await go_online(p2, ctx2)
        await wait_synced(page); await wait_synced(p2)
        t1 = sql("select ticket from passengers where name = '%sFOX IPAD'" % TAG)
        t2 = sql("select ticket from passengers where name = '%sFOX IPHONE'" % TAG)
        check(t1 and t2 and t1 != t2, 'two devices: both uploaded, different ticket numbers (%s / %s)' % (t1, t2))
        await ctx2.close()
        await browser.close()

    sql("""do $$ declare r record; begin
      create temp table e2e_ids on commit drop as select id from passengers where name like 'E2E OFF %';
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
