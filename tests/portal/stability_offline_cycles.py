# LOCAL ONLY. Stability under repeated offline/online cycles (Chromium + CDP):
# N cycles of (go offline → v2 check-in → back online → automatic upload),
# then checks memory, DOM nodes, event listeners, detached nodes and the
# idle request rate. Fictional data only; cleans up after itself.
#   python3 tests/portal/stability_offline_cycles.py <scratch portal dir> [cycles]
import asyncio, json, subprocess, sys, time
from playwright.async_api import async_playwright

DIR = sys.argv[1]
CYCLES = int(sys.argv[2]) if len(sys.argv) > 2 else 15
APP = 'http://127.0.0.1:8781/'
PW = open(DIR + '/test_password.txt').read().strip()
RUN = str(int(time.time()) % 900 + 100)
TAG = 'E2E STAB '
oks, fails = 0, 0
REPORT = {}


def sql(q):
    r = subprocess.run(['docker', 'exec', '-i', 'supabase_db_airvalet-portal-local', 'psql', '-U', 'postgres', '-d', 'postgres', '-qAt', '-c', q], capture_output=True, text=True)
    if r.returncode:
        raise RuntimeError(r.stderr)
    return r.stdout.strip()


def check(cond, msg, extra=''):
    global oks, fails
    if cond:
        oks += 1; print('ok  ', msg, extra)
    else:
        fails += 1; print('FAIL', msg, extra)


async def guard(route):
    u = route.request.url
    if u.startswith('http://127.0.0.1') or 'fonts.g' in u or 'cdnjs' in u or 'jsdelivr' in u:
        await route.continue_()
    else:
        await route.abort()


async def metrics(cdp):
    await cdp.send('HeapProfiler.collectGarbage')
    m = {x['name']: x['value'] for x in (await cdp.send('Performance.getMetrics'))['metrics']}
    return {'heapMB': round(m['JSHeapUsedSize'] / 1048576, 1), 'nodes': int(m['Nodes']), 'listeners': int(m['JSEventListeners'])}


async def detached(cdp):
    chunks = []
    cdp.on('HeapProfiler.addHeapSnapshotChunk', lambda e: chunks.append(e['chunk']))
    await cdp.send('HeapProfiler.takeHeapSnapshot', {'reportProgress': False})
    snap = json.loads(''.join(chunks))
    meta = snap['snapshot']['meta']; fields = meta['node_fields']; n = len(fields)
    names = snap['strings']; nodes = snap['nodes']
    i_name = fields.index('name')
    return sum(1 for k in range(0, len(nodes), n) if names[nodes[k + i_name]].startswith('Detached '))


