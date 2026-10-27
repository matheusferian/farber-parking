# Valet Pass, Concept C port (2026-10-27): every pass state × reduced motion
# on/off, self-hosted fonts (no request to Google Fonts), the hero flight plays
# once (the 30 s refresh / visibilitychange / a state change never replay it),
# static fallback without CSS offset-path, progress line, hash change, 44 px.
# The functional checks of every state live in e2e_pass_stage1_browser.py and
# the older suites; run them against this branch too.
# LOCAL ONLY: app served by serve_root.py, local Supabase + functions (mock SMS).
# Run: LDB=<psql helper> PASS_BASE=http://127.0.0.1:8797/a# PASS_ENGINE=chromium|webkit SHOT_DIR=<dir> \
#      python3 tests/portal/e2e_pass_concept_c_browser.py
import os, random, re, subprocess, sys, time
from playwright.sync_api import sync_playwright

LDB = os.environ.get('LDB') or sys.exit('set LDB to the local psql helper')
BASE = os.environ.get('PASS_BASE', 'http://127.0.0.1:8797/a#')
ENGINE = os.environ.get('PASS_ENGINE', 'chromium')
SHOTS = os.environ.get('SHOT_DIR', '/tmp')
SLOW = os.environ.get('CC_SLOW', '1') == '1'   # include the real 30 s refresh wait
API = '**/functions/v1/valet-pass'
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

