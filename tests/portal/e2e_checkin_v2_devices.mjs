// LOCAL ONLY. Device matrix for New Check-in v2 with Playwright WebKit (Safari
// engine) and Chromium: iPhone / iPad in portrait and landscape, desktop,
// touch input, slow network, connection loss and two devices at once.
// Runs against the local stack (http://127.0.0.1:8781 + local Supabase, mock
// SMS). Non-local hosts are blocked and epsonSend is stubbed: nothing can print.
//   PW_CORE=<path to playwright-core> node tests/portal/e2e_checkin_v2_devices.mjs <scratch portal dir>
import { createRequire } from 'node:module';
import { readFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
const require = createRequire(import.meta.url);
const pw = require(process.env.PW_CORE || 'playwright-core');
const DIR = process.argv[2];
const PW = readFileSync(DIR + '/test_password.txt', 'utf8').trim();
const APP = 'http://127.0.0.1:8781/?checkin=v2';
const RUN = String(Date.now() % 9000 + 1000).slice(-3);
let oks = 0, fails = 0;
const check = (c, m, x) => { if (c) { oks++; console.log('ok  ', m); } else { fails++; console.log('FAIL', m, x === undefined ? '' : JSON.stringify(x)); } };
const sql = (q) => execFileSync('docker', ['exec', '-i', 'supabase_db_airvalet-portal-local', 'psql', '-U', 'postgres', '-d', 'postgres', '-qAt', '-c', q]).toString().trim();
let seq = 10;
const phone = () => '30555' + RUN + String(seq++).padStart(2, '0');
const guard = async (route) => {
  const u = route.request().url();
  if (u.startsWith('http://127.0.0.1') || u.includes('fonts.g') || u.includes('cdnjs') || u.includes('jsdelivr')) return route.continue();
  return route.abort();
};

async function launch(engine) {
  if (engine === 'chromium' && process.env.CHROMIUM_PATH) return pw.chromium.launch({ executablePath: process.env.CHROMIUM_PATH });
  return pw[engine].launch();
}
async function login(page, user = 'localipad') {
  await page.goto(APP);
  await page.waitForSelector('#loginEmail', { state: 'visible', timeout: 20000 });
  for (let a = 0; a < 3; a++) {
    await page.waitForTimeout(2000);
    await page.fill('#loginEmail', user); await page.fill('#loginPwd', PW); await page.press('#loginPwd', 'Enter');
    try { await page.waitForFunction(() => typeof _currentUserEmail !== 'undefined' && !!_currentUserEmail && Array.isArray(data) && data.length > 0, null, { timeout: 15000 }); break; }
    catch (e) { if (a === 2) throw e; }
  }
  await page.evaluate(async () => {
    const key = smsDeviceKey(true);
    await smsApi('/rest/v1/rpc/airvalet_sms_device_request', { method: 'POST', body: JSON.stringify({ p_device_key: key, p_label: 'E2E iPad', p_user_agent: 'e2e' }) });
    await resolveSmsProvider();
    window.__prints = [];
    window.epsonSend = async (xml, label) => { window.__prints.push(label); return true; };
  });
}
async function tapOrClick(page, sel, touch) {
  try { if (touch) await page.tap(sel, { timeout: 10000 }); else await page.click(sel, { timeout: 10000 }); }
  catch (e) { throw new Error(`${touch ? 'tap' : 'click'} ${sel}: ${String(e.message).split('\n')[0]}`); }
}
async function createOne(page, name, ph, touch) {
  await page.evaluate(() => openAdd());
  await page.waitForSelector('#ci2Name', { state: 'visible' });
  await tapOrClick(page, '#ci2Name', touch); await page.keyboard.type(name);
  await tapOrClick(page, '#ci2Phone', touch); await page.keyboard.type(ph);
  await tapOrClick(page, '#ci2Yes', touch);
  await page.waitForSelector('#ci2Created:not([hidden])', { timeout: 20000 });
  return page.evaluate(() => ({ id: _ci.id, ticket: _ci.ticket }));
}

async function profileRun(engine, label, opts) {
  const browser = await launch(engine);
  const ctx = await browser.newContext(opts);
  await ctx.route('**/*', guard);
  const page = await ctx.newPage();
  const errors = []; page.on('pageerror', (e) => errors.push(String(e)));
  const touch = !!opts.hasTouch;
  const tag = `[${engine} ${label}]`;
  await login(page);
  check(await page.evaluate(() => ci2Active()), `${tag} v2 active after ?checkin=v2`);
  await page.evaluate(() => openAdd());
  try { await page.waitForSelector('#ci2Name', { state: 'visible', timeout: 8000 }); }
  catch (e) {
    const st = await page.evaluate(() => ({ addOn: document.getElementById('addOv').classList.contains('on'), ci2Hidden: document.getElementById('ci2').hidden,
      ci2Html: document.getElementById('ci2').innerHTML.length, legacyHidden: document.getElementById('ciLegacy').hidden, pax: document.getElementById('passengerFields').style.display,
      overlays: [...document.querySelectorAll('.ov.on')].map((o) => o.id) }));
    await page.screenshot({ path: `/tmp/ci2-${engine}-${label.replace(/\W+/g, '-')}.png` }).catch(() => {});
    throw new Error('new check-in did not open: ' + JSON.stringify(st) + ' errors=' + JSON.stringify(errors));
  }
  // Fields: keyboard type, iOS zoom (font-size >= 16px), labels.
  const f = await page.evaluate(() => {
    const px = (sel) => parseFloat(getComputedStyle(document.querySelector(sel)).fontSize);
    return { tel: document.getElementById('ci2Phone').type, mode: document.getElementById('ci2Phone').inputMode, name: px('#ci2Name'), phone: px('#ci2Phone'),
             nameLabel: !!document.querySelector('label[for="ci2Name"]'), phoneLabel: !!document.querySelector('label[for="ci2Phone"]') };
  });
  // Phone keypad (digits + '+') so international numbers can be typed (2026-10-26).
  check(f.tel === 'tel' && f.mode === 'tel', `${tag} phone uses the phone keypad (digits and +)`, f);
  check(f.name >= 16 && f.phone >= 16, `${tag} inputs ≥16px (no Safari zoom on focus)`, f);
  check(f.nameLabel && f.phoneLabel, `${tag} inputs have visible labels`);
  await tapOrClick(page, '.ci2-retpick[data-n="1"] [data-cal="1"]', touch);
  const vw = opts.viewport.width;
  check(await page.evaluate(() => document.documentElement.scrollWidth) <= vw, `${tag} no horizontal scroll with the calendar open`);
  // Touch targets inside the v2 sheet (visible buttons / inputs).
  const small = await page.evaluate(() => [...document.querySelectorAll('#ci2 button, #ci2 input, #ci2 summary, #ci2 select, #ci2 textarea')]
    .filter((e) => e.offsetParent && e.type !== 'hidden')
    .map((e) => { const r = e.getBoundingClientRect(); const box = e.type === 'checkbox' ? e.closest('label').getBoundingClientRect() : r; return { t: (e.innerText || e.id || e.className || e.type).slice(0, 24), h: Math.round(box.height), w: Math.round(box.width) }; })
    .filter((x) => x.h < 44 || x.w < 44));
  check(small.length === 0, `${tag} touch targets ≥44pt`, small);
  await tapOrClick(page, '.ci2-retpick[data-n="1"] [data-d]:nth-child(2)', touch);
  await tapOrClick(page, '#ci2Name', touch); await page.keyboard.type('DEV ' + label.toUpperCase());
  await tapOrClick(page, '#ci2Phone', touch); const ph = phone(); await page.keyboard.type(ph);
  await tapOrClick(page, '#ci2Yes', touch);
  const t0 = Date.now();
  await page.waitForSelector('#ci2Created:not([hidden])', { timeout: 20000 });
  const tookMs = Date.now() - t0;
  const r = await page.evaluate(() => ({ id: _ci.id, ticket: _ci.ticket }));
  check(!!r.id, `${tag} ticket created by touch flow (${tookMs} ms incl. 3 s undo)`, r);
  // The welcome is requested right after the card appears: wait for it, then make sure no second one follows.
  const nWelcome = () => sql(`select count(*) from airvalet_sms_messages where passenger_id = ${r.id} and message_type = 'CHECK_IN'`);
  for (let i = 0; i < 20 && nWelcome() === '0'; i++) await page.waitForTimeout(250);
  await page.waitForTimeout(1500);
  const nw = nWelcome();
  check(nw === '1', `${tag} one welcome`, nw);
  await tapOrClick(page, '.ci2-sec-h >> text=Hangar', touch); await tapOrClick(page, '#ci2Hangars button >> nth=0', touch);
  await tapOrClick(page, '#ci2Created [data-open="ci2SVeh"]', touch);
  await tapOrClick(page, '#ci2Makes button >> text=Toyota', touch); await tapOrClick(page, '#ci2Models button >> text=Sienna', touch); await tapOrClick(page, '#ci2Colors button >> text=Silver', touch);
  await page.waitForTimeout(700);
  check(sql(`select car || '|' || color || '|' || loc from passengers where id = ${r.id}`) === 'TOYOTA SIENNA|Silver|HANGAR 19', `${tag} details saved by touch`);
  await tapOrClick(page, '#ci2Print', touch); await page.waitForTimeout(900);
  check(JSON.stringify(await page.evaluate(() => window.__prints)) === '["Key","Dashboard"]', `${tag} Print Tags → Key + Dashboard`);
  await tapOrClick(page, '#ci2Print', touch);
  check(await page.isVisible('#ci2Reprint'), `${tag} Reprint menu opens`);
  const menuIn = await page.evaluate(() => { const r = document.getElementById('ci2Reprint').getBoundingClientRect(); return r.left >= 0 && r.right <= innerWidth + 1 && r.top >= 0; });
  check(menuIn, `${tag} Reprint menu fully on screen`);
  await tapOrClick(page, '#ci2Reprint [data-print="dash"]', touch); await page.waitForTimeout(500);
  check(JSON.stringify(await page.evaluate(() => window.__prints.slice(2))) === '["Dashboard"]', `${tag} Reprint → Dashboard tag only`);
  // Reload: the ticket and its details are on the server, not in the screen.
  await page.reload();
  await page.waitForFunction(() => typeof _currentUserEmail !== 'undefined' && !!_currentUserEmail && Array.isArray(data) && data.length > 0, null, { timeout: 20000 });
  const after = await page.evaluate((id) => { const x = data.find((d) => d.id === id); return x ? [x.car, x.color, x.loc, x.ticket].join('|') : ''; }, r.id);
  check(after === `TOYOTA SIENNA|Silver|HANGAR 19|${r.ticket}`, `${tag} after reload: ticket + vehicle + hangar persisted`, after);
  check(errors.length === 0, `${tag} no page errors`, errors);
  await browser.close();
}

// Device descriptor usable by both engines (Chromium ignores defaultBrowserType).
function dev(engine, name) { const o = { ...pw.devices[name] }; delete o.defaultBrowserType; return o; }
async function adversarial(engine) {
  const tag = `[${engine} adversarial]`;
  const browser = await launch(engine);
  const mk = async (opts) => { const c = await browser.newContext(opts); await c.route('**/*', guard); const p = await c.newPage(); return { c, p }; };
  // Slow network: every API call delayed 1.2 s, repeated taps on Yes.
  const slow = await mk(dev(engine, 'iPhone 15'));
  await login(slow.p);
  await slow.c.route('**/rest/v1/**', async (route) => { await new Promise((r) => setTimeout(r, 1200)); return route.continue(); });
  await slow.p.evaluate(() => openAdd()); await slow.p.waitForSelector('#ci2Name', { state: 'visible' });
  const sph = phone();
  await slow.p.fill('#ci2Name', `DEV SLOW NET ${engine.toUpperCase()}`); await slow.p.fill('#ci2Phone', sph);
  await slow.p.dispatchEvent('#ci2Phone', 'input');
  await slow.p.evaluate(() => { window.__savingSeen = false; const el = document.getElementById('ci2Saving');
    new MutationObserver(() => { if (!el.hidden) window.__savingSeen = true; }).observe(el, { attributes: true }); });
  await tapOrClick(slow.p, '#ci2Yes', true);
  await slow.p.waitForSelector('#ci2Created:not([hidden])', { timeout: 30000 }).catch(() => {});
  const seen = await slow.p.evaluate(() => window.__savingSeen);
  check(seen, `${tag} slow network: “Creating ticket…” shown while saving`);
  for (let i = 0; i < 4; i++) await slow.p.evaluate(() => { document.getElementById('ci2Yes').click(); ci2Create(true); });
  await slow.p.waitForSelector('#ci2Created:not([hidden])', { timeout: 30000 });
  for (let i = 0; i < 20 && sql(`select count(*) from airvalet_sms_messages m join passengers p on p.id = m.passenger_id where p.name = 'DEV SLOW NET ${engine.toUpperCase()}' and m.message_type = 'CHECK_IN'`) === '0'; i++) await slow.p.waitForTimeout(500);
  await slow.p.waitForTimeout(1500);
  check(sql(`select count(*) from passengers where name = 'DEV SLOW NET ${engine.toUpperCase()}' and phone like '%${sph.slice(-4)}'`) === '1', `${tag} slow network + repeated taps → one ticket`);
  check(sql(`select count(*) from airvalet_sms_messages m join passengers p on p.id = m.passenger_id where p.name = 'DEV SLOW NET ${engine.toUpperCase()}' and m.message_type = 'CHECK_IN'`) === '1', `${tag} … and one welcome`);
  await slow.c.close();

  // Connection lost during the countdown → not saved, form kept; back online → saved once.
  const off = await mk(dev(engine, 'iPad Pro 11'));
  await login(off.p);
  await off.p.evaluate(() => openAdd()); await off.p.waitForSelector('#ci2Name', { state: 'visible' });
  const oph = phone();
  await off.p.fill('#ci2Name', `DEV OFFLINE ${engine.toUpperCase()}`); await off.p.fill('#ci2Phone', oph); await off.p.dispatchEvent('#ci2Phone', 'input');
  await tapOrClick(off.p, '#ci2Yes', true);
  await off.p.waitForTimeout(800);
  await off.c.setOffline(true);
  await off.p.waitForTimeout(5000);
  const st = await off.p.evaluate(() => ({ created: _ci.created, offline: _ci.offline, name: document.getElementById('ci2Name').value, msg: document.getElementById('msg').innerText }));
  check(st.created ? st.offline : st.name === `DEV OFFLINE ${engine.toUpperCase()}`, `${tag} offline during countdown → not saved (or offline queue), typed entry kept`, st);
  check(sql(`select count(*) from passengers where name = 'DEV OFFLINE ${engine.toUpperCase()}'`) === '0', `${tag} … nothing written to the server while offline`);
  await off.c.setOffline(false);
  await off.p.waitForTimeout(1500);
  if (!st.created) {
    await tapOrClick(off.p, '#ci2Yes', true);
    await off.p.waitForSelector('#ci2Created:not([hidden])', { timeout: 20000 });
    check(sql(`select count(*) from passengers where name = 'DEV OFFLINE ${engine.toUpperCase()}'`) === '1', `${tag} back online → one tap saves it once`);
  }
  await off.c.close();

  // Two devices at the same time: different guests → different tickets; same ticket edited from both.
  const a = await mk(dev(engine, 'iPad Pro 11'));
  const b = await mk(dev(engine, 'iPhone 15'));
  await login(a.p); await login(b.p, 'localiphone');
  const [ra, rb] = await Promise.all([createOne(a.p, `DEV DEVICE A ${engine.toUpperCase()}`, phone(), true), createOne(b.p, `DEV DEVICE B ${engine.toUpperCase()}`, phone(), true)]);
  check(ra.ticket && rb.ticket && ra.ticket !== rb.ticket, `${tag} two devices at once → two different tickets`, [ra.ticket, rb.ticket]);
  await Promise.all([a.p.evaluate(() => closeAll()), b.p.evaluate(() => closeAll())]);
  await Promise.all([
    a.p.evaluate(async (id) => { await sbUpdate(id, { loc: 'HANGAR 18' }); }, ra.id),
    b.p.evaluate(async (id) => { await sbUpdate(id, { color: 'Blue', car: 'FORD BRONCO' }); }, ra.id)
  ]);
  check(sql(`select loc || '|' || color || '|' || car from passengers where id = ${ra.id}`) === 'HANGAR 18|Blue|FORD BRONCO', `${tag} same ticket edited on two devices → both changes kept (field-level saves)`);
  // Delivery without the ID check is refused even if a device skips the UI.
  sql(`update passengers set pickup_auth_name = 'DEV PICKUP' where id = ${rb.id}`);
  const res = await b.p.evaluate(async (id) => { try { await sbUpdate(id, { status: 'DELIVERED' }); return 'updated'; } catch (e) { return String(e.message); } }, rb.id);
  check(res.includes('AUTHORIZED_PICKUP_ID_REQUIRED'), `${tag} delivery of an authorized ticket without ID check → refused by the database`, res);
  await a.c.close(); await b.c.close();
  await browser.close();
}

const PROFILES = [
  ['iPhone portrait', { ...pw.devices['iPhone 15'] }],
  ['iPhone landscape', { ...pw.devices['iPhone 15 landscape'] }],
  ['iPad portrait', { ...pw.devices['iPad Pro 11'] }],
  ['iPad landscape', { ...pw.devices['iPad Pro 11 landscape'] }],
  ['Desktop 1440', { viewport: { width: 1440, height: 900 } }]
];
for (const engine of (process.env.ENGINES || 'webkit,chromium').split(',')) {
  for (const [label, opts] of PROFILES.filter(([l]) => !process.env.ONLY || l.includes(process.env.ONLY))) {
    const o = { ...opts }; delete o.defaultBrowserType;
    if (engine === 'webkit' && label.startsWith('Desktop')) { console.log('skip [webkit Desktop] headless WebKit without a mobile profile pauses animation frames (test-runner limit; Desktop covered by Chromium)'); continue; }
    try { await profileRun(engine, label, o); } catch (e) { fails++; console.log('FAIL', `[${engine} ${label}] crashed`, String(e && e.stack || e).slice(0, 700)); }
  }
  if (!process.env.ONLY || process.env.ONLY === 'adversarial') try { await adversarial(engine); } catch (e) { fails++; console.log('FAIL', `[${engine} adversarial] crashed`, String(e && e.stack || e).slice(0, 700)); }
}
// Leave the local stack as found.
sql(`do $$ declare r record; begin
  create temp table dev_ids on commit drop as select id from passengers where name like 'DEV %';
  for r in select conrelid::regclass t, a.attname c from pg_constraint k join pg_attribute a on a.attrelid = k.conrelid and a.attnum = any(k.conkey)
           where k.contype = 'f' and k.confrelid = 'public.passengers'::regclass loop
    execute format('delete from %s where %I in (select id from dev_ids)', r.t, r.c);
  end loop;
  delete from airvalet_sms_messages where passenger_id in (select id from dev_ids);
  delete from passengers where id in (select id from dev_ids);
end $$`);
sql("delete from airvalet_sms_enrollments where device_id in (select id from airvalet_sms_devices where label = 'E2E iPad')");
console.log(`\n${oks} passed, ${fails} failed`);
process.exit(fails ? 1 : 0);
