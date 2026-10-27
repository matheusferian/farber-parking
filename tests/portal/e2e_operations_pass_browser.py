# LOCAL ONLY (audit v77, 2026-10-26). Operation flow on one ticket and what the
# passenger sees on the Digital Pass at each step: Parked → Flying back (return
# time) → Ready → At Customs → Lockbox → Delivered (Lockbox) and a normal
# Delivered; token isolation; slow network check-in (Chromium); app reopen.
# Uses an international number so the valet pass token comes from pass-share
# (no SMS anywhere). Fictional data, mock SMS.
#   python3 tests/portal/e2e_operations_pass_browser.py <scratch portal dir> [engine]
import asyncio, os, subprocess, sys, time, urllib.parse
from playwright.async_api import async_playwright

DIR = sys.argv[1]
ENGINE = sys.argv[2] if len(sys.argv) > 2 else 'chromium'
APP = os.environ.get('APP', 'http://127.0.0.1:8781/')
PW = open(DIR + '/test_password.txt').read().strip()
RUN = str(int(time.time()) % 900 + 100)
TAG = 'E2E OPS ' + ENGINE[:2].upper() + ' '
oks, fails = 0, 0
src = open(os.path.join(os.path.dirname(__file__), 'e2e_intl_share_browser.py')).read().split('async def main():')[0]
ns = {'__file__': __file__}; exec(compile(src.replace("TAG = 'E2E INTL '", "TAG = 'E2E OPS '"), 'helpers', 'exec'), ns)
sql = ns['sql']


def check(cond, msg, extra=''):
    global oks, fails
    if cond:
        oks += 1; print('ok  ', f'[{ENGINE}]', msg)
    else:
        fails += 1; print('FAIL', f'[{ENGINE}]', msg, extra)


def cleanup():
    sql("""do $$ declare r record; begin
      create temp table e2e_ids on commit drop as select id from passengers where name like 'E2E OPS %';
      for r in select conrelid::regclass t, a.attname c from pg_constraint k join pg_attribute a on a.attrelid = k.conrelid and a.attnum = any(k.conkey)
               where k.contype = 'f' and k.confrelid = 'public.passengers'::regclass loop
        execute format('delete from %s where %I in (select id from e2e_ids)', r.t, r.c);
      end loop;
      delete from airvalet_sms_messages where passenger_id in (select id from e2e_ids);
      delete from airvalet_sms_enrollments where passenger_id in (select id from e2e_ids);
      delete from airvalet_pass_links where passenger_id in (select id from e2e_ids);
      delete from passengers where id in (select id from e2e_ids);
    end $$""")


async def view(page, tok):
    return await page.evaluate("""async (t) => { const r = await fetch(SUPABASE_URL + '/functions/v1/valet-pass', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ t }) });
      let d = null; try { d = await r.json(); } catch (e) {} return { http: r.status, d }; }""", tok)