# id, name, status word, progress step (aria-current)
STATES = [
    (960401, 'parked', 'Parked', 'Parked'), (960402, 'flying_back', 'Flying back', 'Parked'), (960403, 'pending_return_wash', 'Parked', 'Parked'),
    (960404, 'ready', 'Ready', 'Ready'), (960405, 'ready_lockbox', 'Ready', 'Ready'), (960406, 'customs_ascend', 'At Customs', 'Ready'),
    (960407, 'customs_waiting', 'At Customs', 'Ready'), (960408, 'delivered', 'Delivered', 'Delivered'),
]
FIX = """
insert into public.airvalet_sms_devices (key_hash, label, status, decided_at)
values (public.airvalet_sms_device_key_hash('e2ecc_device_key_cccccccccccccccccccccccccccccccccccccccccc'), 'E2ECC iPad', 'approved', now())
on conflict do nothing;
insert into public.passengers (id, ts, checkin_date, name, phone, ticket, status, ret, loc, car, color, return_operator, return_flight, departure_time, carwash_status) values
 (960401, 'x', now(), 'OLIVIA PARKER', '3055556401', 'CC-01', 'PENDING', %(d5)s, 'HANGAR 16', 'MERCEDES GLE', 'Black', 'MAKERS', null, null, null),
 (960402, 'x', now(), 'LIAM FLYER',    '3055556402', 'CC-02', 'PENDING', %(d1)s, 'HANGAR 16', 'AUDI Q7', 'White', 'MAKERS', 'MA 212', '17:40', null),
 (960403, 'x', now(), 'EMMA CHANGE',   '3055556403', 'CC-03', 'PENDING', %(d4)s, 'HANGAR 16', 'RANGE ROVER', 'Gray', 'MAKERS', null, null, 'CARWASH'),
 (960404, 'x', now(), 'NOAH READY',    '3055556404', 'CC-04', 'PENDING', %(d0)s, 'HANGAR 19', 'TESLA MODEL Y', 'Blue', 'MAKERS', null, null, null),
 (960405, 'x', now(), 'AVA LOCKBOX',   '3055556405', 'CC-05', 'PENDING', %(d0)s, 'HANGAR 16', 'BMW X5', 'Black', 'MAKERS', null, null, null),
 (960406, 'x', now(), 'LUCAS ASCEND',  '3055556406', 'CC-06', 'PENDING', %(d0)s, 'HANGAR 16', 'CADILLAC ESCALADE', 'Black', 'ASCEND', null, null, null),
 (960407, 'x', now(), 'MIA CUSTOMS',   '3055556407', 'CC-07', 'PENDING', %(d0)s, 'HANGAR 16', 'PORSCHE CAYENNE', 'Red', 'MAKERS', null, null, null),
 (960408, 'x', now(), 'ETHAN DONE',    '3055556408', 'CC-08', 'PENDING', %(d0)s, 'HANGAR 16', 'LEXUS LX', 'Silver', 'MAKERS', null, null, null),
 (960409, 'x', now(), 'ZOE CHANGES',   '3055556409', 'CC-09', 'PENDING', %(d3)s, 'HANGAR 16', 'VOLVO XC90', 'Blue', 'MAKERS', null, null, null);
insert into public.airvalet_sms_enrollments (passenger_id, phone_e164, device_id, consent_id)
select p.id, public.airvalet_sms_normalize_phone(p.phone), (select id from public.airvalet_sms_devices where label = 'E2ECC iPad'), gen_random_uuid()
  from public.passengers p where p.id between 960401 and 960409;
insert into public.airvalet_pass_state (passenger_id, ready_at) values (960404, now());
insert into public.airvalet_pass_state (passenger_id, ready_at, lockbox_authorized_at, lockbox_reveal_on, lockbox_code)
  values (960405, now(), now(), (now() at time zone 'America/New_York')::date, 'CC-LBX');
insert into public.airvalet_pass_state (passenger_id, customs_confirmed_at, ready_at) values (960406, now(), now());
insert into public.airvalet_pass_requests (passenger_id, kind, reason, requested_date, requested_time, client_key)
  values (960403, 'RETURN_CHANGE', 'FLIGHT_CHANGED', (now() at time zone 'America/New_York')::date + 6, '18:30', 'ck_cc_pending_return_0001');
update public.passengers set status = 'DELIVERED', delivery_type = 'CUSTOMS', customs_gratuity_sent = false where id = 960407;
update public.passengers set status = 'DELIVERED', delivery_type = 'NORMAL' where id = 960408;
""" % {'d0': d(0), 'd1': d(1), 'd3': d(3), 'd4': d(4), 'd5': d(5)}
CLEAN = """
delete from public.airvalet_pass_requests where passenger_id between 960401 and 960409;
delete from public.airvalet_sms_messages where passenger_id between 960401 and 960409;
delete from public.airvalet_pass_links where passenger_id between 960401 and 960409;
delete from public.airvalet_pass_state where passenger_id between 960401 and 960409;
delete from public.airvalet_sms_enrollments where passenger_id between 960401 and 960409;
delete from public.activity_log where passenger_id between 960401 and 960409;
delete from public.passengers where id between 960401 and 960409;
delete from public.airvalet_sms_devices where label = 'E2ECC iPad';
"""
SAVED_CHAT = sql("select chat_enabled from public.airvalet_portal_settings")
sql(CLEAN); sql(FIX)
TOK = {sid: sql("select public.airvalet_pass_mint(%d);" % sid).splitlines()[-1] for sid in range(960401, 960410)}
sql("update public.airvalet_portal_settings set chat_enabled = true;")

TARGETS = """(function(){ var out=[]; [].forEach.call(document.querySelectorAll('#app a, #app button'), function(e){
  var r=e.getBoundingClientRect(); if(!r.width||!r.height) return;
  if(r.height<44||r.width<44) out.push((e.textContent||'').trim().slice(0,24)+' '+Math.round(r.width)+'x'+Math.round(r.height)); }); return out; })()"""
PLANE = """(function(){ var p=document.querySelector('.hero .plane'), cs=getComputedStyle(p);
  var an=(p.getAnimations?p.getAnimations():[]).filter(function(a){return a.animationName==='fly'||a.animationName==='depart'});
  return {n:document.querySelectorAll('.hero').length, anims:an.map(function(a){return a.animationName+':'+a.playState}),
          opacity:cs.opacity, dist:cs.offsetDistance||'', done:document.getElementById('hero').classList.contains('done')}; })()"""

