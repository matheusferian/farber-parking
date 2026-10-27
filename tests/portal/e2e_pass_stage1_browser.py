# Valet Pass Stage 1 (2026-10-27): quiet gratuity during the trip, elegant card
# after delivery, no amount pre-selected, chips only when per-amount links are
# configured, Valet Terms never linked to the SMS terms, "Valet information"
# sheet, privacy-safe gratuity click count, 44 px targets.
# LOCAL ONLY: app served by serve_root.py, local Supabase + functions (mock SMS).
# Run: LDB=<psql-on-stdin helper> PASS_BASE=http://127.0.0.1:8795/a# PASS_ENGINE=chromium|webkit \
#      SHOT_DIR=<dir> python3 tests/portal/e2e_pass_stage1_browser.py
# STAGE1_MODE=shots only takes one screenshot per state (prefix SHOT_PREFIX), for before/after.
import os, random, subprocess, sys
from playwright.sync_api import sync_playwright

LDB = os.environ.get('LDB') or sys.exit('set LDB to the local psql helper')
BASE = os.environ.get('PASS_BASE', 'http://127.0.0.1:8795/a#')
ENGINE = os.environ.get('PASS_ENGINE', 'chromium')
MODE = os.environ.get('STAGE1_MODE', 'test')
SHOTS = os.environ.get('SHOT_DIR', '/tmp')
PREFIX = os.environ.get('SHOT_PREFIX', 'stage1')
API = '**/functions/v1/valet-pass'
COPY = 'Our valet service is complimentary. If you’d like to say thank you, a gratuity is always optional.'
ok_n = 0; fails = []

def sql(q):
    r = subprocess.run([LDB], input=q, capture_output=True, text=True)
    if r.returncode != 0: raise SystemExit(r.stderr)
    return r.stdout.strip()

def check(cond, label):
    global ok_n
    if cond: ok_n += 1; print('ok  ', label)
    else: fails.append(label); print('FAIL', label)

def rip(): return '10.%d.%d.%d' % (random.randint(0, 255), random.randint(0, 255), random.randint(1, 254))
def d(n): return "to_char((now() at time zone 'America/New_York')::date + %d, 'FMMM/FMDD/YYYY')" % n

