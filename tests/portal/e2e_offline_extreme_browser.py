# LOCAL ONLY. Offline check-in, extreme cases (post-deploy audit 2026-10-25),
# in a real browser against the local stack (send-sms in mock, printer stubbed):
#   1. records from an older app version (several shapes) never upload by
#      themselves: reload, 'online', re-login, tab visible, 15 s timer;
#      only Sync now + confirmation uploads them
#   2. logout / another staff account with records still pending
#   3. app update (new service worker, "Reload now") with records pending
#   4. browser killed after the server saved the row, before the answer
#   5. two tabs of the same device syncing at the same time
#   6. network flapping on/off during the upload
#   python3 tests/portal/e2e_offline_extreme_browser.py <scratch portal dir> [engine]
# Needs a second app server for scenario 3 (copy of the app on port 8782):
#   APP_ROOT=<copy> python3 <scratch>/portal/serve_root.py 8782
import asyncio, os, re, shutil, subprocess, sys, tempfile, time
from playwright.async_api import async_playwright

DIR = sys.argv[1]
ENGINE = sys.argv[2] if len(sys.argv) > 2 else 'chromium'
APP = 'http://127.0.0.1:8781/'
APP2 = 'http://127.0.0.1:8782/'
COPY = os.environ.get('APP_COPY', '')
PW = open(DIR + '/test_password.txt').read().strip()
RUN = str(int(time.time()) % 900 + 100)
TAG = 'E2E XTR ' + ENGINE[:2].upper() + ' '
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


async def guard(route):
    u = route.request.url
    if u.startswith('http://127.0.0.1') or 'fonts.g' in u or 'cdnjs' in u or 'jsdelivr' in u:
        await route.continue_()
    else:
        await route.abort()


STUBS = '''async () => {
  try {
    const key = smsDeviceKey(true);
    await smsApi('/rest/v1/rpc/airvalet_sms_device_request', { method: 'POST', body: JSON.stringify({ p_device_key: key, p_label: 'E2E iPad', p_user_agent: 'e2e' }) });
    await resolveSmsProvider();
  } catch (e) {}
  window.__prints = [];
  window.epsonSend = async (xml, label) => { window.__prints.push({ xml, label }); return true; };
  window.confirm = () => true;
}'''


async def signed_in(page):
    return await page.evaluate('typeof _currentUserEmail !== "undefined" && !!_currentUserEmail && Array.isArray(data) && data.length > 0')


async def login(page, user='localipad', app=APP, goto=True):
    if goto:
        await page.goto(app + '?checkin=v2')
    t0 = time.time()
    while time.time() - t0 < 25:   # an existing session signs in by itself
        if await signed_in(page):
            break
        if await page.is_visible('#loginEmail'):
            await page.wait_for_timeout(1500)
            await page.fill('#loginEmail', user); await page.fill('#loginPwd', PW); await page.press('#loginPwd', 'Enter')
            try:
                await page.wait_for_function('typeof _currentUserEmail !== "undefined" && !!_currentUserEmail && Array.isArray(data) && data.length > 0', timeout=20000)
                break
            except Exception:
                pass
        await page.wait_for_timeout(500)
    await page.wait_for_timeout(1500)
    await page.evaluate(STUBS)


async def offline(ctx, *pages):
    await ctx.set_offline(True)
    for p in pages:
        await p.evaluate("window.dispatchEvent(new Event('offline'))")
    await asyncio.sleep(0.3)


async def online(ctx, *pages):
    await ctx.set_offline(False)
    for p in pages:
        await p.evaluate("window.dispatchEvent(new Event('online'))")


async def v2_create(page, name, phone, consent=False):
    await page.evaluate('openAdd()')
    await page.wait_for_selector('#ci2Name', state='visible')
    await page.fill('#ci2Name', name)
    await page.click('#ci2Phone'); await page.keyboard.type(phone)
    await page.click('#ci2Yes' if consent else '#ci2No')
    if not consent:
        await page.click('#ci2NoText')
    await page.wait_for_selector('#ci2Created:not([hidden])', timeout=20000)
    out = await page.evaluate('({ id: _ci.id, ticket: _ci.ticket, offline: _ci.offline, syncId: _ci.syncId })')
    await page.evaluate('closeAll()')
    return out


