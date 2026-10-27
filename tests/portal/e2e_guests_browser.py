# LOCAL ONLY. Guests v88 (2026-10-27) — premium UI + Edit guest / vehicle / visit. Earlier scope (v87): tab and server search (name / phone in any format / ticket,
# paging, empty and error states), profile tabs (Overview facts only, Visits + visit detail,
# Activity sources, Tips & Notes with audited notes), Ticket → Guest → Visit → Ticket without
# losing unsaved edits, identity (staff see suggestions, ADMIN merges + undo), check-in
# returning-guest hint (shared phone, fill name/vehicle only on tap, never return date or
# consent), iPhone layout. Tickets are never written. Needs 20261114 on the LOCAL stack.
#   APP=http://127.0.0.1:8797/ ENGINE=chromium|webkit SHOT_DIR=… python3 tests/portal/e2e_guests_browser.py <dir with test_password.txt>
import asyncio, os, subprocess, sys
from playwright.async_api import async_playwright

DIR = sys.argv[1]
APP = os.environ.get('APP', 'http://127.0.0.1:8797/')
ENGINE = os.environ.get('ENGINE', 'chromium')
SHOT = os.environ.get('SHOT_DIR', '/tmp')
PW = open(DIR + '/test_password.txt').read().strip()
oks, fails = 0, 0


def sql(q):
    r = subprocess.run(['docker', 'exec', '-i', 'supabase_db_airvalet-portal-local', 'psql', '-U', 'postgres', '-d', 'postgres', '-qAt', '-c', q], capture_output=True, text=True)
    if r.returncode: raise RuntimeError(r.stderr)
    return r.stdout.strip()


def check(cond, msg, extra=''):
    global oks, fails
    if cond: oks += 1; print('ok  ', msg)
    else: fails += 1; print('FAIL', msg, str(extra)[:400])


