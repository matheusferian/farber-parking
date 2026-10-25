# Passenger pass (pass.js) regressions from the 2026-10-25 full-system audit.
# LOCAL ONLY: app on http://127.0.0.1:8781 (serve_ci2.py), local Supabase + functions.
# Run: python3 tests/portal/e2e_pass_browser.py   (needs LDB = path to a psql-on-stdin helper)
import os, random, subprocess, sys, time
from playwright.sync_api import sync_playwright

LDB = os.environ.get('LDB') or sys.exit('set LDB to the local psql helper')
BASE = 'http://127.0.0.1:8781/a#'
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

FIX = """
insert into public.airvalet_sms_devices (key_hash, label, status, decided_at)
values (public.airvalet_sms_device_key_hash('e2ep_device_key_eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee'), 'E2EP iPad', 'approved', now())
on conflict do nothing;
insert into public.passengers (id, ts, checkin_date, name, phone, ticket, status, ret, loc, car, color, return_operator)
values (951201, 'x', now(), 'PASS NORMAL', '3055551201', 'E2EP-01', 'PENDING', to_char((now() at time zone 'America/New_York')::date + 3, 'FMMM/FMDD/YYYY'), null, 'BMW X5', 'Black', 'MAKERS'),
       (951202, 'x', now(), 'PASS CUSTOMS', '3055551202', 'E2EP-02', 'PENDING', to_char((now() at time zone 'America/New_York')::date, 'FMMM/FMDD/YYYY'), 'HANGAR 19', 'BMW X5', 'Black', 'MAKERS'),
       (951203, 'x', now(), 'PASS HANGAR', '3055551203', 'E2EP-03', 'PENDING', to_char((now() at time zone 'America/New_York')::date, 'FMMM/FMDD/YYYY'), 'HANGAR 19', 'BMW X5', 'Black', 'MAKERS'),
       (951204, 'x', now(), 'MAXIMILIANOBARTHOLOMEWVONHOHENZOLLERNSIGMARINGEN', '3055551204', 'E2EP-04', 'PENDING', to_char((now() at time zone 'America/New_York')::date + 3, 'FMMM/FMDD/YYYY'), null, 'MERCEDESBENZMAYBACHGLS600EXTRALONGNAME', 'Black', 'MAKERS'),
       (951205, 'x', now(), 'PASS REVOKE', '3055551205', 'E2EP-05', 'PENDING', to_char((now() at time zone 'America/New_York')::date + 3, 'FMMM/FMDD/YYYY'), null, 'BMW X5', 'Black', 'MAKERS');
insert into public.airvalet_sms_enrollments (passenger_id, phone_e164, device_id, consent_id)
select p.id, public.airvalet_sms_normalize_phone(p.phone), (select id from public.airvalet_sms_devices where label = 'E2EP iPad'), gen_random_uuid()
  from public.passengers p where p.id between 951201 and 951205;
insert into public.airvalet_pass_state (passenger_id, lockbox_authorized_at, lockbox_reveal_on, lockbox_code)
values (951202, now(), (now() at time zone 'America/New_York')::date, 'PRT-E2EP');
"""
CLEAN = """
delete from public.airvalet_sms_messages where passenger_id between 951201 and 951205;
delete from public.airvalet_pass_links where passenger_id between 951201 and 951205;
delete from public.airvalet_pass_state where passenger_id between 951201 and 951205;
delete from public.airvalet_sms_enrollments where passenger_id between 951201 and 951205;
delete from public.passengers where id between 951201 and 951205;
delete from public.airvalet_sms_devices where label = 'E2EP iPad';
"""

sql(CLEAN); sql(FIX)
TOK = {}
for i in range(1, 6):
    TOK[i] = sql("select public.airvalet_pass_mint(%d);" % (951200 + i)).splitlines()[-1]
sql("update public.airvalet_pass_links set expires_at = now() + interval '3 days' where passenger_id between 951201 and 951205 and revoked_at is null;")
sql("update public.passengers set status = 'DELIVERED', delivery_type = 'CUSTOMS', customs_gratuity_sent = false where id = 951202;")