async def unsynced(page):
    return await page.evaluate("(async () => (await offlineCheckinGetAll()).filter(r => offlineIsUnsynced(r)).length)()")


async def wait_synced(page, timeout=60):
    t0 = time.time()
    while True:
        if await unsynced(page) == 0 and not await page.evaluate('_offlineSync.running'):
            break
        if time.time() - t0 > timeout:
            raise TimeoutError('still pending: %s' % await page.evaluate("(async () => JSON.stringify((await offlineCheckinGetAll()).map(r => [r.payload && r.payload.name, r.syncState, r.lastError])))()"))
        await page.wait_for_timeout(500)
    await page.wait_for_timeout(800)


LEGACY_PUT = '''async ([tag, run]) => {
  const base = (n, i) => ({ ts: 'x', checkin_date: new Date().toISOString(), name: tag + n, phone: '(305) 555-' + run + i,
     ticket: '98' + i + '-' + run, ret: '', car: '', color: null, loc: '', status: 'NO DATE', block: '', obs: '', deldate: '' });
  // Phase 2 shape (offline-db.js before SW v73): no v, no sms, no client_key.
  const p2 = offlineBuildCheckinRecord(base('LEG P2', 1), null); delete p2.v; delete p2.sms; delete p2.nextAttemptAt;
  // Same but saved with a client key (re-entered online later by the staff).
  const p2k = offlineBuildCheckinRecord(Object.assign(base('LEG KEY', 2), { client_key: 'ck_leg_' + run }), null); delete p2k.v;
  // Old retry state from an earlier attempt.
  const p2r = offlineBuildCheckinRecord(base('LEG RETRY', 3), null); delete p2r.v; p2r.syncState = 'SYNC_RETRY'; p2r.nextAttemptAt = new Date(Date.now() - 60000).toISOString();
  // Corrupt: no payload at all.
  const bad = offlineBuildCheckinRecord(base('LEG BAD', 4), null); delete bad.v; bad.payload = null;
  for (const r of [p2, p2k, p2r, bad]) await offlineCheckinPut(r);
  await loadData();
  return [p2, p2k, p2r, bad].map(r => r.offline_sync_id);
}'''


def cleanup():
    sql("""do $$ declare r record; begin
      create temp table e2e_ids on commit drop as select id from passengers where name like 'E2E XTR %';
      for r in select conrelid::regclass t, a.attname c from pg_constraint k join pg_attribute a on a.attrelid = k.conrelid and a.attnum = any(k.conkey)
               where k.contype = 'f' and k.confrelid = 'public.passengers'::regclass loop
        execute format('delete from %s where %I in (select id from e2e_ids)', r.t, r.c);
      end loop;
      delete from airvalet_sms_messages where passenger_id in (select id from e2e_ids);
      delete from passengers where id in (select id from e2e_ids);
    end $$""")
    sql("delete from activity_log where passenger like 'E2E XTR %'")