CLEAN = """
delete from public.airvalet_guest_note_revisions where note_id in (select id from public.airvalet_guest_notes where guest_key like '%30555583%' or guest_key like 'g:%' and created_at > now() - interval '1 day');
delete from public.airvalet_guest_notes where guest_key like '%30555583%';
delete from public.airvalet_guest_identity where reason like 'E2E%';
delete from public.airvalet_guest_changes where guest_key like '%30555583%' or passenger_id between 982001 and 982020;
delete from public.airvalet_guest_profiles where guest_key like '%30555583%' or passenger_ids && array[982001,982002,982003,982004,982005,982006,982007,982008,982009,982010]::bigint[];
delete from public.airvalet_guest_identity where passenger_id between 982001 and 982020 or from_key like '%30555583%' or to_key like '%30555583%';
select set_config('airvalet.tip_ledger', '1', false);
delete from public.airvalet_tip_records where passenger_id between 982001 and 982020;
delete from public.payments where passenger_id between 982001 and 982020;
delete from public.airvalet_pass_requests where passenger_id between 982001 and 982020;
delete from public.passenger_return_date_changes where passenger_id between 982001 and 982020;
delete from public.activity_log where passenger_id between 982001 and 982020;
delete from public.passengers where id between 982001 and 982020;
"""
FIX = """
insert into public.passengers (id, ts, checkin_date, name, phone, ticket, status, ret, loc, car, color, deldate, checkout_date, previous_delivery_location, obs, tip_received, carwash_status, delivery_type, return_flight) values
 (982001, '6/4/2025 8:04:49', null, 'LIBBY INFINGERX',  '(305) 555-8301', 'GX-1', 'DELIVERED', '6/9/2025', 'HANGAR 19', 'BMW X5', 'Black', '6/9/2025', null, null, null, null, null, null, null),
 (982002, 'x', '2026-09-02 13:00-04', 'RHETT INFINGERX', '+1 305 555 8301', 'GX-2', 'DELIVERED', '9/6/2026', 'HANGAR 19', 'Ford F150', 'White', '', '2026-09-06 10:00-04', 'HANGAR 16', null, false, null, 'NORMAL', null),
 (982003, 'x', '2026-08-01 09:00-04', 'PHILIP STEUBX',  '3055558302', 'GX-3', 'DELIVERED', '8/5/2026', 'HANGAR 19', 'Audi Q7', 'Gray', '', '2026-08-05 15:00-04', 'HANGAR 7', 'Battery was weak, jump started at pickup', null, 'WASHED', 'NORMAL', 'MA 212'),
 (982004, 'x', '2026-10-01 09:00-04', 'PHILIP STEUBEX', '305.555.8302', 'GX-4', 'DELIVERED', '10/4/2026', 'HANGAR 19', 'Audi Q7', 'Gray', '', '2026-10-04 15:00-04', 'HANGAR 16', null, true, null, 'LOCKBOX', 'MA 318'),
 (982005, 'x', '2026-07-01 09:00-04', 'DOANALD RIEDELX', '3055558303', 'GX-5', 'DELIVERED', '7/3/2026', 'HANGAR 19', 'Lexus RX', 'Blue', '7/3/2026', null, null, null, null, null, null, null),
 (982006, 'x', now() - interval '2 days', 'DONALD RIEDELX',  '3055558303', 'GX-6', 'PENDING', to_char((now() at time zone 'America/New_York')::date + 3, 'FMMM/FMDD/YYYY'), 'HANGAR 18', 'Lexus RX', 'Blue', '', null, null, null, null, null, null, null),
 (982007, 'x', '2026-05-05 09:00-04', 'SOFIA BRANDTX', '3055558304', 'GX-7', 'DELIVERED', '5/8/2026', 'HANGAR 19', 'Mini', 'Green', '', '2026-05-08 09:00-04', 'HANGAR 19', null, null, null, 'NORMAL', null),
 (982008, 'x', '2026-09-05 09:00-04', 'SOFIA BRANDTX', '3055558305', 'GX-8', 'DELIVERED', '9/8/2026', 'HANGAR 19', 'Volvo XC90', 'Black', '', '2026-09-08 09:00-04', 'HANGAR 19', null, null, null, 'NORMAL', null),
 (982009, 'x', '2026-04-01 09:00-04', 'MARCO VIANNAX', '3055558306', 'GX-9', 'DELIVERED', '4/3/2026', 'HANGAR 19', 'BMW X5', 'Black', '', '2026-04-03 09:00-04', 'HANGAR 18', null, null, null, 'NORMAL', null),
 (982010, 'x', '2026-06-01 09:00-04', 'MARCO VIANNAX', '3055558306', 'GX-10', 'DELIVERED', '6/3/2026', 'HANGAR 19', 'BMW X5', 'Black', '', '2026-06-03 09:00-04', 'HANGAR 18', null, null, null, 'NORMAL', null),
 (982011, 'x', '2026-08-01 09:00-04', 'MARCO VIANNAX', '3055558306', 'GX-11', 'DELIVERED', '8/3/2026', 'HANGAR 19', 'MERCEDES GLE', 'White', '', '2026-08-03 09:00-04', 'HANGAR 16', null, null, null, 'NORMAL', null);
insert into public.passenger_return_date_changes (passenger_id, passenger_name, ticket, old_return_date, new_return_date, comment, changed_by)
values (982004, 'PHILIP STEUBEX', 'GX-4', '10/3/2026', '10/4/2026', 'Flight moved', 'localipad@airvalet.local');
insert into public.activity_log (ts, action, passenger, ticket, location, detail, passenger_id, changed_by, created_at)
values ('x', 'RETURN DATE', 'PHILIP STEUBEX', 'GX-4', 'HANGAR 16', 'Return date changed: 10/3/2026 → 10/4/2026 | Reason: Flight moved', 982004, 'localipad@airvalet.local', '2026-10-02 11:00-04');
insert into public.airvalet_pass_requests (passenger_id, kind, status, created_at, decided_at, client_key) values (982004, 'CAR_WASH', 'APPROVED', '2026-10-02 10:00-04', '2026-10-02 10:30-04', 'gx-carwash-request-0001');
select set_config('airvalet.tip_ledger', '1', false);
insert into public.airvalet_tip_records (passenger_id, ticket, amount_cents, source, business_date, recorded_by, recorded_at) values (982004, 'GX-4', 2000, 'DELIVERY', '2026-10-04', 'localipad@airvalet.local', '2026-10-04 15:01-04');
update public.passengers set tip_in_person_cents = 2000 where id = 982004;
insert into public.payments (passenger_id, ticket, amount_cents, type, method, status, stripe_event_id, created_at) values (982003, 'GX-3', 1000, 'TIP', 'STRIPE', 'succeeded', 'evt_gx_1', '2026-08-05 16:00-04');
"""


