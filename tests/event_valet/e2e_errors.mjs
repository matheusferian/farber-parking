// LOCAL ONLY — error-scenario E2E for the Event Valet staff page in headless
// Chrome against tests/event_valet/devserver.ts (local DB, mock SMS, fake printer).
// Injects: lost responses, slow network, printer down (Wi-Fi drop), SMS endpoint
// down, internet down with the printer still reachable (offline mode), full
// offline, two phones at once, app reopened offline, expired session.
// node tests/event_valet/e2e_errors.mjs <password> <anonKey> <serviceKey>
import { spawn } from 'node:child_process';
const [PW, ANON, SERVICE] = process.argv.slice(2);
const SB = 'http://127.0.0.1:55331', PAGE = 'http://localhost:8789/events/makers-halloween-2026/', PRN = 'http://127.0.0.1:8791', PORT = 9366;
const chrome = spawn('/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', ['--headless=new', '--disable-gpu', `--remote-debugging-port=${PORT}`, `--user-data-dir=/tmp/ev-e2e-${Date.now()}`, 'about:blank'], { stdio: 'ignore' });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
for (let i = 0; i < 50; i++) { try { await fetch(`http://127.0.0.1:${PORT}/json/version`); break; } catch { await sleep(200); } }
const results = [];
const check = (name, ok, info = '') => { results.push({ name, ok: !!ok }); console.log((ok ? 'PASS ' : 'FAIL ') + name + (ok ? '' : '  → ' + JSON.stringify(info))); };
const rest = async (path, init = {}) => { const r = await fetch(`${SB}/rest/v1/${path}`, { ...init, headers: { apikey: SERVICE, Authorization: `Bearer ${SERVICE}`, 'Content-Type': 'application/json', ...(init.headers ?? {}) } }); const t = await r.text(); return t ? JSON.parse(t) : null; };
const tickets = () => rest('event_valet_tickets?event_id=eq.makers-halloween-2026&select=id,ticket_code,slot_no,vehicle,status,print_count,parking_location&order=ticket_no');
const byVeh = async (v) => (await tickets()).filter((t) => t.vehicle === v);
const msgs = (kind) => rest(`event_valet_messages?event_id=eq.makers-halloween-2026&direction=eq.OUT&kind=eq.${kind}&select=ticket_id,status`);
const printed = async () => Number(await (await fetch(`${PRN}/count`)).text());
const printerFail = async (on) => { const t = await (await fetch(`${PRN}/fail`)).text(); if ((t === 'fail=true') !== on) await fetch(`${PRN}/fail`); };
const waitFor = async (fn, ms = 15000) => { const end = Date.now() + ms; while (Date.now() < end) { try { if (await fn()) return true; } catch {} await sleep(500); } return false; };

