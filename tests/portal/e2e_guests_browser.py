# LOCAL ONLY. Guests (2026-10-27): tab and server search (name / phone in any format / ticket,
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
 (982008, 'x', '2026-09-05 09:00-04', 'SOFIA BRANDTX', '3055558305', 'GX-8', 'DELIVERED', '9/8/2026', 'HANGAR 19', 'Volvo XC90', 'Black', '', '2026-09-08 09:00-04', 'HANGAR 19', null, null, null, 'NORMAL', null);
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
    await page.click('#gxList .gx-row:has-text("%s")' % name)
    await page.wait_for_selector('#gxPanel .gx-tabs', timeout=10000)
    await page.wait_for_timeout(300)


async def body(page):
    return await page.evaluate('document.querySelector("#gxPanel .gx-body").innerText')


async def main():
    sql(CLEAN); sql(FIX)
    before = sql("select md5(string_agg(p::text, '|' order by p.id)) from public.passengers p where p.id between 982001 and 982020")
    try:
        async with async_playwright() as pw:
            kw = {'executable_path': os.environ['WEBKIT_PATH']} if ENGINE == 'webkit' and os.environ.get('WEBKIT_PATH') else {}
            b = await getattr(pw, ENGINE).launch(**kw)
            ctx, page, errs = await login(b)

            # ── Tab + list ──
            check(await page.is_visible('.tab[data-t="guests"]'), 'Guests tab visible for IPAD_OPS')
            await page.evaluate('document.querySelector(\'.tab[data-t="guests"]\').click()')
            await page.wait_for_function('!_gx.loading && _gx.rows.length > 0', timeout=15000)
            meta = await page.evaluate('document.getElementById("gxMeta").innerText')
            check('Most recent guests' in meta, 'opens on the most recent guests (server, paged)', meta)
            await page.wait_for_timeout(300)
            await page.screenshot(path=SHOT + '/guests_list_ipad_%s.png' % ENGINE)
            h = await page.evaluate('Math.round(document.querySelector("#gxList .gx-row").getBoundingClientRect().height)')
            check(h >= 44, 'list rows are ≥ 44 px (%s)' % h)

            # ── Search ──
            t = await search(page, 'steub')
            check('Philip Steubex' in t and 'Returning · 2 visits' in t, 'name, partial: one guest with both spellings, 2 visits', t)
            t = await search(page, '305-555-8301')
            check('Libby Infingerx' in t and 'Rhett Infingerx' in t, 'phone with dashes: both family members, kept apart', t)
            t = await search(page, '5558302')
            check('Philip Steubex' in t, 'phone, last digits', t)
            t = await search(page, 'GX-5')
            check('Doanald Riedelx' in t and 'Donald Riedelx' not in t, 'ticket number', t)
            t = await search(page, 'zzzz nobody')
            check('No guest matches' in t, 'no match: helpful empty state', t)
            await page.screenshot(path=SHOT + '/guests_empty_ipad_%s.png' % ENGINE)
            n = await page.evaluate('(async () => { var a = await gxRpc("airvalet_guest_search", {p_q: "GX-", p_limit: 2, p_offset: 0}); var b2 = await gxRpc("airvalet_guest_search", {p_q: "GX-", p_limit: 2, p_offset: 2}); return [a.rows.length, a.has_more, b2.rows.length, a.rows[0].guest_key !== b2.rows[0].guest_key]; })()')
            check(n[0] == 2 and n[1] and n[2] >= 1 and n[3], 'paging: next page brings other guests', n)
            # error state
            await page.route('**/rpc/airvalet_guest_search', lambda r: asyncio.ensure_future(r.fulfill(status=500, body='{"message":"boom"}', content_type='application/json')))
            t = await search(page, 'steub x')
            check('Could not load guests' in t and await page.is_visible('#gxList button:has-text("Try again")'), 'server error: message + Try again', t)
            await page.unroute('**/rpc/airvalet_guest_search')

            # ── Profile: Overview ──
            await open_guest(page, 'steub', 'Philip Steubex')
            ov = await body(page)
            check('Returning guest · 1 previous visit' in ov and 'Last visit: October 2026' in ov and 'Usually parks about 4 days' in ov and 'Gray Audi Q7' in ov,
                  'overview: only facts on record (returning, last visit, usual stay, vehicle)', ov[:500])
            check('Also checked in as: Philip Steubx' in ov, 'overview: other spelling shown', ov[:600])
            await page.screenshot(path=SHOT + '/guests_profile_ipad_%s.png' % ENGINE)

            # ── Visits + detail ──
            await page.click('#gxPanel .gx-tabs button:has-text("Visits")')
            v = await body(page)
            check('GX-4' in v and 'GX-3' in v and 'Return changed ×1' in v and 'Cash $20.00' in v and 'Stripe $10.00' in v and 'Car wash · washed' in v,
                  'visits: tickets, dates, return change, cash + Stripe, services', v[:600])
            await page.screenshot(path=SHOT + '/guests_visits_ipad_%s.png' % ENGINE)
            await page.click('#gxPanel .gx-visit:has-text("GX-4")')
            d = await body(page)
            check('10/3/2026' in d and '10/4/2026' in d and 'Flight moved' in d and 'Hangar 16' in d and 'MA 318' in d, 'visit detail: planned vs current return, reason, hangar, flight', d[:700])
            await page.screenshot(path=SHOT + '/guests_visit_detail_ipad_%s.png' % ENGINE)
            # Ticket → Guest → Visit → Ticket, unsaved edits protected
            await page.evaluate('gxClose(); showDet(982004)'); await page.wait_for_selector('#detOv.on')
            await page.click('#detPanel .gx-tk-btn'); await page.wait_for_selector('#gxPanel .gx-tabs', timeout=10000)
            check(await page.evaluate('document.getElementById("detOv").classList.contains("on") && document.getElementById("gxOv").classList.contains("on")'), 'Guest Profile opens over the ticket (ticket stays open)')
            await page.evaluate('_editChanges = {obs: "typed but not saved"}')
            await page.click('#gxPanel .gx-tabs button:has-text("Visits")'); await page.click('#gxPanel .gx-visit:has-text("GX-3")')
            await page.click('#gxPanel button:has-text("Open ticket GX-3")'); await page.wait_for_timeout(400)
            check(await page.evaluate('document.getElementById("gxOv").classList.contains("on") && _editChanges.obs === "typed but not saved"') and 'Save or discard' in await page.evaluate('window._msgs.join(" / ")'),
                  'unsaved ticket edits: opening another ticket is refused, nothing lost')
            await page.evaluate('_editChanges = {}')
            await page.click('#gxPanel button:has-text("Open ticket GX-3")'); await page.wait_for_timeout(600)
            check(await page.evaluate('!document.getElementById("gxOv").classList.contains("on") && document.getElementById("detOv").classList.contains("on") && document.querySelector("#detPanel .dname").innerText.indexOf("STEUBX") >= 0'),
                  'Visit → Open ticket shows that ticket')
            await page.evaluate('closeAll()')

            # ── Activity ──
            await page.evaluate('gxOpen(_gx.rows.length ? null : null)') if False else None
            await page.evaluate('document.querySelector(\'.tab[data-t="guests"]\').click()'); await open_guest(page, 'steub', 'Philip Steubex')
            await page.click('#gxPanel .gx-tabs button:has-text("Activity")')
            await page.wait_for_function('Array.isArray(_gx.act)', timeout=10000); await page.wait_for_timeout(300)
            a = await body(page)
            check('Checked in' in a and 'Return date changed' in a and 'Car wash requested' in a and 'Stripe gratuity confirmed' in a and 'Note on the ticket' in a and 'time not recorded' in a,
                  'activity: check-in, return change, guest request, Stripe, ticket note (time not recorded)', a[:700])
            issue = await page.evaluate('document.querySelectorAll("#gxPanel .gx-ev.issue").length')
            check(issue >= 1 and 'From the guest' in a and 'Entered by the team' in a and 'Recorded by AirValet' in a, 'sources told apart (AirValet / team / guest) and the battery note flagged')
            await page.screenshot(path=SHOT + '/guests_activity_ipad_%s.png' % ENGINE)

            # ── Tips & Notes ──
            await page.click('#gxPanel .gx-tabs button:has-text("Tips & Notes")')
            tn = await body(page)
            check('$20.00' in tn and 'Cash recorded' in tn and '$10.00' in tn and 'never rate or rank' in tn, 'tips: cash + Stripe totals, not a rating', tn[:400])
            await page.fill('#gxNoteNew', 'Prefers the car facing out')
            await page.evaluate('document.getElementById("gxNoteAdd").click(); document.getElementById("gxNoteAdd").click();')
            await page.wait_for_timeout(1500)
            check(sql("select count(*) from public.airvalet_guest_notes where body = 'Prefers the car facing out'") == '1', 'double tap on Save note → one note')
            await page.click('#gxPanel .gx-tabs button:has-text("Tips & Notes")') if not await page.is_visible('#gxNoteNew') else None
            await page.click('#gxPanel button[data-edit]'); await page.fill('#gxPanel .gx-note textarea', 'Prefers the car facing out, keys in hand')
            await page.click('#gxPanel .gx-note button:has-text("Save")'); await page.wait_for_timeout(1500)
            tn = await body(page)
            check('keys in hand' in tn and 'History (2)' in tn and 'edited by localipad' in tn, 'edit keeps the history (2 revisions, who)', tn[-500:])
            await page.screenshot(path=SHOT + '/guests_tips_notes_ipad_%s.png' % ENGINE)
            await page.click('#gxPanel button[data-del]'); await page.wait_for_selector('#gxActOv.on')
            check(await page.evaluate('document.getElementById("gxActGo").disabled'), 'delete note: button stays off until confirmed')
            await page.check('#gxActOk'); await page.click('#gxActGo'); await page.wait_for_timeout(1500)
            check('No notes yet' in await body(page) and sql("select count(*) from public.airvalet_guest_note_revisions r join public.airvalet_guest_notes n on n.id = r.note_id where n.body like 'Prefers the car%'") == '3',
                  'delete hides the note, history kept (3 entries)')
            vt = await page.evaluate('''(async () => { var p = await gxRpc("airvalet_guest_profile", {p_key: (await gxRpc("airvalet_guest_for_passenger", {p_passenger_id: 982002})).key}); _gx.prof = p; _gx.key = p.key; _gx.tab = "tips"; gxRender(); return document.querySelector("#gxPanel .gx-body").innerText; })()''')
            v2 = await page.evaluate('''(async () => { var p = await gxRpc("airvalet_guest_profile", {p_key: (await gxRpc("airvalet_guest_for_passenger", {p_passenger_id: 982001})).key}); _gx.prof = p; _gx.key = p.key; _gx.tab = "tips"; gxRender(); return document.querySelector("#gxPanel .gx-body").innerText; })()''')
            check('No tip (recorded by the team)' in vt and 'No tip record' in v2, 'no record kept apart from a recorded "No"', (vt[-200:], v2[-200:]))

            # ── Identity: staff see suggestions only ──
            await page.evaluate('gxClose()'); await open_guest(page, 'riedelx', 'Donald Riedelx')
            ov = await body(page)
            check('possible same guest' in ov.lower() and 'Doanald Riedelx' in ov and not await page.is_visible('#gxPanel [data-merge]') and not await page.is_visible('#gxPanel [data-distinct]'),
                  'IPAD_OPS: suggestion highlighted, no Merge / Not the same buttons', ov[-400:])
            check(not await page.is_visible('#gxReviewBtn'), 'IPAD_OPS: no duplicate review')
            # the public side (anon key, no login — what the Valet Pass has) reads nothing
            anon = await page.evaluate('''(async () => { var h = {apikey: SUPABASE_KEY, Authorization: 'Bearer ' + SUPABASE_KEY, 'Content-Type': 'application/json'}, out = {};
              for (var f of ['airvalet_guest_search', 'airvalet_guest_profile', 'airvalet_guest_lookup_phone', 'airvalet_guest_review'])
                out[f] = (await fetch(SUPABASE_URL + '/rest/v1/rpc/' + f, {method: 'POST', headers: h, body: '{}'})).status;
              for (var t of ['airvalet_guest_notes', 'airvalet_guest_identity', 'airvalet_guest_note_revisions']) {
                var r = await fetch(SUPABASE_URL + '/rest/v1/' + t + '?select=*', {headers: h}); out[t] = r.status + ':' + (await r.text()).slice(0, 20); }
              return out; })()''')
            check(all(v in (401, 403, 404) for k, v in anon.items() if k.startswith('airvalet_guest_s') or k in ('airvalet_guest_profile', 'airvalet_guest_lookup_phone', 'airvalet_guest_review'))
                  and all(not str(v).startswith('200:[{') for k, v in anon.items() if k.startswith('airvalet_guest_n') or k == 'airvalet_guest_identity'),
                  'anon (public Valet Pass key) cannot call guest functions or read notes / decisions', anon)
            await page.evaluate('gxClose()')

            # ── Check-in hint (v2): shared phone, fill only on tap ──
            await page.evaluate('openAdd()'); await page.wait_for_selector('#ci2Phone', timeout=10000)
            await page.fill('#ci2Phone', '3055558301'); await page.dispatch_event('#ci2Phone', 'input')
            await page.wait_for_selector('#gxCi2:not([hidden]) .gx-ci-r', timeout=10000)
            ci = await page.evaluate('document.getElementById("gxCi2").innerText')
            name0 = await page.evaluate('document.getElementById("ci2Name").value')
            check('2 guests' in ci.lower() and 'Libby Infingerx' in ci and 'Rhett Infingerx' in ci and name0 == '', 'check-in: shared phone lists both people, nothing filled yet', ci)
            await page.screenshot(path=SHOT + '/guests_checkin_hint_ipad_%s.png' % ENGINE)
            await page.click('#gxCi2 .gx-ci-r:has-text("Rhett") button[data-use]')
            st = await page.evaluate('({n: document.getElementById("ci2Name").value, veh: _ci.vehText, ret: _ci.ret || null, consent: _ci.consent})')
            check(st['n'] == 'RHETT INFINGERX' and 'F150' in (st['veh'] or '') and st['ret'] is None and st['consent'] is None, 'Use name & vehicle: name + vehicle only; return date and consent untouched', st)
            await page.click('#gxCi2 .gx-ci-r:has-text("Libby") button[data-prof]'); await page.wait_for_selector('#gxPanel .gx-tabs', timeout=10000)
            check(await page.evaluate('document.getElementById("addOv").classList.contains("on") && document.getElementById("ci2Name").value === "RHETT INFINGERX"'), 'profile opens over the check-in; the form keeps what was typed')
            await page.evaluate('gxClose()'); await page.evaluate('document.getElementById("ci2Name").value=""; document.getElementById("ci2Phone").value=""; closeAll()')
            check(not errs, 'no page errors (iPad)', errs[:3])
            await ctx.close()

            # ── ADMIN: duplicate review, merge with reason + confirmation, undo ──
            actx, apage, aerrs = await login(b, 'localadmin')
            await apage.evaluate('document.querySelector(\'.tab[data-t="guests"]\').click()'); await apage.wait_for_function('!_gx.loading', timeout=15000)
            await apage.wait_for_selector('#gxReviewBtn:not([hidden])', timeout=10000)
            rb = await apage.evaluate('document.getElementById("gxReviewBtn").innerText')
            check('possible duplicate' in rb.lower(), 'ADMIN: duplicates to review are highlighted', rb)
            await apage.screenshot(path=SHOT + '/guests_review_banner_ipad_%s.png' % ENGINE)
            await apage.click('#gxReviewBtn'); await apage.wait_for_selector('#gxPanel .gx-rv', timeout=15000)
            rv = await body(apage)
            check('Doanald Riedelx' in rv and 'Donald Riedelx' in rv and 'Sofia Brandtx' in rv and 'Infingerx' not in rv, 'review lists the typo pair and the same-name pair, not the family', rv[:600])
            await apage.screenshot(path=SHOT + '/guests_review_ipad_%s.png' % ENGINE)
            # Not the same person (Sofia)
            await apage.click('#gxPanel .gx-rv:has-text("Sofia Brandtx") [data-rvdistinct]'); await apage.wait_for_selector('#gxActOv.on')
            dis = await apage.evaluate('document.getElementById("gxActGo").disabled')
            await apage.fill('#gxActReason', 'E2E two different Sofias'); dis2 = await apage.evaluate('document.getElementById("gxActGo").disabled')
            await apage.check('#gxActOk'); dis3 = await apage.evaluate('document.getElementById("gxActGo").disabled')
            check(dis and dis2 and not dis3, 'sheet: needs a reason AND the confirmation before the button works', (dis, dis2, dis3))
            await apage.click('#gxActGo'); await apage.wait_for_selector('#gxPanel .gx-rv', timeout=15000); await apage.wait_for_timeout(500)
            check('Sofia Brandtx' not in await body(apage) and sql("select count(*) from public.airvalet_guest_identity where kind = 'DISTINCT' and revoked_at is null and reason = 'E2E two different Sofias'") == '1',
                  '"Not the same person": pair leaves the review, decision recorded')
            # Merge DOANALD → DONALD (DONALD kept: more recent)
            await apage.click('#gxPanel .gx-rv:has-text("Riedelx") [data-rvmerge]'); await apage.wait_for_selector('#gxActOv.on')
            await apage.fill('#gxActReason', 'E2E same phone and car, typo')
            await apage.screenshot(path=SHOT + '/guests_merge_sheet_ipad_%s.png' % ENGINE)
            sheet = await apage.evaluate('document.getElementById("gxActPanel").innerText')
            check('No ticket is changed' in sheet and 'Keep the other one' in sheet, 'merge sheet explains the effect and lets you pick which guest stays', sheet[:300])
            await apage.check('#gxActOk'); await apage.click('#gxActGo'); await apage.wait_for_timeout(2500)
            check(sql("select count(*) from public.airvalet_guest_identity where kind = 'MERGE' and revoked_at is null and reason = 'E2E same phone and car, typo'") == '1', 'merge recorded with reason and who')
            await apage.screenshot(path=SHOT + '/guests_review_after_ipad_%s.png' % ENGINE)
            await apage.evaluate('gxClose()')
            await open_guest(apage, 'riedelx', 'Donald Riedelx')
            ov = await body(apage)
            check('Returning guest' in ov and 'identity history' in ov.lower() and 'Guest merged' in ov, 'merged guest: 2 visits, decision in Identity history', ov[-400:])
            await apage.screenshot(path=SHOT + '/guests_identity_ipad_%s.png' % ENGINE)
            await apage.click('#gxPanel [data-undo]'); await apage.wait_for_selector('#gxActOv.on')
            await apage.fill('#gxActReason', 'E2E undo'); await apage.check('#gxActOk'); await apage.click('#gxActGo'); await apage.wait_for_timeout(2500)
            check(sql("select count(*) from public.airvalet_guest_identity where kind = 'MERGE' and revoked_at is not null and reason = 'E2E same phone and car, typo'") == '1' and 'undone by localadmin' in await body(apage),
                  'Undo through the sheet: decision kept, marked undone')
            check(sql("select count(*) from public.airvalet_guest_identity where reason like 'E2E%' and created_by = 'localadmin@airvalet.local'") == '2', 'decisions carry the signed-in account')
            check(not aerrs, 'no page errors (ADMIN)', aerrs[:3])
            await actx.close()

            # ── iPhone ──
            ictx, ipage, ierrs = await login(b, 'localiphone', {'width': 390, 'height': 844})
            await ipage.evaluate('openSidebarDrawer && openSidebarDrawer()'); await ipage.wait_for_timeout(400)
            await ipage.click('.tab[data-t="guests"]')   # through the iPhone drawer, as staff do; await ipage.wait_for_function('!_gx.loading && _gx.rows.length > 0', timeout=15000)
            await search(ipage, 'steub'); await ipage.wait_for_timeout(300)
            check(await ipage.evaluate('document.documentElement.scrollWidth <= 390'), 'iPhone: no sideways scroll on the list')
            check(not await ipage.is_visible('#gxMore'), 'one result: no "Show more" button')
            await ipage.screenshot(path=SHOT + '/guests_list_iphone_%s.png' % ENGINE)
            await ipage.click('#gxList .gx-row:has-text("Philip Steubex")'); await ipage.wait_for_selector('#gxPanel .gx-tabs')
            await ipage.wait_for_timeout(400)
            w = await ipage.evaluate('Math.round(document.getElementById("gxPanel").getBoundingClientRect().width)')
            check(w == 390 and await ipage.evaluate('document.documentElement.scrollWidth <= 390'), 'iPhone: profile full screen, no sideways scroll (%s)' % w)
            await ipage.screenshot(path=SHOT + '/guests_profile_iphone_%s.png' % ENGINE)
            await ipage.click('#gxPanel .gx-tabs button:has-text("Activity")'); await ipage.wait_for_function('Array.isArray(_gx.act)', timeout=10000); await ipage.wait_for_timeout(300)
            await ipage.screenshot(path=SHOT + '/guests_activity_iphone_%s.png' % ENGINE)
            check(not ierrs, 'no page errors (iPhone)', ierrs[:3])
            await ictx.close(); await b.close()
    finally:
        after = sql("select md5(string_agg(p::text, '|' order by p.id)) from public.passengers p where p.id between 982001 and 982020")
        check(after == before, 'tickets never written by Guests (rows identical before / after)')
        sql(CLEAN)
    print('\n%d ok, %d failed' % (oks, fails))
    sys.exit(1 if fails else 0)

asyncio.run(main())