async def guard(route):
    u = route.request.url
    if u.startswith('http://127.0.0.1') or 'fonts.g' in u or 'cdnjs' in u or 'jsdelivr' in u: await route.continue_()
    else: await route.abort()


async def login(b, user='localipad', viewport=None):
    ctx = await b.new_context(viewport=viewport or {'width': 820, 'height': 1180}, service_workers='block')
    await ctx.route('**/*', guard)
    page = await ctx.new_page(); errs = []
    page.on('pageerror', lambda e: errs.append(str(e)))
    page.on('dialog', lambda d: (errs.append('native dialog: ' + d.message), asyncio.ensure_future(d.dismiss())))   # Guests never uses prompt / confirm
    await page.goto(APP + '?checkin=v2')
    await page.wait_for_selector('#loginEmail', state='visible', timeout=20000)
    for attempt in range(3):
        await page.wait_for_timeout(2000)
        await page.fill('#loginEmail', user); await page.fill('#loginPwd', PW); await page.press('#loginPwd', 'Enter')
        try:
            await page.wait_for_function('typeof _currentUserEmail !== "undefined" && !!_currentUserEmail && Array.isArray(data) && data.length > 0', timeout=15000); break
        except Exception:
            if attempt == 2: raise
    await page.wait_for_timeout(1200)
    await page.evaluate('window._msgs = []; var _sm = showMsg; window.showMsg = function (t) { window._msgs.push(String(t)); return _sm.apply(this, arguments); };')
    return ctx, page, errs



async def search(page, q):
    await page.fill('#gxQ', q)
    await page.wait_for_timeout(250)
    await page.wait_for_function('!_gx.loading', timeout=10000)
    await page.wait_for_timeout(200)
    return await page.evaluate('document.getElementById("gxList").innerText')


async def open_guest(page, q, name):
    await search(page, q)
    await page.click('#gxList .gx-gcard:has-text("%s")' % name)
    await page.wait_for_selector('#gxPanel .gx-seg', timeout=10000)
    await page.wait_for_timeout(300)


async def body(page):
    return await page.evaluate('document.querySelector("#gxPanel .gx-content").innerText')


async def section(page, tab):
    await page.click('#gxPanel .gx-seg [data-tab="%s"]' % tab)
    if tab == 'activity': await page.wait_for_function('Array.isArray(_gx.act)', timeout=10000)
    await page.wait_for_timeout(250)
    return await body(page)