async def main():
    cleanup()
    async with async_playwright() as pw:
        kw = {'executable_path': os.environ['WEBKIT_PATH']} if ENGINE == 'webkit' and os.environ.get('WEBKIT_PATH') else {}
        b = await getattr(pw, ENGINE).launch(**kw)
        ctx = await b.new_context(viewport={'width': 820, 'height': 1180}, service_workers='block')
        page = await ctx.new_page(); errs = []
        page.on('pageerror', lambda e: errs.append(str(e)))
        await ns['login'](page)
        today = await page.evaluate("(()=>{const d=new Date();return (d.getMonth()+1)+'/'+d.getDate()+'/'+d.getFullYear()})()")
        iso = await page.evaluate("(()=>{const d=new Date();return d.getFullYear()+'-'+String(d.getMonth()+1).padStart(2,'0')+'-'+String(d.getDate()).padStart(2,'0')})()")

        name = TAG + 'FLOW ' + RUN
        await ns['v2_fill'](page, name, '+44 7911 12' + RUN)
        g = await ns['v2_yes'](page)
        await page.wait_for_selector('#ci2Sms.share', timeout=20000)
        wa = await page.get_attribute('#ci2Sms a.share-wa', 'href')
        tok = urllib.parse.unquote(wa.split('?text=', 1)[1]).split('/a#', 1)[1].strip()
        pid = g['id']
        await page.evaluate('closeAll()')
        sql("update passengers set ret = '%s', car = 'TEST CAR', loc = 'HANGAR 19' where id = %d" % (today, pid))
        await page.evaluate('loadData && loadData()'); await page.wait_for_timeout(1500)

        v = await view(page, tok)
        p = (v['d'] or {}).get('pass') or {}
        check(v['d'] and v['d'].get('state') == 'ok', 'Parked: the link opens (state ok)', v)
        check(not any(k in p for k in ('ticket', 'phone', 'loc')), 'pass never returns ticket / phone / key location', sorted(p.keys()))
        check(not p.get('ready_by_staff') and not p.get('lockbox'), 'Parked: not ready, no lockbox', p)

        await page.evaluate("(async()=>{ await sbUpdate(%d, { ret_time: '18:30' }); })()" % pid)
        v = await view(page, tok); p = v['d']['pass']
        check('18:30' in str(p) or '6:30' in str(p), 'Flying back: return time shows on the pass', {k: p[k] for k in p if 'ret' in k or 'time' in k})

        await page.evaluate("vpRpc('airvalet_pass_state_set', { p_passenger_id: %d, p_field: 'ready', p_value: { on: true } })" % pid)
        v = await view(page, tok); p = v['d']['pass']
        check(p.get('ready_by_staff') is True, 'Ready: the pass shows the car ready', p.get('ready_by_staff'))

        # At Customs = an Ascend return (pickup at Customs) marked ready, or a Customs delivery.
        sql("update passengers set return_operator = 'ASCEND' where id = %d" % pid)
        v = await view(page, tok); p = v['d']['pass']
        check(p.get('status') != 'CUSTOMS_CONFIRMED', 'Ascend return before staff confirm Customs: not shown yet', p.get('status'))
        await page.evaluate("vpRpc('airvalet_pass_state_set', { p_passenger_id: %d, p_field: 'customs_confirmed', p_value: { on: true } })" % pid)
        v = await view(page, tok); p = v['d']['pass']
        check(p.get('status') == 'CUSTOMS_CONFIRMED', 'At Customs: Ascend + Confirm Customs + ready → the pass shows Customs', p.get('status'))
        await page.evaluate("vpRpc('airvalet_pass_state_set', { p_passenger_id: %d, p_field: 'customs_confirmed', p_value: { on: false } })" % pid)
        sql("update passengers set return_operator = 'MAKERS' where id = %d" % pid)
        v = await view(page, tok); p = v['d']['pass']
        check(p.get('status') != 'CUSTOMS_CONFIRMED', 'back to Makers Air: Customs no longer shown', p.get('status'))

        await page.evaluate("vpRpc('airvalet_pass_state_set', { p_passenger_id: %d, p_field: 'lockbox', p_value: { on: true, code: '4321', reveal_on: '%s' } })" % (pid, iso))
        v = await view(page, tok); p = v['d']['pass']
        check('4321' in str(p.get('lockbox')), 'Lockbox: code shows on the reveal day', p.get('lockbox'))

        ok = await page.evaluate("deliverWithTip(%d, 'LOCKBOX', null)" % pid)
        await page.wait_for_timeout(1500)
        chooser = await page.locator('#shareOv a.share-wa').count()
        check(chooser == 1, 'international guest: the delivered text opens WhatsApp / iMessage (no Twilio)', chooser)
        if chooser: await page.click('#shareOv .share-x')
        st = sql("select status || '|' || coalesce(delivery_type,'') from passengers where id=%d" % pid)
        check(st == 'DELIVERED|LOCKBOX', 'Delivered (Lockbox) saved', st)
        v = await view(page, tok); p = (v['d'] or {}).get('pass') or {}
        check(not p.get('lockbox'), 'KNOWN LOCK-A: after "Lockbox" delivery the code is hidden from the passenger', p.get('lockbox'))
        check(sql("select count(*) from airvalet_pass_links where passenger_id=%d and revoked_at is null and expires_at is not null" % pid) == '1', 'Delivered: link gets a 7-day expiry')

        # normal delivery on a second ticket
        name2 = TAG + 'NORMAL ' + RUN
        await ns['v2_fill'](page, name2, '+33 6 12 34 5' + RUN[:2])
        g2 = await ns['v2_yes'](page); await page.wait_for_selector('#ci2Sms.share', timeout=20000)
        wa2 = await page.get_attribute('#ci2Sms a.share-wa', 'href'); tok2 = urllib.parse.unquote(wa2.split('?text=', 1)[1]).split('/a#', 1)[1].strip()
        await page.evaluate('closeAll()')
        ok = await page.evaluate("deliverWithTip(%d, 'CUSTOMS', null)" % g2['id']); await page.wait_for_timeout(1500)
        if await page.locator('#shareOv').count(): await page.click('#shareOv .share-x')
        for sel in ['#customsCommOv.on .ov-close', '#customsCommOv.on button:has-text("Cancel")', '#customsCommOv.on button:has-text("Close")']:
            if await page.locator(sel).count(): await page.click(sel); break
        await page.evaluate("document.querySelectorAll('.ov.on, .overlay.on').forEach(o => o.classList.remove('on'))")
        check(sql("select status || '|' || coalesce(delivery_type,'') from passengers where id=%d" % g2['id']) == 'DELIVERED|CUSTOMS', 'Delivered at Customs saved')
        v = await view(page, tok2)
        check(v['d'] and v['d'].get('state') == 'ok' and v['d']['pass'].get('status') == 'CUSTOMS_CONFIRMED', 'Customs delivery: the pass shows Customs', v['d'] and v['d'].get('pass', {}).get('status'))
        sql("update passengers set customs_gratuity_sent = true where id = %d" % g2['id'])
        v = await view(page, tok2)
        check(v['d']['pass'].get('status') == 'DELIVERED', 'after the Customs gratuity text: the pass shows Delivered', v['d']['pass'].get('status'))

        # isolation
        v = await view(page, 'AAAAAAAAAAAAAAAAA')
        check(not (v['d'] and v['d'].get('state') == 'ok'), 'random token sees nothing', v)
        check(tok != tok2, 'each ticket has its own token')

        # reopen the app: tickets still there
        await page.reload(); await page.wait_for_function('typeof data !== "undefined" && Array.isArray(data) && data.length > 0', timeout=30000)
        n = await page.evaluate("data.filter(r => (r.name||'').indexOf(%r) === 0).length" % TAG)
        check(n == 2, 'after reopening the app both tickets are listed once', n)

        # slow network check-in (Chromium: CDP throttling ~ slow 3G)
        if ENGINE == 'chromium':
            cdp = await ctx.new_cdp_session(page)
            await cdp.send('Network.enable')
            await cdp.send('Network.emulateNetworkConditions', {'offline': False, 'latency': 800, 'downloadThroughput': 50000, 'uploadThroughput': 25000})
            await page.wait_for_timeout(2500)
            await page.evaluate("window.confirm = () => true")
            name3 = TAG + 'SLOW ' + RUN
            await ns['v2_fill'](page, name3, '305555' + RUN + '1')
            g3 = await ns['v2_yes'](page)
            await page.wait_for_timeout(4000)
            await cdp.send('Network.emulateNetworkConditions', {'offline': False, 'latency': 0, 'downloadThroughput': -1, 'uploadThroughput': -1})
            check(sql("select count(*) from passengers where name = '%s'" % name3) == '1', 'slow network: ticket saved exactly once')
            await page.wait_for_timeout(3000)
            check(sql("select count(*) from airvalet_sms_messages m join passengers p on p.id = m.passenger_id where p.name = '%s' and m.message_type = 'CHECK_IN'" % name3) == '1', 'slow network: one welcome SMS (mock)')
            await page.evaluate('closeAll()')

        check(not errs, 'no page errors', errs[:3])
        await ctx.close(); await b.close()
    cleanup()
    print('%d passed, %d failed' % (oks, fails))

asyncio.run(main())