try:
    with sync_playwright() as pw:
        b = getattr(pw, ENGINE).launch(**({'executable_path': os.environ['WEBKIT_PATH']} if ENGINE == 'webkit' and os.environ.get('WEBKIT_PATH') else {}))
        def ctx(motion='no-preference', css_patch=None):
            c = b.new_context(viewport={'width': 390, 'height': 844}, device_scale_factor=2, reduced_motion=motion)
            st = {'google': [], 'fonts': [], 'views': 0}; ip = rip()
            def fix(route):
                if route.request.method == 'POST' and '"action"' not in (route.request.post_data or ''): st['views'] += 1
                h = dict(route.request.headers); h['x-forwarded-for'] = ip; route.continue_(headers=h)
            c.route(API, fix)
            def g(route): st['google'].append(route.request.url); route.abort()
            c.route(re.compile(r'https://fonts\.(googleapis|gstatic)\.com/.*'), g)
            c.on('request', lambda r: st['fonts'].append(r.url) if '/assets/fonts/' in r.url else None)
            if css_patch:
                def css(route):
                    resp = route.fetch(); route.fulfill(response=resp, body=css_patch(resp.text()))
                c.route('**/pass.css', css)
            return c, st
        def openp(c, sid):
            p = c.new_page(); p.goto(BASE + TOK[sid]); p.wait_for_selector('.pass'); return p
        def vis(p): p.evaluate("document.dispatchEvent(new Event('visibilitychange'))"); p.wait_for_timeout(1500)

        for motion in ('no-preference', 'reduce'):
            for sid, name, word, step in STATES:
                c, st = ctx(motion); p = openp(c, sid); tag = '%s [%s]' % (name, motion)
                p.evaluate('document.fonts.ready'); p.wait_for_timeout(300)
                pl = p.evaluate(PLANE)
                check(pl['n'] == 1, '%s: one hero' % tag)
                if motion == 'no-preference':
                    want = 'depart' if name == 'delivered' else 'fly'
                    check(any(a.startswith(want + ':') for a in pl['anims']), '%s: %s animation (%s)' % (tag, want, pl['anims']))
                else:
                    check(not pl['anims'], '%s: no aircraft animation (%s)' % (tag, pl['anims']))
                    if name == 'delivered': check(pl['opacity'] == '0', '%s: aircraft gone after delivery, static' % tag)
                    else: check(pl['opacity'] == '1' and pl['dist'] in ('62%', ''), '%s: aircraft static on the line (%s)' % (tag, pl['dist']))
                check(p.inner_text('.pass-status').strip() == word, '%s: status "%s"' % (tag, word))
                cur = p.evaluate("(document.querySelector('.tl [aria-current=step]')||{}).textContent||''")
                check(cur.strip() == step, '%s: progress at "%s" (%s)' % (tag, step, cur))
                h1 = p.inner_text('#hello')
                check(h1.startswith('Thank you' if name == 'delivered' else 'Welcome') and h1.endswith('.'), '%s: hero greeting (%s)' % (tag, h1))
                check(p.evaluate("document.fonts.check('700 16px Sora') && document.fonts.check('400 16px Inter')"), '%s: Sora + Inter loaded' % tag)
                check(not st['google'] and any('sora-latin' in u for u in st['fonts']), '%s: fonts self-hosted, no Google Fonts request (%s)' % (tag, st['google']))
                small = p.evaluate(TARGETS)
                check(not small, '%s: tap targets >= 44 px %s' % (tag, small))
                check(p.evaluate('document.documentElement.scrollWidth') <= 390, '%s: no sideways scroll' % tag)
                check('ready and waiting' not in p.inner_text('body') and 'good hands' not in p.inner_text('body'), '%s: no promise copy' % tag)
                check(p.query_selector('a[href="terms.html"]') is None and p.query_selector('.foot-logo') is not None, '%s: blue footer logo, no Valet Terms → SMS terms' % tag)
                if motion == 'no-preference':
                    p.wait_for_timeout(6600)   # the flight has landed on the line
                    p.screenshot(path='%s/concept_c_%s_%s.png' % (SHOTS, name, ENGINE), full_page=True)
                elif name in ('parked', 'delivered'):
                    p.screenshot(path='%s/concept_c_%s_reduced_motion_%s.png' % (SHOTS, name, ENGINE), full_page=True)
                c.close()

        # The flight plays once: refreshes (visibilitychange and the real 30 s timer) never replay it.
        c, st = ctx(); p = openp(c, 960401)
        p.evaluate("window.__starts=0; document.getElementById('hero').addEventListener('animationstart', function(e){ if(e.animationName==='fly'||e.animationName==='depart') window.__starts++; }); document.querySelector('.hero .plane').__same = 1;")
        p.wait_for_timeout(800)
        st0 = p.evaluate("(document.querySelector('.hero .plane').getAnimations().filter(a=>a.animationName==='fly')[0]||{}).startTime")
        for _ in range(3): vis(p)
        if SLOW:
            v0 = st['views']; p.wait_for_timeout(31500)
            check(st['views'] > v0, '30 s refresh ran (%d views)' % (st['views'] - v0))
        st1 = p.evaluate("(document.querySelector('.hero .plane').getAnimations().filter(a=>a.animationName==='fly')[0]||{}).startTime")
        check(p.evaluate("document.querySelector('.hero .plane').__same === 1"), 'refresh: the hero is never re-created')
        check(p.evaluate('window.__starts') <= 1 and st0 == st1, 'refresh: the flight is not replayed (starts after listener: %s, startTime %s → %s)' % (p.evaluate('window.__starts'), st0, st1))
        # A real state change (delivered) departs once; later refreshes keep it.
        sql("update public.passengers set status = 'DELIVERED', delivery_type = 'NORMAL' where id = 960401;")
        sql("update public.airvalet_pass_links set expires_at = now() + interval '3 hours' where passenger_id = 960401 and revoked_at is null;")
        vis(p); p.wait_for_timeout(500)
        n_dep = p.evaluate('window.__starts')
        for _ in range(2): vis(p)
        check(p.evaluate(PLANE)['done'] and p.evaluate('window.__starts') == n_dep, 'state change → departs once, refreshes keep it (%s starts)' % n_dep)
        check(p.inner_text('#hello').startswith('Thank you'), 'state change: hero text updated in place')
        c.close()

        # Hash change: never keeps the previous guest's name; hero not re-created.
        c, st = ctx(); p = openp(c, 960404)
        p.evaluate("document.querySelector('.hero .plane').__same = 1")
        p.evaluate("location.hash = '%s'" % TOK[960409])
        for _ in range(40):   # (the page CSP forbids wait_for_function's eval)
            if 'Zoe' in p.inner_text('#hello'): break
            p.wait_for_timeout(250)
        check('Noah' not in p.inner_text('body') and p.evaluate("document.querySelector('.hero .plane').__same === 1"), 'hash change: other guest shown, hero kept, no previous name')
        c.close()

        # Without CSS motion path (older iOS): static aircraft, nothing moves (simulated by forcing the fallback block).
        patch = lambda t: t.replace('@supports not (offset-path: path("M 0 0"))', '@supports (display: block)')
        c, st = ctx(css_patch=patch); p = openp(c, 960404); p.wait_for_timeout(500)
        pl = p.evaluate(PLANE)
        box = p.evaluate("(function(){var a=document.querySelector('.hero .plane').getBoundingClientRect(), h=document.getElementById('hero').getBoundingClientRect(); return [a.left>=h.left, a.right<=h.right, a.top>=h.top, a.bottom<=h.bottom, Math.round(a.left)]})()")
        check(not pl['anims'] and pl['opacity'] == '1' and all(box[:4]), 'no offset-path: static aircraft inside the hero (%s %s)' % (pl, box))
        p.screenshot(path='%s/concept_c_no_offset_path_fallback_%s.png' % (SHOTS, ENGINE))
        c.close()
        b.close()
finally:
    sql("update public.airvalet_portal_settings set chat_enabled = %s;" % ('true' if SAVED_CHAT == 't' else 'false')); sql(CLEAN)

print('\n%d ok, %d failed' % (ok_n, len(fails)))
sys.exit(1 if fails else 0)