A11Y = r"""(root) => {
  const sel = 'button, a[href], input, textarea, select, [role="tab"]', out = {unnamed: [], small: [], lowContrast: []};
  const vis = (e) => { const r = e.getBoundingClientRect(); return r.width > 0 && r.height > 0 && getComputedStyle(e).visibility !== 'hidden'; };
  root.querySelectorAll(sel).forEach(e => {
    if (!vis(e)) return;
    const name = (e.getAttribute('aria-label') || e.innerText || e.value || e.placeholder || (e.labels && e.labels[0] && e.labels[0].innerText) || e.title || '').trim();
    if (!name && e.type !== 'checkbox') out.unnamed.push(e.outerHTML.slice(0, 80));
    const r = e.getBoundingClientRect();
    if (e.type !== 'checkbox' && !e.closest('.gx-sheet-h') && (r.height < 43.5 || r.width < 43.5) && e.tagName !== 'INPUT' && e.tagName !== 'TEXTAREA') out.small.push((e.innerText || e.getAttribute('aria-label') || e.tagName).slice(0, 30) + ' ' + Math.round(r.width) + 'x' + Math.round(r.height));
  });
  const lum = (c) => { const m = c.match(/[\d.]+/g).map(Number); const f = (v) => { v /= 255; return v <= .03928 ? v / 12.92 : Math.pow((v + .055) / 1.055, 2.4); }; return [.2126 * f(m[0]) + .7152 * f(m[1]) + .0722 * f(m[2]), m[3] == null ? 1 : m[3]]; };
  const bg = (e) => { while (e) { const c = getComputedStyle(e).backgroundColor; const a = c.match(/[\d.]+/g); if (a && (a.length < 4 || +a[3] > .95) && !/gradient/.test(getComputedStyle(e).backgroundImage)) return c; if (/gradient/.test(getComputedStyle(e).backgroundImage)) return null; e = e.parentElement; } return 'rgb(255,255,255)'; };
  root.querySelectorAll('b, span, small, p, h2, h3, time, td, th, li, label').forEach(e => {
    if (!vis(e) || !e.childNodes.length || ![...e.childNodes].some(n => n.nodeType === 3 && n.textContent.trim())) return;
    const st = getComputedStyle(e), b = bg(e); if (!b) return;
    const [lf, af] = lum(st.color); if (af < .95) return;
    const [lb] = lum(b), ratio = (Math.max(lf, lb) + .05) / (Math.min(lf, lb) + .05);
    const big = parseFloat(st.fontSize) >= 24 || (parseFloat(st.fontSize) >= 18.66 && +st.fontWeight >= 700);
    if (ratio < (big ? 3 : 4.5)) out.lowContrast.push(e.innerText.slice(0, 24) + ' ' + ratio.toFixed(2));
  });
  return out;
}"""


async def a11y(page, root, label):
    r = await page.evaluate('(%s)(document.querySelector("%s"))' % (A11Y, root))
    check(not r['unnamed'], label + ': every control has an accessible name', r['unnamed'][:3])
    check(not r['small'], label + ': touch targets ≥ 44 px', r['small'][:4])
    check(not r['lowContrast'], label + ': text contrast ≥ 4.5:1 (3:1 large)', r['lowContrast'][:4])