async def main():
    async with async_playwright() as pw:
        b = await pw.chromium.launch()
        ctx = await b.new_context(viewport={'width': 820, 'height': 1180})
        await ctx.route('**/*', guard)
        page = await ctx.new_page()
        errors = []
        page.on('pageerror', lambda e: errors.append(str(e)))
        reqs = []
        page.on('request', lambda r: reqs.append((time.time(), r.url)))
        await page.goto(APP + '?checkin=v2')
        await page.wait_for_selector('#loginEmail', state='visible', timeout=20000)
        for attempt in range(3):
            await page.wait_for_timeout(2000)
            await page.fill('#loginEmail', 'localipad'); await page.fill('#loginPwd', PW); await page.press('#loginPwd', 'Enter')
            try:
                await page.wait_for_function('typeof _currentUserEmail !== "undefined" && !!_currentUserEmail && Array.isArray(data) && data.length > 0', timeout=20000); break
            except Exception:
                if attempt == 2: raise
        await page.wait_for_timeout(2000)
        await page.evaluate("() => { window.epsonSend = async () => true; window.confirm = () => true; }")
        cdp = await ctx.new_cdp_session(page)
        await cdp.send('Performance.enable')
        m0 = await metrics(cdp)
        t0 = time.time()
        for i in range(CYCLES):
            await ctx.set_offline(True); await page.evaluate("window.dispatchEvent(new Event('offline'))")
            await page.evaluate('openAdd()')
            await page.wait_for_function("!!document.getElementById('ci2Name') && !document.getElementById('ci2').hidden")
            await page.fill('#ci2Name', TAG + str(i))
            await page.click('#ci2Phone'); await page.keyboard.type('30555' + RUN + str(i).zfill(2)[-2:])
            await page.click('#ci2No'); await page.click('#ci2NoText')
            await page.wait_for_function("!!document.getElementById('ci2Created') && !document.getElementById('ci2Created').hidden", timeout=20000)
            await page.evaluate('closeAll()')
            await ctx.set_offline(False); await page.evaluate("window.dispatchEvent(new Event('online'))")
            t1 = time.time()
            while True:   # evaluate() awaits the Promise (wait_for_function would not)
                left = await page.evaluate("(async () => (await offlineCheckinGetAll()).filter(r => offlineIsUnsynced(r)).length)()")
                if left == 0 and not await page.evaluate('_offlineSync.running'):
                    break
                if time.time() - t1 > 45:
                    raise TimeoutError('cycle %d: still pending' % i)
                await page.wait_for_timeout(300)
        dt = time.time() - t0
        await page.wait_for_timeout(2000)
        m1 = await metrics(cdp)
        # Leak check without new data: re-render and open/close the check-in 20 times.
        # (run inside the page: Playwright element handles would themselves keep old nodes alive)
        await page.evaluate('async () => { for (let i = 0; i < 20; i++) { render(); openAdd(); await new Promise(r => setTimeout(r, 50)); closeAll(); } }')
        await page.wait_for_timeout(1500)
        m2 = await metrics(cdp)
        check(m2['listeners'] - m1['listeners'] <= 120, 'no listener leak: 20 re-renders + 20 open/close with the same data', (m1['listeners'], m2['listeners']))
        check(m2['nodes'] - m1['nodes'] <= 600, 'no DOM node leak on re-render', (m1['nodes'], m2['nodes']))
        det = await detached(cdp)
        n = int(sql("select count(*) from passengers where name like '%s%%'" % TAG))
        if n != CYCLES: print('DEBUG names:', sql("select string_agg(name, ',') from passengers where created_at > now() - interval '10 minutes'"), await page.evaluate("(async () => JSON.stringify((await offlineCheckinGetAll()).map(r => [r.payload.name, r.syncState, r.lastError])))()"))
        check(n == CYCLES, '%d offline/online cycles: every check-in uploaded exactly once' % CYCLES, n)
        REPORT['listeners_per_new_row'] = round((m1['listeners'] - m0['listeners']) / max(1, CYCLES), 1)
        check(m1['heapMB'] - m0['heapMB'] <= 15, 'JS heap stable (after GC)', (m0['heapMB'], m1['heapMB']))
        check(det <= 50, 'detached DOM nodes after the cycles', det)
        # idle: requests per minute with nothing pending
        reqs.clear()
        await page.wait_for_timeout(60000)
        idle = [u for _, u in reqs if '/rest/v1/' in u or '/functions/v1/' in u]
        check(len(idle) <= 30, 'idle API requests in 60 s (polling budget)', len(idle))
        check(not errors, 'no page errors', errors[:3])
        REPORT.update({'cycles': CYCLES, 'seconds': round(dt, 1), 'per_cycle_s': round(dt / CYCLES, 2), 'before': m0, 'after': m1, 'detached': det,
                       'idle_requests_60s': len(idle), 'idle_breakdown': sorted({u.split('?')[0].split('/v1/')[-1] for u in idle})})
        print(json.dumps(REPORT))
        await b.close()
    sql("""do $$ declare r record; begin
      create temp table e2e_ids on commit drop as select id from passengers where name like 'E2E STAB %';
      for r in select conrelid::regclass t, a.attname c from pg_constraint k join pg_attribute a on a.attrelid = k.conrelid and a.attnum = any(k.conkey)
               where k.contype = 'f' and k.confrelid = 'public.passengers'::regclass loop
        execute format('delete from %s where %I in (select id from e2e_ids)', r.t, r.c);
      end loop;
      delete from passengers where id in (select id from e2e_ids);
    end $$""")
    print(f'\n{oks} passed, {fails} failed')
    sys.exit(1 if fails else 0)

asyncio.run(main())