async def main():
    cleanup()
    async with async_playwright() as pw:
        kw = {'executable_path': os.environ['WEBKIT_PATH']} if ENGINE == 'webkit' and os.environ.get('WEBKIT_PATH') else {}
        bt = pw.webkit if ENGINE == 'webkit' else pw.chromium
        browser = await bt.launch(**kw)
        ctx = await browser.new_context(viewport={'width': 820, 'height': 1180})
        await ctx.route('**/*', guard)
        page = await ctx.new_page()
        errors = []
        page.on('pageerror', lambda e: errors.append(str(e)))
        await login(page)
        await page.evaluate('closeAll()')

        # ── 1. Older-version records: never automatic ─────────────────────
        ids = await page.evaluate(LEGACY_PUT, [TAG, RUN])
        leg = lambda: n_pax(TAG + 'LEG%')
        await page.evaluate('offlineSyncPending(false)'); await page.wait_for_timeout(1500)
        check(leg() == 0, 'legacy: automatic sync call uploads nothing')
        await offline(ctx, page); await online(ctx, page); await page.wait_for_timeout(4000)
        check(leg() == 0, "legacy: back 'online' uploads nothing")
        await page.evaluate("document.dispatchEvent(new Event('visibilitychange'))"); await page.wait_for_timeout(1500)
        check(leg() == 0, 'legacy: tab visible again uploads nothing')
        await page.wait_for_timeout(16500)   # the 15 s retry timer fires at least once
        check(leg() == 0, 'legacy: 15 s retry timer uploads nothing')
        await page.reload(); await login(page, goto=False); await page.wait_for_timeout(3000)
        check(leg() == 0, 'legacy: reload + automatic sign-in uploads nothing')
        await page.evaluate('doLogout()'); await page.wait_for_timeout(1500); await login(page, goto=False); await page.wait_for_timeout(3000)
        check(leg() == 0, 'legacy: sign out + sign in again uploads nothing')
        left = await page.evaluate("(async (ids) => (await offlineCheckinGetAll()).filter(r => ids.includes(r.offline_sync_id)).length)(%s)" % ids)
        check(left == 4, 'legacy: all 4 older records still on the device', left)
        banner = await page.inner_text('#offlineModeBanner')
        check('older offline check-in' in banner, 'legacy: banner asks for a review', banner)
        await page.evaluate('window.confirm = () => false')
        r = await page.evaluate('offlineSyncNow()')
        await page.wait_for_timeout(1500)
        check(leg() == 0 and r.get('skipped') == 'cancelled', 'legacy: Sync now + Cancel uploads nothing', r)
        await page.evaluate('window.confirm = () => true')
        r_ok = await page.evaluate('offlineSyncNow()')
        await page.wait_for_timeout(4000)
        n_ok = n_pax(TAG + 'LEG P2') + n_pax(TAG + 'LEG KEY') + n_pax(TAG + 'LEG RETRY')
        dbg = await page.evaluate("(async () => JSON.stringify({ net: _offlineNet, st: (await offlineCheckinGetAll()).map(r => [r.payload && r.payload.name, r.syncState, r.lastError, r.v]) }))()")
        check(n_ok == 3, 'legacy: Sync now + OK uploads the 3 valid records once each', (n_ok, r_ok, dbg))
        check(n_pax(TAG + 'LEG BAD') == 0, 'legacy: the corrupt record is not uploaded')
        bad = await page.evaluate("(async (id) => (await offlineCheckinGet(id)))(%r)" % ids[3])
        check(bad is not None and bad.get('syncState') == 'SYNC_ERROR' and 'Damaged' in (bad.get('lastError') or ''), 'legacy: the corrupt record stays on the device, marked damaged (not lost, not blocking)', bad and (bad.get('syncState'), bad.get('lastError')))
        await page.evaluate('offlineSyncNow()'); await page.wait_for_timeout(3000)
        n_ok2 = n_pax(TAG + 'LEG P2') + n_pax(TAG + 'LEG KEY') + n_pax(TAG + 'LEG RETRY')
        check(n_ok2 == 3, 'legacy: a second Sync now creates no duplicates', n_ok2)
        await page.evaluate("(async (id) => offlineCheckinDelete(id))(%r)" % ids[3]); await page.evaluate('loadData()')

        # ── 2. Logout / another account while records are pending ────────
        await page.evaluate('window.__realSync = offlineSyncPending; window.offlineSyncPending = async () => ({ skipped: "held by test" })')
        await offline(ctx, page)
        a = await v2_create(page, TAG + 'SWITCH', '30555' + RUN + '21')
        await online(ctx, page); await page.wait_for_timeout(2500)
        await page.evaluate('doLogout()'); await page.wait_for_timeout(2000)
        kept = await unsynced(page)
        check(kept == 1, 'sign out: the pending check-in stays on the device', kept)
        await login(page, 'localiphone', goto=False)
        check(await unsynced(page) == 1 and n_pax(TAG + 'SWITCH') == 0, 'another account signs in: record still pending, not lost')
        await page.evaluate('window.offlineSyncPending = window.__realSync; offlineSyncPending(false)')
        await wait_synced(page)
        check(n_pax(TAG + 'SWITCH') == 1, 'another account: uploaded exactly once')
        who = sql("select coalesce(changed_by,'') from activity_log where passenger like '%sSWITCH' and action='CREATED' limit 1" % TAG)
        print('     info: CREATED log for SWITCH stamped by:', who or '(none)')
        await page.evaluate('doLogout()'); await page.wait_for_timeout(1500); await login(page, goto=False)

        # ── 5. Two tabs of the same device ──────────────────────────────
        p2 = await ctx.new_page(); p2.on('pageerror', lambda e: errors.append(str(e)))
        await login(p2)
        for pg in (page, p2):
            await pg.evaluate('window.__realSync = offlineSyncPending; window.offlineSyncPending = async () => ({ skipped: "held by test" })')
        await offline(ctx, page, p2)
        for i in range(3):
            await v2_create(page, TAG + 'TAB A%d' % i, '30555' + RUN + '3%d' % i)
        await online(ctx, page, p2); await page.wait_for_timeout(1500)
        await p2.evaluate('loadData()')
        await asyncio.gather(page.evaluate('window.offlineSyncPending = window.__realSync; Promise.all([offlineSyncPending(false), offlineSyncPending(true)])'),
                             p2.evaluate('window.offlineSyncPending = window.__realSync; Promise.all([offlineSyncPending(false), offlineSyncPending(true)])'))
        await wait_synced(page); await wait_synced(p2)
        counts = [n_pax(TAG + 'TAB A%d' % i) for i in range(3)]
        check(counts == [1, 1, 1], 'two tabs syncing together (auto + manual each): every check-in exactly once', counts)
        tickets = sql("select string_agg(ticket, ',') from passengers where name like '%sTAB A%%'" % TAG).split(',')
        check(len(set(tickets)) == 3, 'two tabs: three different ticket numbers', tickets)
        try:
            await asyncio.wait_for(p2.close(), 10)
        except asyncio.TimeoutError:
            print('     info: closing the second tab hung in the test browser (headless WebKit); it stays open for the next scenario')

        # ── 6. Network flapping during the upload ───────────────────────
        await page.evaluate("""() => { if (window.__trk) return; window.__trk = true; const real = window.fetch; window.__inflight = {}; let n = 0;
          window.fetch = function(u, o) { const id = ++n; window.__inflight[id] = [String(u).slice(-80), (o && o.method) || 'GET', Date.now()];
            return real(u, o).finally(() => { delete window.__inflight[id]; }); }; }""")
        async def state():
            return await asyncio.wait_for(page.evaluate("""(async () => JSON.stringify({ running: _offlineSync.running,
              locks: navigator.locks ? await navigator.locks.query() : null,
              inflight: Object.values(window.__inflight).map(x => [x[0], x[1], Math.round((Date.now() - x[2]) / 1000)]) }))()"""), 15)
        print('     step: flapping start')
        await page.evaluate('window.__realSync = offlineSyncPending; window.offlineSyncPending = async () => ({ skipped: "held by test" })')
        await offline(ctx, page)
        for i in range(5):
            await asyncio.wait_for(v2_create(page, TAG + 'FLAP %d' % i, '30555' + RUN + '4%d' % i), 60)
        print('     step: 5 offline check-ins saved')
        await page.evaluate('window.offlineSyncPending = window.__realSync')
        await online(ctx, page)
        for k in range(16):   # ~8 s of on/off every 0.5 s
            await asyncio.sleep(0.5)
            if k % 2 == 0: await offline(ctx, page)
            else: await online(ctx, page)
        await online(ctx, page)
        print('     step: flapping done', await state())
        try:
            await asyncio.wait_for(page.evaluate('offlineSyncNow()'), 120)
        except asyncio.TimeoutError:
            print('     HUNG: Sync now did not finish in 120 s', await state())
        await wait_synced(page, 90)
        counts = [n_pax(TAG + 'FLAP %d' % i) for i in range(5)]
        check(counts == [1] * 5, 'flapping network: all 5 uploaded exactly once', counts)

        check(not errors, 'no page errors (main + second tab)', errors[:3])
        await browser.close()

        # ── 4. Browser killed after the server saved the row ────────────
        if ENGINE == 'chromium':
            udd = tempfile.mkdtemp(prefix='e2e_kill_')
            pctx = await bt.launch_persistent_context(udd, viewport={'width': 820, 'height': 1180}, **kw)
            await pctx.route('**/*', guard)
            pg = pctx.pages[0] if pctx.pages else await pctx.new_page()
            await login(pg)
            await pg.evaluate('window.__realSync = offlineSyncPending; window.offlineSyncPending = async () => ({ skipped: "held by test" })')
            await offline(pctx, pg)
            await v2_create(pg, TAG + 'KILL', '30555' + RUN + '51', consent=True)
            await online(pctx, pg); await pg.wait_for_timeout(1500)
            # The server saves the row, but the page never gets the answer (killed first).
            await pg.evaluate('''() => { const real = window.fetch; window.fetch = async (u, o) => {
                const r = await real(u, o);
                if (String(u).includes('/rest/v1/passengers') && o && o.method === 'POST') { window.__saved = true; await new Promise(() => {}); }
                return r; }; window.__realSync(true); }''')
            t0 = time.time()
            while not await pg.evaluate('!!window.__saved') and time.time() - t0 < 20:
                await pg.wait_for_timeout(200)
            check(n_pax(TAG + 'KILL') == 1, 'kill: the server saved the row before the browser died')
            await pctx.close()   # browser gone mid-sync
            sms_before = int(sql("select count(*) from airvalet_sms_messages m join passengers p on p.id = m.passenger_id where p.name = '%sKILL'" % TAG))
            pctx = await bt.launch_persistent_context(udd, viewport={'width': 820, 'height': 1180}, **kw)
            await pctx.route('**/*', guard)
            pg = pctx.pages[0] if pctx.pages else await pctx.new_page()
            await login(pg)
            st = await pg.evaluate("(async () => JSON.stringify((await offlineCheckinGetAll()).map(r => [r.payload && r.payload.name, r.syncState])))()")
            await pg.evaluate('offlineSyncPending(false)')
            await wait_synced(pg)
            check(n_pax(TAG + 'KILL') == 1, 'kill: after restart the record syncs without a duplicate passenger', st)
            sms_after = int(sql("select count(*) from airvalet_sms_messages m join passengers p on p.id = m.passenger_id where p.name = '%sKILL' and m.message_type = 'CHECK_IN'" % TAG))
            check(sms_after <= 1, 'kill: at most one welcome text for that passenger', (sms_before, sms_after))
            await pctx.close()
            shutil.rmtree(udd, ignore_errors=True)

        # ── 3. App update with records pending ──────────────────────────
        if ENGINE == 'chromium' and COPY:
            swf = os.path.join(COPY, 'service-worker.js')
            orig = open(swf).read()
            browser = await bt.launch(**kw)
            ctx = await browser.new_context(viewport={'width': 820, 'height': 1180})
            await ctx.route('**/*', guard)
            page = await ctx.new_page()
            await login(page, app=APP2)
            await page.wait_for_function('navigator.serviceWorker && !!navigator.serviceWorker.controller', timeout=20000)
            await page.evaluate('window.__realSync = offlineSyncPending; window.offlineSyncPending = async () => ({ skipped: "held by test" })')
            await offline(ctx, page)
            for i in range(2):
                await v2_create(page, TAG + 'UPD %d' % i, '30555' + RUN + '6%d' % i)
            try:
                open(swf, 'w').write(re.sub(r"CACHE_VERSION = '([^']+)'", r"CACHE_VERSION = '\1-e2e-update'", orig, count=1))
                await online(ctx, page)
                await page.evaluate('_offlineSw.registration.update()')
                await page.wait_for_function("getComputedStyle(document.getElementById('offlineUpdateBanner')).display !== 'none'", timeout=20000)
                check(True, 'update: "new version" banner shown with records pending')
                check(await unsynced(page) == 2, 'update: the 2 records are still pending before reload')
                await page.evaluate('window.__oldDoc = 1; offlineApplyUpdate()')
                t0 = time.time()
                while time.time() - t0 < 30:   # the new version reloads the page (controllerchange)
                    try:
                        if not await page.evaluate('window.__oldDoc === 1'): break
                    except Exception:
                        pass
                    await asyncio.sleep(0.5)
                await page.wait_for_load_state('load'); await page.wait_for_timeout(3000)
                await login(page, app=APP2, goto=False)
                await wait_synced(page)
                counts = [n_pax(TAG + 'UPD %d' % i) for i in range(2)]
                check(counts == [1, 1], 'update: after "Reload now" both records uploaded exactly once', counts)
                ver = await page.evaluate("caches.keys()")
                check(any(c.endswith('-e2e-update') for c in ver), 'update: the new version is the active cache', ver)
            finally:
                open(swf, 'w').write(orig)
            await browser.close()
        elif ENGINE == 'chromium':
            print('     skip: scenario 3 needs APP_COPY + server on 8782')

    cleanup()
    print(f'\n{oks} passed, {fails} failed')
    sys.exit(1 if fails else 0)

asyncio.run(main())