async def main():
    sql(CLEAN); sql(FIX)
    # identity / financial / status fields must never change through Guests; vehicle & notes only where staff saved them.
    FPQ = "select md5(string_agg(p.id || p.name || p.phone || p.ticket || p.status || coalesce(p.ret, '') || coalesce(p.tip_in_person_cents::text, '') || coalesce(p.tip_received::text, '') || coalesce(p.checkin_date::text, '') || coalesce(p.checkout_date::text, ''), '|' order by p.id)) from public.passengers p where p.id between 982001 and 982020"
    before = sql(FPQ)
    sql("select public.airvalet_pass_mint(982006)")   # an active pass link that must survive every edit
    links0 = sql("select md5(string_agg(x::text, '|' order by x.id)) from public.airvalet_pass_links x where passenger_id between 982001 and 982020")
    sms0 = sql("select count(*) from public.airvalet_sms_messages")
    try:
        async with async_playwright() as pw:
            kw = {'executable_path': os.environ['WEBKIT_PATH']} if ENGINE == 'webkit' and os.environ.get('WEBKIT_PATH') else {}
            b = await getattr(pw, ENGINE).launch(**kw)
            ctx, page, errs = await login(b)

            # ── Guests: search + cards ──
            check(await page.is_visible('.tab[data-t="guests"]'), 'Guests tab visible for IPAD_OPS')
            await page.evaluate('document.querySelector(\'.tab[data-t="guests"]\').click()')
            await page.wait_for_function('!_gx.loading && _gx.rows.length > 0', timeout=15000)
            check('Recent passengers' in await page.evaluate('document.getElementById("gxMeta").innerText'), 'opens on recent guests (server, paged)')
            cols = await page.evaluate('getComputedStyle(document.getElementById("gxList")).gridTemplateColumns.split(" ").length')
            check(cols == 2, 'iPad: two-column cards (%s)' % cols)
            await page.wait_for_timeout(300)
            await page.screenshot(path=SHOT + '/v88_list_ipad_%s.png' % ENGINE)
            await a11y(page, '#pane-guests', 'list (iPad)')
            t = await search(page, 'steub')
            card = await page.evaluate('document.querySelector("#gxList .gx-gcard").innerText')
            check('Philip Steubex' in card and 'Gray Audi Q7' in card and 'Last Oct 1, 2026' in card and card.count('(305) 555-8302') == 1, 'card: name, vehicle, last visit, phone once', card)
            check(await page.evaluate('document.querySelector("#gxList .gx-gcard .gx-badge") !== null'), 'returning badge shown (discreet)')
            t = await search(page, '305-555-8301'); check('Libby Infingerx' in t and 'Rhett Infingerx' in t, 'phone in any format: both family members, apart')
            t = await search(page, 'GX-5'); check('Doanald Riedelx' in t, 'ticket number')
            t = await search(page, 'zzzz nobody'); check('No passenger matches' in t, 'empty state with guidance')
            await page.screenshot(path=SHOT + '/v88_empty_ipad_%s.png' % ENGINE)
            await page.route('**/rpc/airvalet_guest_search', lambda r: asyncio.ensure_future(r.fulfill(status=500, body='{"message":"boom"}', content_type='application/json')))
            t = await search(page, 'steub x'); check('Could not load passengers' in t and await page.is_visible('#gxList button:has-text("Try again")'), 'error state + Try again')
            await page.unroute('**/rpc/airvalet_guest_search')
            t0 = await page.evaluate('performance.now()')
            await open_guest(page, 'steub', 'Philip Steubex')
            ms = await page.evaluate('performance.now()') - t0
            check(ms < 2500, 'profile opens fast (%d ms incl. search)' % ms)

            # ── Pass header + Overview ──
            ps = await page.evaluate('document.querySelector("#gxPanel .gx-pass").innerText')
            check('Philip Steubex' in ps and '(305) 555-8302' in ps and 'Returning passenger'.lower() in ps.lower() and 'Aug 2026' in ps and 'Oct 1' in ps and 'Gray Audi Q7' in ps, 'pass header: name, phone, returning, first / last, vehicle', ps)
            ov = await body(page)
            check('returning passenger · 1 previous visit' in ov.lower() and 'usual stay' in ov.lower() and 'last stay' in ov.lower() and 'last parked in' in ov.lower() and 'vehicles' in ov.lower(), 'overview: tiles complete the pass (no repeats), facts, vehicles', ov[:400])
            check('days parked' not in ov.lower(), 'overview does not repeat the pass numbers')
            check('Ticket GX-3: Battery was weak' in ov, 'overview: vehicle issue from the ticket highlighted', ov[:600])
            await page.screenshot(path=SHOT + '/v88_profile_ipad_%s.png' % ENGINE)
            await a11y(page, '#gxPanel', 'profile (iPad)')
            roles = await page.evaluate('[...document.querySelectorAll("#gxPanel .gx-seg [role=tab]")].map(b => b.getAttribute("aria-selected"))')
            check(roles == ['true', 'false', 'false', 'false'], 'sections are a tablist with aria-selected', roles)
            await page.focus('#gxPanel .gx-seg [data-tab="overview"]'); await page.keyboard.press('ArrowRight'); await page.wait_for_timeout(200)
            check(await page.evaluate('_gx.tab') == 'visits', 'arrow keys move between sections')

            # ── Visits ──
            v = await body(page)
            check('GX-4' in v and 'GX-3' in v and 'Return changed ×1' in v and 'Cash $20.00' in v and 'Stripe $10.00' in v and 'Hangar 16' in v and 'Open ticket' in v and 'Edit visit' in v,
                  'visits: tickets, dates, return change, tips, location, actions', v[:500])
            await page.screenshot(path=SHOT + '/v88_visits_ipad_%s.png' % ENGINE)

            # ── Edit visit (operational fields only), unsaved guard ──
            await page.click('#gxPanel .gx-visit:has-text("GX-3") [data-editvisit]'); await page.wait_for_selector('#gxActOv.on.form')
            check(await page.evaluate('document.getElementById("gxVMake").value') == 'Audi' and await page.evaluate('document.getElementById("gxVModel").value') == 'Q7', 'edit visit: vehicle split into make / model')
            await page.fill('#gxVFlight', 'MA 999'); await page.click('#gxFCancel')
            check(await page.is_visible('#gxFDiscard'), 'unsaved changes: asks before closing')
            await page.click('#gxFKeep'); check(await page.evaluate('document.getElementById("gxVFlight").value') == 'MA 999', 'keep editing: nothing lost')
            await page.click('.gx-sw[data-color="Silver"]'); await page.fill('#gxVNotes', 'Battery was weak, jump started at pickup. Replaced 9/2.')
            await page.screenshot(path=SHOT + '/v88_edit_visit_ipad_%s.png' % ENGINE)
            await a11y(page, '#gxActPanel', 'edit visit sheet')
            await page.click('#gxFSave'); await page.wait_for_timeout(1500)
            row = sql("select color || '|' || return_flight || '|' || obs from public.passengers where id = 982003")
            check(row == 'Silver|MA 999|Battery was weak, jump started at pickup. Replaced 9/2.', 'visit saved (color, flight, notes)', row)
            hist = sql("select count(*) from public.activity_log where passenger_id = 982003 and action = 'EDITED' and detail like '%From Passengers' and changed_by = 'localipad@airvalet.local'")
            check(hist == '3', 'each change in the ticket history with who', hist)
            check(await page.evaluate('paxById(982003).color') == 'Silver', 'app data updated at once (no reload)')

            # ── Edit guest: corrected details, tickets untouched, phone validated ──
            await page.click('#gxEditGuest'); await page.wait_for_selector('#gxActOv.on.form')
            await page.fill('#gxEFirst', 'Philip'); await page.fill('#gxELast', 'Steube')
            await page.fill('#gxEPhone', '000'); await page.dispatch_event('#gxEPhone', 'input')
            check('Not a valid phone' in await page.evaluate('document.getElementById("gxEPhoneH").innerText'), 'phone validated while typing')
            await page.click('#gxFSave'); await page.wait_for_timeout(400)
            check('valid phone' in await page.evaluate('document.getElementById("gxFErr").innerText'), 'invalid phone: not saved, clear message')
            await page.fill('#gxEPhone', '(305) 555-8399'); await page.dispatch_event('#gxEPhone', 'input')
            await page.screenshot(path=SHOT + '/v88_edit_guest_ipad_%s.png' % ENGINE)
            await a11y(page, '#gxActPanel', 'edit guest sheet')
            await page.click('#gxFSave'); await page.wait_for_selector('#gxPanel .gx-seg', timeout=10000); await page.wait_for_timeout(800)
            ps = await page.evaluate('document.querySelector("#gxPanel .gx-pass").innerText')
            check('Philip Steube' in ps and '(305) 555-8399' in ps and 'On tickets as Philip Steubex' in ps, 'header shows the corrected details, and the name on tickets', ps)
            check(sql("select count(*) from public.airvalet_guest_changes where field in ('guest_name','guest_phone') and changed_by = 'localipad@airvalet.local'") == '2', 'name + phone change recorded (old / new / who)')
            t = await search(page, '555-8399'); check('Philip Steube' in t, 'search finds the corrected phone')

            # ── Vehicles: two cars stay two cars ──
            await page.evaluate('gxClose()'); await open_guest(page, 'vianna', 'Marco Viannax')
            ov = await body(page)
            check('Black BMW X5' in ov and 'White Mercedes GLE' in ov, 'vehicles: BMW and Mercedes listed apart', ov[:500])
            await page.click('#gxPanel .gx-veh:has-text("BMW") [data-veh]'); await page.wait_for_selector('#gxActOv.on.form')
            ticks = await page.evaluate('[...document.querySelectorAll(".gx-ticks input")].map(i => i.value + ":" + i.checked)')
            check(ticks == ['982010:true', '982009:true'] or sorted(ticks) == ['982009:true', '982010:true'], 'edit BMW: only its 2 visits listed', ticks)
            await page.fill('#gxVModel', 'X6'); await page.uncheck('.gx-ticks input[value="982009"]')
            await page.screenshot(path=SHOT + '/v88_edit_vehicle_ipad_%s.png' % ENGINE)
            await page.click('#gxFSave'); await page.wait_for_timeout(1500)
            cars = sql("select string_agg(id || ':' || car, ',' order by id) from public.passengers where id between 982009 and 982011")
            check(cars == '982009:BMW X5,982010:BMW X6,982011:MERCEDES GLE', 'only the ticked visit changed; Mercedes untouched', cars)

            # ── Activity ──
            await page.evaluate('gxClose()'); await open_guest(page, 'steub', 'Philip Steube')
            a = await section(page, 'activity')
            check('Checked in' in a and 'Return date changed' in a and 'Car wash requested' in a and 'Stripe gratuity confirmed' in a and 'Time not recorded' in a, 'activity: kinds, sources, unknown time', a[:500])
            kinds = await page.evaluate('[...new Set([...document.querySelectorAll("#gxPanel .gx-evi")].map(e => e.className.split(" ")[1]))]')
            check(len(kinds) >= 4 and await page.evaluate('document.querySelectorAll("#gxPanel .gx-ev.issue").length') >= 1, 'event types told apart visually (+ text); vehicle issue flagged', kinds)
            await page.screenshot(path=SHOT + '/v88_activity_ipad_%s.png' % ENGINE)

            # ── Tips & Notes ──
            tn = await section(page, 'tips')
            check('cash · in person' in tn.lower() and 'stripe · confirmed' in tn.lower(), 'cash and Stripe in separate cards', tn[:300])
            check('$20.00' in tn and '$10.00' in tn and 'never rate or rank' in tn, 'amounts only where recorded; not a rating')
            await page.fill('#gxNoteNew', 'Prefers the car facing out')
            await page.evaluate('document.getElementById("gxNoteAdd").click(); document.getElementById("gxNoteAdd").click();'); await page.wait_for_timeout(1500)
            check(sql("select count(*) from public.airvalet_guest_notes where body = 'Prefers the car facing out'") == '1', 'note: double tap saves once')
            await page.screenshot(path=SHOT + '/v88_tips_notes_ipad_%s.png' % ENGINE)
            check(not errs, 'no page errors (iPad)', errs[:3])
            await ctx.close()

            # ── ADMIN: duplicates side by side ──
            actx, apage, aerrs = await login(b, 'localadmin')
            await apage.evaluate('document.querySelector(\'.tab[data-t="guests"]\').click()'); await apage.wait_for_selector('#gxReviewBtn:not([hidden])', timeout=15000)
            await apage.click('#gxReviewBtn'); await apage.wait_for_selector('#gxPanel .gx-rv', timeout=15000); await apage.wait_for_timeout(500)
            rv = await apage.evaluate('document.querySelector("#gxPanel .gx-rv").innerText')
            diffs = await apage.evaluate('document.querySelectorAll("#gxPanel .gx-rv:first-of-type td.diff").length')
            marks = await apage.evaluate('document.querySelectorAll("#gxPanel .gx-rv mark").length')
            check(diffs >= 1 and marks >= 1, 'differences highlighted (cells %d, name words %d)' % (diffs, marks))
            await apage.screenshot(path=SHOT + '/v88_review_ipad_%s.png' % ENGINE)
            await a11y(apage, '#gxPanel', 'duplicates (iPad)')
            await apage.click('#gxPanel .gx-rv:has-text("Riedelx") [data-rvmerge]'); await apage.wait_for_selector('#gxActOv.on')
            check(await apage.evaluate('document.getElementById("gxActGo").disabled'), 'merge needs reason + confirmation')
            await apage.fill('#gxActReason', 'E2E same phone and car'); await apage.check('#gxActOk'); await apage.click('#gxActGo'); await apage.wait_for_timeout(2500)
            check(sql("select count(*) from public.airvalet_guest_identity where reason = 'E2E same phone and car' and revoked_at is null") == '1', 'merged only after the decision')
            check(not aerrs, 'no page errors (ADMIN)', aerrs[:3])
            await actx.close()

            # ── iPhone 390 and 320: one hand, nothing cut ──
            for wdt in (390, 320):
                ictx, ipage, ierrs = await login(b, 'localiphone', {'width': wdt, 'height': 844 if wdt == 390 else 640})
                await ipage.evaluate('document.querySelector(\'.tab[data-t="guests"]\').click()'); await ipage.wait_for_function('!_gx.loading && _gx.rows.length > 0', timeout=15000)
                await search(ipage, 'steub'); await ipage.wait_for_timeout(300)
                check(await ipage.evaluate('document.documentElement.scrollWidth <= %d' % wdt), 'iPhone %d: no sideways scroll on the list' % wdt)
                if wdt == 390: await ipage.screenshot(path=SHOT + '/v88_list_iphone_%s.png' % ENGINE)
                await ipage.click('#gxList .gx-gcard:has-text("Philip Steube")'); await ipage.wait_for_selector('#gxPanel .gx-seg'); await ipage.wait_for_timeout(400)
                cut = await ipage.evaluate('[...document.querySelectorAll("#gxPanel .gx-seg button")].filter(b => b.scrollWidth > b.clientWidth + 1 || b.querySelector("span").scrollWidth > b.querySelector("span").clientWidth + 1).map(b => b.innerText)')
                check(not cut and await ipage.evaluate('document.documentElement.scrollWidth <= %d' % wdt), 'iPhone %d: all four sections fit, none cut' % wdt, cut)
                if wdt == 390:
                    await ipage.screenshot(path=SHOT + '/v88_profile_iphone_%s.png' % ENGINE)
                    await a11y(ipage, '#gxPanel', 'profile (iPhone)')
                    await section(ipage, 'visits'); await ipage.screenshot(path=SHOT + '/v88_visits_iphone_%s.png' % ENGINE)
                    await section(ipage, 'activity'); await ipage.screenshot(path=SHOT + '/v88_activity_iphone_%s.png' % ENGINE)
                    await ipage.click('#gxEditGuest'); await ipage.wait_for_selector('#gxActOv.on.form'); await ipage.wait_for_timeout(300)
                    sh = await ipage.evaluate('(() => { const r = document.querySelector("#gxActPanel").getBoundingClientRect(); return [Math.round(r.width), Math.round(r.bottom)]; })()')
                    check(sh[0] == wdt, 'iPhone: edit sheet full width from the bottom (%s)' % sh)
                    await ipage.screenshot(path=SHOT + '/v88_edit_guest_iphone_%s.png' % ENGINE)
                    await ipage.click('#gxFCancel')
                check(not ierrs, 'no page errors (iPhone %d)' % wdt, ierrs[:3])
                await ictx.close()

            # ── Reduce Motion ──
            rctx = await b.new_context(viewport={'width': 820, 'height': 1180}, reduced_motion='reduce', service_workers='block')
            await rctx.route('**/*', guard); rp = await rctx.new_page(); await rp.goto(APP)
            anim = await rp.evaluate('(() => { const d = document.createElement("div"); d.className = "gx-ov on"; d.innerHTML = "<div class=gx-panel></div><div class=\'gx-skel\'><i></i></div>"; document.body.appendChild(d); const a = getComputedStyle(d.querySelector(".gx-panel")).animationName, b = getComputedStyle(d.querySelector(".gx-skel i")).animationName; d.remove(); return a + "|" + b; })()')
            check(anim == 'none|none', 'Reduce Motion: no panel or skeleton animation (%s)' % anim)
            await rctx.close(); await b.close()
    finally:
        check(sql(FPQ) == before, 'names, phones, status, return, tips, dates of every ticket unchanged')
        check(sql("select md5(string_agg(x::text, '|' order by x.id)) from public.airvalet_pass_links x where passenger_id between 982001 and 982020") == links0, 'Valet Pass link not revoked by any edit')
        check(sql("select count(*) from public.airvalet_sms_messages") == sms0, 'no text sent by any edit')
        sql(CLEAN)
    print('\n%d ok, %d failed' % (oks, fails))
    sys.exit(1 if fails else 0)

asyncio.run(main())