# id, name, ticket, ret, loc, car, operator → expected status word
STATES = [
    (960001, 'parked', 'Parked'), (960002, 'flying_back', 'Flying back'), (960003, 'pending_return_wash', 'Parked'),
    (960004, 'ready', 'Ready'), (960005, 'ready_lockbox', 'Ready'), (960006, 'customs_ascend', 'At Customs'),
    (960007, 'customs_waiting', 'At Customs'), (960008, 'delivered', 'Delivered'),
]
FIX = """
insert into public.airvalet_sms_devices (key_hash, label, status, decided_at)
values (public.airvalet_sms_device_key_hash('e2es1_device_key_sssssssssssssssssssssssssssssssssssssssss'), 'E2ES1 iPad', 'approved', now())
on conflict do nothing;
insert into public.passengers (id, ts, checkin_date, name, phone, ticket, status, ret, loc, car, color, return_operator, return_flight, departure_time, carwash_status) values
 (960001, 'x', now(), 'OLIVIA PARKER', '3055556001', 'S1-01', 'PENDING', %(d5)s, 'HANGAR 16', 'MERCEDES GLE', 'Black', 'MAKERS', null, null, null),
 (960002, 'x', now(), 'LIAM FLYER',    '3055556002', 'S1-02', 'PENDING', %(d1)s, 'HANGAR 16', 'AUDI Q7', 'White', 'MAKERS', 'MA 212', '17:40', null),
 (960003, 'x', now(), 'EMMA CHANGE',   '3055556003', 'S1-03', 'PENDING', %(d4)s, 'HANGAR 16', 'RANGE ROVER', 'Gray', 'MAKERS', null, null, 'CARWASH'),
 (960004, 'x', now(), 'NOAH READY',    '3055556004', 'S1-04', 'PENDING', %(d0)s, 'HANGAR 19', 'TESLA MODEL Y', 'Blue', 'MAKERS', null, null, null),
 (960005, 'x', now(), 'AVA LOCKBOX',   '3055556005', 'S1-05', 'PENDING', %(d0)s, 'HANGAR 16', 'BMW X5', 'Black', 'MAKERS', null, null, null),
 (960006, 'x', now(), 'LUCAS ASCEND',  '3055556006', 'S1-06', 'PENDING', %(d0)s, 'HANGAR 16', 'CADILLAC ESCALADE', 'Black', 'ASCEND', null, null, null),
 (960007, 'x', now(), 'MIA CUSTOMS',   '3055556007', 'S1-07', 'PENDING', %(d0)s, 'HANGAR 16', 'PORSCHE CAYENNE', 'Red', 'MAKERS', null, null, null),
 (960008, 'x', now(), 'ETHAN DONE',    '3055556008', 'S1-08', 'PENDING', %(d0)s, 'HANGAR 16', 'LEXUS LX', 'Silver', 'MAKERS', null, null, null);
insert into public.airvalet_sms_enrollments (passenger_id, phone_e164, device_id, consent_id)
select p.id, public.airvalet_sms_normalize_phone(p.phone), (select id from public.airvalet_sms_devices where label = 'E2ES1 iPad'), gen_random_uuid()
  from public.passengers p where p.id between 960001 and 960008;
insert into public.airvalet_pass_state (passenger_id, ready_at) values (960004, now());
insert into public.airvalet_pass_state (passenger_id, ready_at, lockbox_authorized_at, lockbox_reveal_on, lockbox_code)
  values (960005, now(), now(), (now() at time zone 'America/New_York')::date, 'S1-LBX');
insert into public.airvalet_pass_state (passenger_id, customs_confirmed_at, ready_at) values (960006, now(), now());
insert into public.airvalet_pass_requests (passenger_id, kind, reason, requested_date, requested_time, client_key)
  values (960003, 'RETURN_CHANGE', 'FLIGHT_CHANGED', (now() at time zone 'America/New_York')::date + 6, '18:30', 'ck_s1_pending_return_0001');
update public.passengers set status = 'DELIVERED', delivery_type = 'CUSTOMS', customs_gratuity_sent = false where id = 960007;
update public.passengers set status = 'DELIVERED', delivery_type = 'NORMAL' where id = 960008;
""" % {'d0': d(0), 'd1': d(1), 'd4': d(4), 'd5': d(5)}
CLEAN = """
delete from public.airvalet_pass_requests where passenger_id between 960001 and 960008;
delete from public.airvalet_sms_messages where passenger_id between 960001 and 960008;
delete from public.airvalet_pass_links where passenger_id between 960001 and 960008;
delete from public.airvalet_pass_state where passenger_id between 960001 and 960008;
delete from public.airvalet_sms_enrollments where passenger_id between 960001 and 960008;
delete from public.activity_log where passenger_id between 960001 and 960008;
delete from public.passengers where id between 960001 and 960008;
delete from public.airvalet_sms_devices where label = 'E2ES1 iPad';
"""
HAS_FLAGS = sql("select count(*) from information_schema.columns where table_name = 'airvalet_portal_settings' and column_name in ('gratuity_links', 'gratuity_reference')") == '2'
SAVED = sql("select chat_enabled || '|' || terms_published" + (" || '|' || gratuity_reference || '|' || gratuity_links::text" if HAS_FLAGS else '') + " from public.airvalet_portal_settings").split('|', 3)
def restore():
    q = "update public.airvalet_portal_settings set chat_enabled = %s, terms_published = %s" % (SAVED[0], SAVED[1])
    if HAS_FLAGS: q += ", gratuity_reference = %s, gratuity_links = '%s'::jsonb" % (SAVED[2], SAVED[3].replace("'", "''"))
    sql(q + ';')

sql(CLEAN); sql(FIX)
TOK = {sid: sql("select public.airvalet_pass_mint(%d);" % sid).splitlines()[-1] for sid, _, _ in STATES}
sql("update public.airvalet_portal_settings set chat_enabled = true;")  # as in production
GURL = sql("select gratuity_url from public.airvalet_portal_settings")

VISIBLE_TARGETS = """(function(root){
  var out=[]; [].forEach.call(document.querySelectorAll(root+' a, '+root+' button'), function(e){
    var r=e.getBoundingClientRect(), s=getComputedStyle(e);
    if(!r.width||!r.height||s.visibility==='hidden') return;
    if(r.height<44||r.width<44) out.push((e.textContent||e.getAttribute('aria-label')||e.tagName).trim().slice(0,30)+' '+Math.round(r.width)+'x'+Math.round(r.height));
  }); return out; })"""
SELECTED = """document.querySelectorAll('[aria-pressed="true"],[aria-checked="true"],[aria-selected="true"],.selected,.active,input:checked').length"""