// Each "phone" is its own browser context (own localStorage / service worker),
// exactly like two different devices.
const browserWs = new WebSocket((await (await fetch(`http://127.0.0.1:${PORT}/json/version`)).json()).webSocketDebuggerUrl);
await new Promise((r) => browserWs.addEventListener('open', r));
let bid = 0; const bpend = new Map();
browserWs.addEventListener('message', (e) => { const m = JSON.parse(e.data); if (m.id && bpend.has(m.id)) { bpend.get(m.id)(m); bpend.delete(m.id); } });
const bsend = (method, params = {}) => new Promise((r) => { const i = ++bid; bpend.set(i, r); browserWs.send(JSON.stringify({ id: i, method, params })); });
async function openTab() {
  const ctx = (await bsend('Target.createBrowserContext', {})).result.browserContextId;
  const targetId = (await bsend('Target.createTarget', { url: 'about:blank', browserContextId: ctx })).result.targetId;
  const ws = new WebSocket(`ws://127.0.0.1:${PORT}/devtools/page/${targetId}`); await new Promise((r) => ws.addEventListener('open', r));
  let id = 0; const pend = new Map(); const errs = []; let pausedHandler = null;
  ws.addEventListener('message', (e) => { const m = JSON.parse(e.data);
    if (m.id && pend.has(m.id)) { pend.get(m.id)(m); pend.delete(m.id); }
    if (m.method === 'Runtime.exceptionThrown') errs.push(m.params.exceptionDetails.exception?.description ?? m.params.exceptionDetails.text);
    if (m.method === 'Fetch.requestPaused' && pausedHandler) pausedHandler(m.params); });
  const send = (method, params = {}) => new Promise((r) => { const i = ++id; pend.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
  const ev = async (x) => { const r = await send('Runtime.evaluate', { expression: x, awaitPromise: true, returnByValue: true }); if (r.result?.exceptionDetails) throw new Error(JSON.stringify(r.result.exceptionDetails).slice(0, 300)); return r.result?.result?.value; };
  await send('Runtime.enable'); await send('Page.enable'); await send('Network.enable');
  await send('Emulation.setDeviceMetricsOverride', { width: 390, height: 844, deviceScaleFactor: 2, mobile: true });
  const tab = { ws, send, ev, errs, onPaused: (h) => { pausedHandler = h; } };
  tab.blockServer = async (on) => {
    if (!on) return send('Fetch.disable');
    tab.onPaused(async (p) => { await send('Fetch.failRequest', { requestId: p.requestId, errorReason: 'InternetDisconnected' }); });
    return send('Fetch.enable', { patterns: [{ urlPattern: '*127.0.0.1:55331*' }, { urlPattern: '*127.0.0.1:8790*' }] });
  };
  tab.net = (offline, latency = 0) => send('Network.emulateNetworkConditions', { offline, latency, downloadThroughput: latency ? 20000 : -1, uploadThroughput: latency ? 20000 : -1 });
  return tab;
}
const W = 'const w = (ms) => new Promise(r => setTimeout(r, ms));';
const fill = (p, make, model = '') => `(async () => {
  document.querySelector('.tab[data-tab=checkin]').click();
  if (document.getElementById('ciForm').classList.contains('hidden')) document.getElementById('dNext').click();
  const ph = document.getElementById('ciPhone'); ph.value = '${p}'; ph.dispatchEvent(new Event('input'));
  const mk = document.getElementById('ciMake'); mk.value = '${make}'; mk.dispatchEvent(new Event('input'));
  const md = document.getElementById('ciModel'); md.value = '${model}'; md.dispatchEvent(new Event('input')); })()`;
const checkin = async (tab, p, make, model = '', wait = 2500) => { await tab.ev(fill(p, make, model)); await tab.ev(`document.getElementById('ciBtn').click()`); await sleep(wait); };
const txt = (id) => `(document.getElementById('${id}') || {}).textContent`;
const board = (tab) => tab.ev(`(async () => { ${W} document.querySelector('.tab[data-tab=board]').click(); await w(300); })()`);
const cardSel = (id) => `document.querySelector('[data-id="${id}"]')`;
const tap = (tab, js) => tab.ev(`(async () => { ${W} ${js}; await w(250); })()`);
const more = (tab, id, action) => tap(tab, `${cardSel(id)}.querySelector('[data-more]').click(); await w(200); document.querySelector('#modalBody [data-m="${action}"]').click()`);
const confirmYes = (tab) => tap(tab, `document.getElementById('mYes').click()`);

// ── reset ──
await rest('event_valet_messages?event_id=eq.makers-halloween-2026', { method: 'DELETE' });
await rest('event_valet_audit?event_id=eq.makers-halloween-2026', { method: 'DELETE' });
await rest('event_valet_tickets?event_id=eq.makers-halloween-2026', { method: 'DELETE' });
await rest('event_valet_events?id=eq.makers-halloween-2026', { method: 'PATCH', body: JSON.stringify({ sms_enabled: true, sms_test_only: false, tip_enabled: true, tip_links: { sms: 'https://buy.stripe.com/test', other: 'https://buy.stripe.com/test' } }) });
await printerFail(false);

const PRINT_BASE = await printed();
async function loginPhone(tab) {
  await tab.send('Page.navigate', { url: 'http://localhost:8789/favicon-32x32.png' }); await sleep(400);
  await tab.ev(`localStorage.setItem('ev_local_cfg', JSON.stringify({url:'${SB}', key:'${ANON}', fn:'http://127.0.0.1:8790/event-valet', printer:'${PRN}/x'}))`);
  await tab.send('Page.navigate', { url: PAGE }); await sleep(1800);
  await tab.ev(`document.getElementById('lgUser').value='localipad'; document.getElementById('lgPwd').value='${PW}'; document.getElementById('lgBtn').click()`); await sleep(2500);
}
const A = await openTab();
const logsA = []; A.ws.addEventListener('message', (e) => { const m = JSON.parse(e.data); if (m.method === 'Runtime.consoleAPICalled') logsA.push(m.params.type + ' ' + m.params.args.map((a) => a.value ?? a.description).join(' ')); });
await loginPhone(A);
check('login works', (await A.ev(`document.getElementById('app').className`)) === '');

// ── 1 validation ──
await checkin(A, '954555', 'BMW', '', 300);
check('invalid phone blocked', /10-digit/.test(await A.ev(txt('ciErr'))));
await checkin(A, '9545550101', '', '', 300);
check('make required', /make/.test(await A.ev(txt('ciErr'))));
check('no ticket created by invalid input', (await tickets()).length === 0);

// ── 2 autocomplete ──
await A.ev(`(() => { const mk = document.getElementById('ciMake'); mk.value = 'te'; mk.dispatchEvent(new Event('input')); })()`);
check('typing "te" suggests TESLA', (await A.ev(`document.getElementById('sgMake').innerText`)).includes('TESLA'));
await A.ev(`[...document.querySelectorAll('#sgMake button')].find(b => b.textContent === 'TESLA').click()`);
check('model suggestions for TESLA', (await A.ev(`document.getElementById('sgModel').innerText`)).includes('MODEL Y'));
await A.ev(`[...document.querySelectorAll('#sgModel button')].find(b => b.textContent === 'MODEL Y').click()`);
check('make + model filled', (await A.ev(`vehicleText()`)) === 'TESLA MODEL Y');
await A.ev(`(() => { const mk = document.getElementById('ciMake'); mk.value = 'range'; mk.dispatchEvent(new Event('input')); document.querySelector('#sgMake button').click(); })()`);
check('alias "range" → LAND ROVER RANGE ROVER', (await A.ev(`vehicleText()`)) === 'LAND ROVER RANGE ROVER');
await A.ev(`(() => { const mk = document.getElementById('ciMake'); mk.value = 'Benz'; mk.dispatchEvent(new Event('input')); })()`);
check('alias "benz" → MERCEDES-BENZ', (await A.ev(`document.getElementById('sgMake').innerText`)).includes('MERCEDES-BENZ'));
await A.ev(`(() => { const mk = document.getElementById('ciMake'); mk.value = 'Pagani'; mk.dispatchEvent(new Event('input')); document.getElementById('ciModel').value = ''; })()`);
check('unknown make still allowed (free text)', (await A.ev(`vehicleText()`)) === 'PAGANI');

// ── 3 normal check-in ──
await checkin(A, '9545550101', 'HONDA', 'CIVIC');
let H = await byVeh('HONDA CIVIC');
check('check-in: 1 ticket #0101, slot 1', H.length === 1 && H[0].ticket_code === '0101' && H[0].slot_no === 1, H);
check('check-in SMS sent once', (await msgs('CHECKIN')).length === 1);
check('nothing printed before the location', (await printed()) === PRINT_BASE && /Select a location/.test(await A.ev(txt('dPrint'))));

// ── 4 lost response (server saved, phone never got the answer) ──
await A.send('Fetch.enable', { patterns: [{ urlPattern: '*rpc/event_valet_checkin*', requestStage: 'Response' }] });
let dropped = 0;
A.onPaused(async (p) => { if (dropped === 0) { dropped++; await A.send('Fetch.failRequest', { requestId: p.requestId, errorReason: 'ConnectionReset' }); } else await A.send('Fetch.continueRequest', { requestId: p.requestId }); });
await checkin(A, '9545550102', 'BMW', 'X5', 4000);
await A.send('Fetch.disable');
const X5 = await byVeh('BMW X5');
check('lost response: answer dropped once', dropped === 1);
check('lost response: exactly 1 ticket (no duplicate)', X5.length === 1 && X5[0].ticket_code === '0102', X5);
check('lost response: screen shows #0102', (await A.ev(txt('dTicket'))) === '#0102', await A.ev(txt('dTicket')));
check('lost response: SMS once', (await msgs('CHECKIN')).filter((m) => m.ticket_id === X5[0].id).length === 1);

// ── 5 slow signal ──
await A.net(false, 2500);
await checkin(A, '9545550103', 'LEXUS', 'RX', 9000);
await A.net(false, 0);
check('slow signal (2.5 s): ticket #0103 created', (await A.ev(txt('dTicket'))) === '#0103', await A.ev(txt('dTicket')));

// ── 6 Wi-Fi drop: printer unreachable → queue → prints by itself once ──
await printerFail(true);
await tap(A, `document.querySelector('#dLocs [data-loc="HANGAR 19"]').click()`); await sleep(2500);
check('printer down: "will print automatically"', /automatically/i.test(await A.ev(txt('dPrint'))), await A.ev(txt('dPrint')));
check('printer down: header shows 1 QUEUED', /1 QUEUED/.test(await A.ev(txt('bPrinter'))), await A.ev(txt('bPrinter')));
check('printer down: location saved', (await byVeh('LEXUS RX'))[0].parking_location === 'HANGAR 19');
const p0 = await printed();
await printerFail(false);
const auto = await waitFor(async () => (await printed()) - p0 === 1 && (await byVeh('LEXUS RX'))[0].print_count === 1, 15000);
check('printer back: queued ticket printed by itself, exactly once', auto && (await printed()) - p0 === 1, { p0, now: await printed() });
await sleep(9000);
check('…and never printed again', (await printed()) - p0 === 1);
check('printer back: header PRINTER ✓, queue empty', (await A.ev(txt('bPrinter'))) === 'PRINTER ✓', await A.ev(txt('bPrinter')));

// ── 7 SMS endpoint unreachable → RESEND later ──
await A.send('Fetch.enable', { patterns: [{ urlPattern: '*event-valet/send*' }] });
A.onPaused(async (p) => { await A.send('Fetch.failRequest', { requestId: p.requestId, errorReason: 'InternetDisconnected' }); });
await checkin(A, '9545550104', 'KIA', '', 6500);
check('SMS unreachable: ticket still created', (await A.ev(txt('dTicket'))) === '#0104');
check('SMS unreachable: says tap RESEND', /RESEND/.test(await A.ev(txt('dSms'))), await A.ev(txt('dSms')));
await A.send('Fetch.disable');
await tap(A, `document.getElementById('dResend').click()`); await sleep(2500);
const K = (await byVeh('KIA'))[0];
check('RESEND after recovery: sent once', (await msgs('CHECKIN')).filter((m) => m.ticket_id === K.id).length === 1);

// ── 8 two phones ──
const B = await openTab();
await loginPhone(B);
check('second phone logs in and opens', (await B.ev(`document.getElementById('app').className`)) === '');
await Promise.all([checkin(A, '3055550201', 'AUDI'), checkin(B, '3055550202', 'JEEP')]);
let T = await tickets();
const codes = T.map((t) => t.ticket_code), slots = T.filter((t) => t.status !== 'DELIVERED' && t.slot_no).map((t) => t.slot_no);
check('two phones at once: no duplicate codes', new Set(codes).size === codes.length, codes);
check('two phones at once: no duplicate key slots', new Set(slots).size === slots.length, slots);
await Promise.all([checkin(A, '9545550909', 'FORD'), checkin(B, '3055550909', 'RAM')]);
const c909 = (await tickets()).filter((t) => /0909$/.test(t.ticket_code)).map((t) => t.ticket_code).sort();
check('same last 4 at the same time → 0909 + 10909', JSON.stringify(c909) === '["0909","10909"]', c909);

// ── 9 board flow + sync between phones ──
await board(A); await board(B); await sleep(3500);
H = (await byVeh('HONDA CIVIC'))[0];
await tap(A, `${cardSel(H.id)}.querySelector('[data-loc="GRASS"]').click()`); await sleep(1500);
check('board: location from card prints the key ticket', (await byVeh('HONDA CIVIC'))[0].print_count === 1);
await sleep(3500);
await tap(A, `${cardSel(H.id)}.querySelector('[data-a=REQUESTED]').click()`); await sleep(1500);
check('board: REQUEST CAR → REQUESTED + guest SMS', (await byVeh('HONDA CIVIC'))[0].status === 'REQUESTED' && (await msgs('REQUESTED')).some((m) => m.ticket_id === H.id));
await sleep(3500);
await tap(A, `${cardSel(H.id)}.querySelector('[data-a=DELIVERED]').click()`); await confirmYes(A); await sleep(2000);
check('board: DELIVERED (with confirmation)', (await byVeh('HONDA CIVIC'))[0].status === 'DELIVERED');
await sleep(3500);
check('other phone sees it delivered within 3 s', await B.ev(`!!document.querySelector('.drow[data-id="${H.id}"]')`));
const again = await A.ev(`(async () => (await sb.rpc('event_valet_set_status', { p_ticket: '${H.id}', p_status: 'DELIVERED' })).data.changed)()`);
check('DELIVERED twice = no change', again === false);
check('thank-you SMS exactly once', (await msgs('TIP')).filter((m) => m.ticket_id === H.id).length === 1);
const F = (await byVeh('FORD'))[0];
await more(A, F.id, 'del'); await confirmYes(A); await sleep(1500);
check('DELETE (⋯ menu) removes the ticket', !(await byVeh('FORD')).length);
await sleep(3500);
check('…and it disappears on the other phone', !(await B.ev(`!!${cardSel(F.id)}`)));

// ── 10 OFFLINE MODE: internet down, printer still on Wi-Fi ──
await A.blockServer(true);
const before = (await tickets()).length;
await checkin(A, '9545557777', 'PORSCHE', 'CAYENNE', 6000);
check('offline: check-in still works (offline ticket #7777)', (await A.ev(txt('dTicket'))) === '#7777' && /OFFLINE/.test(await A.ev(txt('dRef'))), [await A.ev(txt('dTicket')), await A.ev(txt('dRef'))]);
check('offline: header shows OFFLINE · 1 TO SYNC', /OFFLINE · 1 TO SYNC/.test(await A.ev(txt('bNet'))), await A.ev(txt('bNet')));
check('offline: key slot taken from the top (20)', (await A.ev(txt('dSlot'))) === '20', await A.ev(txt('dSlot')));
const q0 = await printed();
await tap(A, `document.querySelector('#dLocs [data-loc="FENCE"]').click()`); await sleep(2500);
check('offline: key ticket prints right away (Wi-Fi printer)', (await printed()) - q0 === 1 && /Printed/.test(await A.ev(txt('dPrint'))), await A.ev(txt('dPrint')));
await checkin(A, '9545558888', 'MINI', '', 1200);
check('offline: next check-in is instant, slot 19', (await A.ev(txt('dTicket'))) === '#8888' && (await A.ev(txt('dSlot'))) === '19');
await board(A); await sleep(400);
check('offline: offline cars show on the board', (await A.ev(`document.querySelectorAll('.card.LOCAL').length`)) === 2);
check('offline: nothing reached the server yet', (await tickets()).length === before);
await checkin(B, '3055558888', 'TESLA');
check('meanwhile the online phone got #8888', (await B.ev(txt('dTicket'))) === '#8888');
await A.blockServer(false);
const synced = await waitFor(async () => (await A.ev(`outbox().length`)) === 0, 20000);
const P7 = (await byVeh('PORSCHE CAYENNE'))[0], M8 = (await byVeh('MINI'))[0];
check('internet back: offline tickets synced by themselves', synced && P7 && M8);
check('sync keeps the printed code / slot / location', P7 && P7.ticket_code === '7777' && P7.slot_no === 20 && P7.parking_location === 'FENCE' && P7.print_count === 1, P7);
check('conflict → new code 18888 + warning shown', M8 && M8.ticket_code === '18888' && /changed after sync/.test(await A.ev(`document.getElementById('modalBody').innerText`)), [M8, await A.ev(`document.getElementById('modalBody').innerText`)]);
check('guest SMS sent after sync, once each', (await msgs('CHECKIN')).filter((m) => m.ticket_id === P7.id || m.ticket_id === M8.id).length === 2);
check('header back to normal', await A.ev(`document.getElementById('bNet').classList.contains('hidden')`));
await tap(A, `(document.getElementById('mClose') || {click(){}}).click()`);

// ── 11 FULL offline (no internet AND no printer) → both wait, nothing lost ──
await A.net(true); await printerFail(true);
await sleep(7000);
await checkin(A, '9545556060', 'VOLVO', 'XC90', 3000);
await tap(A, `document.querySelector('#dLocs [data-loc="HANGAR 18"]').click()`); await sleep(2000);
check('full offline: ticket saved + print queued', (await A.ev(`outbox().length`)) === 1 && (await A.ev(`printq().length`)) === 1);
await A.net(false); await printerFail(false);
const both = await waitFor(async () => { const v = (await byVeh('VOLVO XC90'))[0]; return v && v.print_count === 1 && (await A.ev(`printq().length`)) === 0; }, 25000);
check('back: synced AND printed by itself (print_count 1)', both, (await byVeh('VOLVO XC90'))[0]);

// ── 12 mistaken offline ticket deleted before sync never reaches the server ──
await A.blockServer(true); await sleep(7000);
await checkin(A, '9545556666', 'WRONG', 'CAR', 1500);
await tap(A, `document.getElementById('dDelete').click()`);
check('offline ticket can be deleted before sync', (await A.ev(`outbox().length`)) === 0);
await A.blockServer(false); await sleep(6000);
check('deleted offline ticket never reaches the server', !(await byVeh('WRONG CAR')).length);

// ── 13 app reopened with no internet → opens from cache, still works offline ──
await A.send('Page.reload'); await sleep(3000);     // make sure the worker controls the page
await A.net(true);
await A.send('Page.reload'); await sleep(4000);
check('app opens with no internet (cached), logged in', await A.ev(`document.getElementById('app').className === '' && !!document.getElementById('ciBtn')`).catch(() => false));
await checkin(A, '9545555050', 'GMC', 'YUKON', 2500);
check('…and can check in offline', (await A.ev(txt('dTicket'))) === '#5050');
await A.net(false);
check('…which syncs when back', await waitFor(async () => (await byVeh('GMC YUKON')).length === 1, 20000));

// ── 14 signal oscillation banner (phone B) ──
await B.net(true); await sleep(8000);
const bannerOn = !(await B.ev(`document.getElementById('offline').classList.contains('hidden')`));
await B.net(false); await sleep(4500);
const bannerOff = await B.ev(`document.getElementById('offline').classList.contains('hidden')`);
check('signal lost → banner; back → banner gone', bannerOn && bannerOff, { bannerOn, bannerOff });

// ── 15 expired / missing session → login screen ──
await B.ev(`Object.keys(localStorage).filter(k => k.startsWith('sb-')).forEach(k => localStorage.removeItem(k))`);
await B.send('Page.reload'); await sleep(2500);
check('no session → login screen', !(await B.ev(`document.getElementById('viewLogin').classList.contains('hidden')`)));

// ── integrity ──
T = await tickets();
const active = T.filter((t) => t.status !== 'DELIVERED' && t.slot_no).map((t) => t.slot_no);
check('end state: no duplicate codes in the whole event', new Set(T.map((t) => t.ticket_code)).size === T.length, T.map((t) => t.ticket_code));
check('end state: no two active cars share a key slot', new Set(active).size === active.length, active);
check('no JavaScript errors on either phone', A.errs.length === 0 && B.errs.length === 0, [...A.errs, ...B.errs]);
const pass = results.filter((r) => r.ok).length;
console.log(`\n${pass}/${results.length} passed`);
A.ws.close(); B.ws.close(); browserWs.close(); chrome.kill();
process.exit(pass === results.length ? 0 : 1);