try:
    with sync_playwright() as pw:
        b = pw.chromium.launch()
        def ctx(mode=None):
            c = b.new_context(viewport={'width': 390, 'height': 844}, reduced_motion='reduce')
            st = {'mode': mode, 'n': 0}; ip = rip()
            def fix(route):
                st['n'] += 1; m = st['mode']
                if m == '500': return route.fulfill(status=500, body='oops')
                if m == 'abort': return route.abort('internetdisconnected')
                if m == '429': return route.fulfill(status=429, body='{"state":"limited"}', headers={'content-type': 'application/json', 'access-control-allow-origin': '*'})
                h = dict(route.request.headers); h['x-forwarded-for'] = ip; route.continue_(headers=h)
            c.route(API, fix)
            return c, st
        def vis(p): p.evaluate("document.dispatchEvent(new Event('visibilitychange'))"); p.wait_for_timeout(2500)

        # F-7: a failed refresh keeps the pass on screen
        for m in ['abort', '500', '429']:
            c, st = ctx(); p = c.new_page(); p.goto(BASE + TOK[1]); p.wait_for_selector('.pass')
            st['mode'] = m; vis(p)
            check(p.query_selector('.pass') is not None and p.query_selector('#stale') is not None, 'F-7 refresh %s: pass stays, quiet note shown' % m)
            st['mode'] = None; vis(p)
            check(p.query_selector('.pass') is not None and p.query_selector('#stale') is None, 'F-7 refresh %s: next success clears the note' % m)
            c.close()
        # cold failure still offers Try again
        c, st = ctx(mode='429'); p = c.new_page(); p.goto(BASE + TOK[1]); p.wait_for_selector('.center h2')
        check(p.query_selector('#retry') is not None, 'cold 429: Try again button')
        c.close()

        # F-3: link revoked while open → inactive screen, no more API calls
        c, st = ctx(); p = c.new_page(); p.goto(BASE + TOK[5]); p.wait_for_selector('.pass')
        sql("update public.airvalet_pass_links set revoked_at = now(), revoke_reason = 'rotated' where passenger_id = 951205 and revoked_at is null;")
        vis(p); n0 = st['n']
        for _ in range(5): vis(p)
        check('not active' in p.inner_text('#app'), 'F-3 revoked while open: shows "not active"')
        check(st['n'] == n0, 'F-3 revoked while open: refresh stops calling the API (%d extra calls)' % (st['n'] - n0))
        c.close()

        # F-1 / F-5: Customs delivery → pickup Customs, no lockbox
        c, st = ctx(); p = c.new_page(); p.goto(BASE + TOK[2]); p.wait_for_selector('.pass')
        t = p.inner_text('#app')
        check('At Customs' in t, 'F-5 Customs delivery: At Customs')
        pick = p.evaluate("(function(){var k=[].find.call(document.querySelectorAll('.pass .k'),function(e){return e.textContent.trim()==='Pickup'});return k&&k.nextElementSibling?k.nextElementSibling.textContent.trim():''})()")
        check(pick == 'Customs', 'F-5 Customs delivery: pickup field says Customs (%r)' % pick)
        check(p.query_selector('[data-open="lockbox"]') is None and 'PRT-E2EP' not in p.content(), 'F-1 Customs delivery: no lockbox button or code')
        c.close()

        # F-4: Ready by location (Hangar 19, return today) without staff Ready
        c, st = ctx(); p = c.new_page(); p.goto(BASE + TOK[3]); p.wait_for_selector('.pass')
        t = p.inner_text('#app')
        check('A/C running' not in t and 'for your return today' in t, 'F-4 Ready by location: no "A/C running" promise')
        sql("insert into public.airvalet_pass_state (passenger_id, ready_at) values (951203, now()) on conflict (passenger_id) do update set ready_at = now();")
        vis(p)
        check('A/C running' in p.inner_text('#app'), 'F-4 staff Ready: "A/C running" shown')
        c.close()

        # F-11 long name/vehicle; F-8 call link height
        c, st = ctx(); p = c.new_page(); p.goto(BASE + TOK[4]); p.wait_for_selector('.pass')
        sw = p.evaluate('document.documentElement.scrollWidth')
        check(sw <= 390, 'F-11 long name/vehicle: no horizontal scroll (scrollWidth %d)' % sw)
        h = p.evaluate("Math.round(document.querySelector('.contact-line a').getBoundingClientRect().height)")
        check(h >= 44, 'F-8 call link is a 44 pt target (%d)' % h)
        # F-13: another link in the same tab never shows the previous chat
        p.evaluate("location.hash = '%s'" % TOK[1]); p.wait_for_selector('.pass'); p.wait_for_timeout(500)
        check('PASS NORMAL'.split()[0].title() in p.inner_text('#app') or 'Pass' in p.inner_text('#app'), 'F-13 hash change loads the other pass')
        c.close()
        b.close()
finally:
    sql(CLEAN)

print('\n%d ok, %d failed' % (ok_n, len(fails)))
sys.exit(1 if fails else 0)