try:
    with sync_playwright() as pw:
        b = getattr(pw, ENGINE).launch(**({'executable_path': os.environ['WEBKIT_PATH']} if ENGINE == 'webkit' and os.environ.get('WEBKIT_PATH') else {}))
        def ctx(motion='no-preference'):
            c = b.new_context(viewport={'width': 390, 'height': 844}, device_scale_factor=2, reduced_motion=motion)
            ip = rip(); st = {'stripe': []}
            def fix(route):
                h = dict(route.request.headers); h['x-forwarded-for'] = ip; route.continue_(headers=h)
            c.route(API, fix)
            def stripe(route):  # never reach Stripe: a stub page instead
                st['stripe'].append(route.request.url); route.fulfill(status=200, body='<html><body>stub</body></html>', headers={'content-type': 'text/html'})
            c.route('https://buy.stripe.com/**', stripe)
            return c, st
        def openp(c, sid):
            p = c.new_page(); p.goto(BASE + TOK[sid]); p.wait_for_selector('.pass'); p.wait_for_timeout(400); return p
        def vis(p): p.evaluate("document.dispatchEvent(new Event('visibilitychange'))"); p.wait_for_timeout(1500)

        if MODE == 'shots':
            for sid, name, _ in STATES:
                c, _st = ctx(); p = openp(c, sid)
                p.screenshot(path='%s/%s_%s_%s.png' % (SHOTS, PREFIX, name, ENGINE), full_page=True); c.close()
            raise SystemExit(0)

        for motion in ('no-preference', 'reduce'):
            for sid, name, word in STATES:
                c, st = ctx(motion); p = openp(c, sid); tag = '%s [%s]' % (name, motion)
                check(p.inner_text('.pass-status').strip() == word, '%s: status "%s"' % (tag, word))
                check(p.query_selector('.btn.brass') is None, '%s: no gold gratuity button' % tag)
                done = sid == 960008
                if done:
                    g = p.query_selector('.grat')
                    check(g is not None and p.inner_text('.grat-copy').strip() == COPY, '%s: gratuity card with the neutral copy' % tag)
                    check(len(p.query_selector_all('.grat a[data-grat]')) == 1 and p.query_selector('.grat-chips') is None, '%s: one "Leave a gratuity" action, no fake amounts' % tag)
                    check(p.query_selector('.list [data-open="gratuity"]') is None, '%s: no quiet row after delivery' % tag)
                else:
                    row = p.query_selector('.list [data-open="gratuity"]')
                    check(row is not None and p.query_selector('.grat') is None, '%s: discreet gratuity row only' % tag)
                    if row: check(row.evaluate("e => getComputedStyle(e).backgroundColor") in ('rgba(0, 0, 0, 0)', 'transparent'), '%s: row has no highlight' % tag)
                check(p.evaluate(SELECTED) == 0, '%s: nothing pre-selected' % tag)
                check(p.query_selector('a[href="terms.html"]') is None and 'Valet Terms' not in p.inner_text('footer'), '%s: no Valet Terms → SMS terms link' % tag)
                small = p.evaluate(VISIBLE_TARGETS + "('#app')")
                check(not small, '%s: tap targets >= 44 px %s' % (tag, small))
                check(p.evaluate('document.documentElement.scrollWidth') <= 390, '%s: no sideways scroll' % tag)
                if name == 'ready_lockbox': check(p.query_selector('[data-open="lockbox"]') is not None, '%s: lockbox button kept' % tag)
                if name == 'pending_return_wash': check('Waiting for our team to confirm' in p.inner_text('.pass') and 'Scheduled' in p.inner_text('.list'), '%s: pending return + car wash kept' % tag)
                if name == 'flying_back': check('MA 212' in p.inner_text('.pass') and '5:40 PM' in p.inner_text('.pass'), '%s: Flight / Arrives kept' % tag)
                if name == 'parked': check(p.query_selector('#howBtn') is not None and p.query_selector('[data-open="return"]') is not None, '%s: How to get there + Change return kept' % tag)
                check('S1-0%d' % (sid - 960000) in p.inner_text('.pass-ticket'), '%s: small ticket line kept' % tag)
                if motion == 'no-preference':
                    p.screenshot(path='%s/%s_%s_%s.png' % (SHOTS, PREFIX, name, ENGINE), full_page=True)
                c.close()

        # Gratuity sheet during the trip: neutral copy, the current link, one tap = one count.
        c, st = ctx(); p = openp(c, 960001)
        for _ in range(3): vis(p)   # refreshes never add listeners
        p.click('.list [data-open="gratuity"]'); p.wait_for_selector('#sheet a[data-grat]'); p.wait_for_timeout(500)
        check(COPY in p.inner_text('#sheet'), 'sheet: neutral copy')
        hrefs = p.eval_on_selector_all('#sheet a[data-grat]', 'l => l.map(a => a.href)')
        check(hrefs == [GURL], 'sheet: one action → the current link, no reference while the flag is off (%s)' % hrefs)
        check(not p.evaluate(VISIBLE_TARGETS + "('#sheet')"), 'sheet: tap targets >= 44 px')
        p.screenshot(path='%s/%s_gratuity_sheet_%s.png' % (SHOTS, PREFIX, ENGINE))
        with c.expect_page() as np: p.click('#sheet a[data-grat]')
        np.value.wait_for_load_state(); p.wait_for_timeout(1200)
        check(sql("select gratuity_clicks from public.airvalet_pass_links where passenger_id = 960001 and revoked_at is null") == '1', 'metric: one tap → gratuity_clicks = 1')
        check(st['stripe'] == [GURL], 'metric: the payment link still opens (%s)' % st['stripe'])
        c.close()

        # Valet information sheet (facts only) + terms_published never revives the SMS-terms link.
        sql("update public.airvalet_portal_settings set terms_published = true;")
        c, st = ctx(); p = openp(c, 960001)
        check(p.query_selector('a[href="terms.html"]') is None and 'Valet Terms' not in p.inner_text('footer'), 'terms_published = true: still no Valet Terms link (legal panel hidden)')
        p.click('footer [data-open="info"]'); p.wait_for_selector('#sheet .info-row'); p.wait_for_timeout(500)  # sheet slide-in done
        t = p.inner_text('#sheet')
        check('Valet hours' in t and 'complimentary' in t and 'Call valet' in t and 'Farber Parking' in t, 'info sheet: hours, complimentary, contacts, operator')
        check(not any(w in t.lower() for w in ('liab', 'damage', 'responsib', 'waive', 'terms', 'customs', 'mechanic')), 'info sheet: no legal clauses, no Customs / mechanical promise')
        small = p.evaluate(VISIBLE_TARGETS + "('#sheet')")
        check(not small, 'info sheet: tap targets >= 44 px %s' % small)
        p.screenshot(path='%s/%s_info_sheet_%s.png' % (SHOTS, PREFIX, ENGINE))
        c.close()
        restore(); sql("update public.airvalet_portal_settings set chat_enabled = true;")

        if HAS_FLAGS:
            # Per-amount links (flag): $10 / $20 / $40 / Other, nothing selected; reference flag adds pax-<id>.
            sql("""update public.airvalet_portal_settings set gratuity_links = '{"10":"https://buy.stripe.com/test10aaaaaa","20":"https://buy.stripe.com/test20aaaaaa","40":"https://buy.stripe.com/test40aaaaaa"}';""")
            c, st = ctx(); p = openp(c, 960008)
            chips = p.eval_on_selector_all('.grat .chip', 'l => l.map(a => [a.textContent.trim(), a.href])')
            check([x[0] for x in chips] == ['$10', '$20', '$40', 'Other'], 'chips: $10 / $20 / $40 / Other (%s)' % [x[0] for x in chips])
            check(chips and chips[3][1] == GURL and len(set(x[1] for x in chips)) == 4, 'chips: one link each, Other = the current link')
            check(p.evaluate(SELECTED) == 0, 'chips: nothing pre-selected')
            check(not p.evaluate(VISIBLE_TARGETS + "('.grat')"), 'chips: tap targets >= 44 px')
            p.screenshot(path='%s/%s_delivered_chips_%s.png' % (SHOTS, PREFIX, ENGINE), full_page=True)
            c.close()
            c, st = ctx(); p = openp(c, 960001); p.click('.list [data-open="gratuity"]'); p.wait_for_selector('#sheet .chip')
            check(len(p.query_selector_all('#sheet .chip')) == 4, 'chips: also in the trip sheet (still behind the quiet row)')
            c.close()
            sql("update public.airvalet_portal_settings set gratuity_reference = true;")
            c, st = ctx(); p = openp(c, 960008)
            hrefs = p.eval_on_selector_all('.grat a[data-grat]', 'l => l.map(a => a.href)')
            check(hrefs and all(h.endswith('?client_reference_id=pax-960008') for h in hrefs), 'reference flag on: every link carries pax-960008')
            c.close()
            restore()
            c, st = ctx(); p = openp(c, 960008)
            hrefs = p.eval_on_selector_all('.grat a[data-grat]', 'l => l.map(a => a.href)')
            check(hrefs == [GURL], 'flags back off: single current link, no reference')
            c.close()
        b.close()
finally:
    restore(); sql(CLEAN)

print('\n%d ok, %d failed' % (ok_n, len(fails)))
sys.exit(1 if fails else 0)
