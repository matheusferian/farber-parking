// LOCAL ONLY — error-scenario E2E for the Event Valet staff page in headless
// Chrome against tests/event_valet/devserver.ts (local DB, mock SMS, fake printer).
// Injects: offline, lost responses, slow network, printer down, SMS endpoint down,
// two phones at once, expired session.
// node tests/event_valet/e2e_errors.mjs <password> <anonKey> <serviceKey>
import { spawn } from 'node:child_process';
const [PW, ANON, SERVICE] = process.argv.slice(2);
const SB = 'http://127.0.0.1:55331', PAGE = 'http://localhost:8789/events/makers-halloween-2026', PORT = 9366;
const chrome = spawn('/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', ['--headless=new', '--disable-gpu', `--remote-debugging-port=${PORT}`, `--user-data-dir=/tmp/ev-e2e-${Date.now()}`, 'about:blank'], { stdio: 'ignore' });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
for (let i = 0; i < 50; i++) { try { await fetch(`http://127.0.0.1:${PORT}/json/version`); break; } catch { await sleep(200); } }
const results = [];
const check = (name, ok, info = '') => { results.push({ name, ok: !!ok, info }); console.log((ok ? 'PASS ' : 'FAIL ') + name + (ok ? '' : '  → ' + JSON.stringify(info))); };
const rest = async (path, init = {}) => { const r = await fetch(`${SB}/rest/v1/${path}`, { ...init, headers: { apikey: SERVICE, Authorization: `Bearer ${SERVICE}`, 'Content-Type': 'application/json', ...(init.headers ?? {}) } }); const t = await r.text(); return t ? JSON.parse(t) : null; };
const tickets = () => rest('event_valet_tickets?event_id=eq.makers-halloween-2026&select=id,ticket_code,slot_no,vehicle,status,print_count&order=ticket_no');
const msgs = (kind) => rest(`event_valet_messages?event_id=eq.makers-halloween-2026&direction=eq.OUT&kind=eq.${kind}&select=ticket_id,status`);

async function openTab() {
  const t = await (await fetch(`http://127.0.0.1:${PORT}/json/new?about:blank`, { method: 'PUT' })).json();
  const ws = new WebSocket(t.webSocketDebuggerUrl); await new Promise((r) => ws.addEventListener('open', r));
  let id = 0; const pend = new Map(); const errs = []; let pausedHandler = null;
  ws.addEventListener('message', (e) => { const m = JSON.parse(e.data);
    if (m.id && pend.has(m.id)) { pend.get(m.id)(m); pend.delete(m.id); }
    if (m.method === 'Runtime.exceptionThrown') errs.push(m.params.exceptionDetails.exception?.description ?? m.params.exceptionDetails.text);
    if (m.method === 'Fetch.requestPaused' && pausedHandler) pausedHandler(m.params); });
  const send = (method, params = {}) => new Promise((r) => { const i = ++id; pend.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
  const ev = async (x) => { const r = await send('Runtime.evaluate', { expression: x, awaitPromise: true, returnByValue: true }); if (r.result?.exceptionDetails) throw new Error(JSON.stringify(r.result.exceptionDetails).slice(0, 300)); return r.result?.result?.value; };
  await send('Runtime.enable'); await send('Page.enable'); await send('Network.enable');
  await send('Emulation.setDeviceMetricsOverride', { width: 390, height: 844, deviceScaleFactor: 2, mobile: true });
  return { ws, send, ev, errs, onPaused: (h) => { pausedHandler = h; } };
}
const W = 'const w = (ms) => new Promise(r => setTimeout(r, ms));';
const fill = (p, make, model = '') => `(async () => { ${W}
  if (!document.getElementById('ciForm').classList.contains('hidden')) {} else document.getElementById('dNext').click();
  const ph = document.getElementById('ciPhone'); ph.value = '${p}'; ph.dispatchEvent(new Event('input'));
  const mk = document.getElementById('ciMake'); mk.value = '${make}'; mk.dispatchEvent(new Event('input'));
  const md = document.getElementById('ciModel'); md.value = '${model}'; md.dispatchEvent(new Event('input')); })()`;
const click = (id) => `document.getElementById('${id}').click()`;
const txt = (id) => `document.getElementById('${id}').textContent`;

// reset
await rest('event_valet_messages?event_id=eq.makers-halloween-2026', { method: 'DELETE' });
await rest('event_valet_audit?event_id=eq.makers-halloween-2026', { method: 'DELETE' });
await rest('event_valet_tickets?event_id=eq.makers-halloween-2026', { method: 'DELETE' });
await rest('event_valet_events?id=eq.makers-halloween-2026', { method: 'PATCH', body: JSON.stringify({ sms_enabled: true, sms_test_only: false, tip_enabled: true, tip_links: { sms: 'https://buy.stripe.com/test', other: 'https://buy.stripe.com/test' } }) });
await fetch('http://127.0.0.1:8791/fail').then((r) => r.text()).then(async (t) => { if (t === 'fail=true') await fetch('http://127.0.0.1:8791/fail'); });

const A = await openTab();
await A.send('Page.navigate', { url: 'http://localhost:8789/favicon-32x32.png' }); await sleep(400);
await A.ev(`localStorage.setItem('ev_local_cfg', JSON.stringify({url:'${SB}', key:'${ANON}', fn:'http://127.0.0.1:8790/event-valet', printer:'http://127.0.0.1:8791/x'}))`);
await A.send('Page.navigate', { url: PAGE }); await sleep(1800);
await A.ev(`document.getElementById('lgUser').value='localipad'; document.getElementById('lgPwd').value='${PW}'; ${click('lgBtn')}`); await sleep(2500);
check('login works', (await A.ev(`document.getElementById('app').className`)) === '');

// 1 validation
await A.ev(fill('954555', 'BMW')); await A.ev(click('ciBtn')); await sleep(300);
check('invalid phone blocked', /10-digit/.test(await A.ev(txt('ciErr'))));
await A.ev(fill('9545550101', '')); await A.ev(click('ciBtn')); await sleep(300);
check('make required', /make/.test(await A.ev(txt('ciErr'))));
check('no ticket created by invalid input', (await tickets()).length === 0);

// 2 autocomplete
await A.ev(`(async () => { ${W} const mk = document.getElementById('ciMake'); mk.value = 'te'; mk.dispatchEvent(new Event('input')); })()`);
check('typing "te" suggests TESLA', (await A.ev(`document.getElementById('sgMake').innerText`)).includes('TESLA'));
await A.ev(`[...document.querySelectorAll('#sgMake button')].find(b => b.textContent === 'TESLA').click()`);
check('model suggestions for TESLA', (await A.ev(`document.getElementById('sgModel').innerText`)).includes('MODEL Y'));
await A.ev(`[...document.querySelectorAll('#sgModel button')].find(b => b.textContent === 'MODEL Y').click()`);
check('make + model filled', (await A.ev(`vehicleText()`)) === 'TESLA MODEL Y');
await A.ev(`(async () => { const mk = document.getElementById('ciMake'); mk.value = 'range'; mk.dispatchEvent(new Event('input')); })()`);
await A.ev(`document.querySelector('#sgMake button').click()`);
check('alias "range" → LAND ROVER RANGE ROVER', (await A.ev(`vehicleText()`)) === 'LAND ROVER RANGE ROVER');
await A.ev(`(async () => { const mk = document.getElementById('ciMake'); mk.value = 'Benz'; mk.dispatchEvent(new Event('input')); })()`);
check('alias "benz" → MERCEDES-BENZ', (await A.ev(`document.getElementById('sgMake').innerText`)).includes('MERCEDES-BENZ'));
await A.ev(`(async () => { const mk = document.getElementById('ciMake'); mk.value = 'Pagani'; mk.dispatchEvent(new Event('input')); })()`);
check('unknown make still allowed (free text)', (await A.ev(`vehicleText()`)).startsWith('PAGANI'));

// 3 offline check-in → clear message, nothing created; back online → one ticket
await A.ev(fill('9545550101', 'HONDA', 'CIVIC'));
await A.send('Network.emulateNetworkConditions', { offline: true, latency: 0, downloadThroughput: -1, uploadThroughput: -1 });
await A.ev(click('ciBtn')); await sleep(5500);
check('offline: friendly message, no crash', /Weak signal/.test(await A.ev(txt('ciErr'))), await A.ev(txt('ciErr')));
check('offline: nothing saved', (await tickets()).length === 0);
await A.send('Network.emulateNetworkConditions', { offline: false, latency: 0, downloadThroughput: -1, uploadThroughput: -1 });
await A.ev(click('ciBtn')); await sleep(2500);
let T = await tickets();
check('back online: exactly 1 ticket', T.length === 1 && T[0].ticket_code === '0101' && T[0].vehicle === 'HONDA CIVIC', T);
check('check-in SMS sent once', (await msgs('CHECKIN')).length === 1);

// 4 lost response (server saved, phone never got the answer) → auto retry, same ticket
await A.send('Fetch.enable', { patterns: [{ urlPattern: '*rpc/event_valet_checkin*', requestStage: 'Response' }] });
let dropped = 0;
A.onPaused(async (p) => { if (dropped === 0) { dropped++; await A.send('Fetch.failRequest', { requestId: p.requestId, errorReason: 'ConnectionReset' }); } else await A.send('Fetch.continueRequest', { requestId: p.requestId }); });
await A.ev(fill('9545550102', 'BMW', 'X5')); await A.ev(click('ciBtn')); await sleep(4000);
await A.send('Fetch.disable');
T = await tickets();
check('lost response: answer dropped once', dropped === 1);
check('lost response: still exactly 1 new ticket (no duplicate)', T.length === 2 && T[1].ticket_code === '0102', T);
check('lost response: screen shows the ticket', (await A.ev(txt('dTicket'))) === '#0102', await A.ev(txt('dTicket')));
check('lost response: SMS once', (await msgs('CHECKIN')).filter(Boolean).length === 2);

// 5 slow signal (2.5 s latency) still works
await A.send('Network.emulateNetworkConditions', { offline: false, latency: 2500, downloadThroughput: 20000, uploadThroughput: 20000 });
await A.ev(fill('9545550103', 'LEXUS', 'RX')); await A.ev(click('ciBtn')); await sleep(9000);
await A.send('Network.emulateNetworkConditions', { offline: false, latency: 0, downloadThroughput: -1, uploadThroughput: -1 });
check('slow signal: ticket created', (await A.ev(txt('dTicket'))) === '#0103', await A.ev(txt('dTicket')));

// 6 printer down when location is chosen → check-in fine, print failed, reprint OK
await fetch('http://127.0.0.1:8791/fail');
await A.ev(`document.querySelector('#dLocs [data-loc="HANGAR 19"]').click()`); await sleep(3500);
check('printer down: shows print failed', /failed/i.test(await A.ev(txt('dPrint'))), await A.ev(txt('dPrint')));
check('printer down: location saved anyway', (await tickets())[2].status === 'PARKED');
await fetch('http://127.0.0.1:8791/fail'); await sleep(4200);
await A.ev(click('dReprint')); await sleep(2000);
T = await tickets();
check('printer back: REPRINT works, same number/slot', /Reprinted/.test(await A.ev(txt('dPrint'))) && T[2].print_count === 1 && T[2].ticket_code === '0103' && T[2].slot_no === 3, T[2]);

// 7 SMS endpoint unreachable → ticket fine, "tap RESEND"; RESEND later sends once
await A.send('Fetch.enable', { patterns: [{ urlPattern: '*event-valet/send*', requestStage: 'Request' }] });
A.onPaused(async (p) => { await A.send('Fetch.failRequest', { requestId: p.requestId, errorReason: 'InternetDisconnected' }); });
await A.ev(fill('9545550104', 'KIA')); await A.ev(click('ciBtn')); await sleep(6000);
check('SMS unreachable: ticket still created', (await A.ev(txt('dTicket'))) === '#0104');
check('SMS unreachable: says tap RESEND', /RESEND/.test(await A.ev(txt('dSms'))), await A.ev(txt('dSms')));
await A.send('Fetch.disable');
await A.ev(click('dResend')); await sleep(2500);
const t104 = (await tickets()).find((t) => t.ticket_code === '0104');
check('RESEND after recovery: sent', /Sent|test/.test(await A.ev(txt('dSms'))) && (await msgs('CHECKIN')).filter((m) => m.ticket_id === t104.id).length === 1);

// 8 two phones at once
const B = await openTab();
await B.send('Page.navigate', { url: PAGE }); await sleep(2500);
const sameSession = (await B.ev(`document.getElementById('app').className`)) === '';
check('second phone opens (same login)', sameSession);
await Promise.all([
  (async () => { await A.ev(fill('3055550201', 'AUDI')); await A.ev(click('ciBtn')); })(),
  (async () => { await B.ev(fill('3055550202', 'JEEP')); await B.ev(click('ciBtn')); })(),
]);
await sleep(3000);
T = await tickets();
const codes = T.map((t) => t.ticket_code), slots = T.filter((t) => t.status !== 'DELIVERED').map((t) => t.slot_no);
check('two phones: no duplicate ticket codes', new Set(codes).size === codes.length, codes);
check('two phones: no duplicate key slots', new Set(slots).size === slots.length, slots);
// same last 4 on two phones at once
await Promise.all([
  (async () => { await A.ev(fill('9545550909', 'FORD')); await A.ev(click('ciBtn')); })(),
  (async () => { await B.ev(fill('3055550909', 'RAM')); await B.ev(click('ciBtn')); })(),
]);
await sleep(3000);
T = await tickets();
const c909 = T.filter((t) => /0909$/.test(t.ticket_code)).map((t) => t.ticket_code).sort();
check('same last 4 at the same time → 0909 + 10909', JSON.stringify(c909) === '["0909","10909"]', c909);

// board sync: A delivers, B sees it within 3 s; double DELIVERED → one thank-you SMS
await A.ev(`document.querySelector('.tab[data-tab=board]').click()`); await B.ev(`document.querySelector('.tab[data-tab=board]').click()`); await sleep(3500);
const target = T.find((t) => t.ticket_code === '0101');
await A.ev(`(async () => { ${W} const c = document.querySelector('.card[data-id="${target.id}"]'); c.querySelector('[data-a=REQUESTED]').click(); await w(1200); })()`);
await sleep(1500);
await A.ev(`(async () => { ${W} const c = document.querySelector('.card[data-id="${target.id}"]'); c.querySelector('[data-a=DELIVERED]').click(); await w(300); document.getElementById('mYes').click(); await w(1500); })()`);
await B.ev(`(async () => { ${W} await w(3500); })()`);
check('other phone sees DELIVERED within 3 s', (await B.ev(`document.querySelector('.card[data-id="${target.id}"]')?.className || ''`)).includes('DELIVERED'));
const r2 = await fetch(`${SB}/rest/v1/rpc/event_valet_set_status`, { method: 'POST', headers: { apikey: ANON, Authorization: `Bearer ${await A.ev(`(async () => (await sb.auth.getSession()).data.session.access_token)()`)}`, 'Content-Type': 'application/json' }, body: JSON.stringify({ p_ticket: target.id, p_status: 'DELIVERED' }) });
check('DELIVERED again = no change', (await r2.json()).changed === false);
check('thank-you SMS exactly once', (await msgs('TIP')).filter((m) => m.ticket_id === target.id).length === 1);

// delete on A disappears on B
const del = T.find((t) => t.ticket_code === '0909');
await A.ev(`(async () => { ${W} const c = document.querySelector('.card[data-id="${del.id}"]'); c.querySelector('[data-m=del]').click(); await w(300); document.getElementById('mYes').click(); await w(1500); })()`);
await B.ev(`(async () => { ${W} await w(3500); })()`);
check('DELETE on one phone disappears on the other', !(await B.ev(`!!document.querySelector('.card[data-id="${del.id}"]')`)));

// offline banner on oscillation: shows after 2 failed refreshes, clears when back
await B.send('Network.emulateNetworkConditions', { offline: true, latency: 0, downloadThroughput: -1, uploadThroughput: -1 });
await B.ev(`(async () => { ${W} await w(8000); })()`);
const bannerOn = !(await B.ev(`document.getElementById('offline').classList.contains('hidden')`));
await B.send('Network.emulateNetworkConditions', { offline: false, latency: 0, downloadThroughput: -1, uploadThroughput: -1 });
await B.ev(`(async () => { ${W} await w(4000); })()`);
const bannerOff = await B.ev(`document.getElementById('offline').classList.contains('hidden')`);
check('signal lost → banner; back → banner gone', bannerOn && bannerOff, { bannerOn, bannerOff });

// expired / missing session → login screen, no crash
await B.ev(`Object.keys(localStorage).filter(k => k.startsWith('sb-')).forEach(k => localStorage.removeItem(k))`);
await B.send('Page.reload'); await sleep(2500);
check('no session → login screen', !(await B.ev(`document.getElementById('viewLogin').classList.contains('hidden')`)));

check('no JavaScript errors on either phone', A.errs.length === 0 && B.errs.length === 0, [...A.errs, ...B.errs]);
const pass = results.filter((r) => r.ok).length;
console.log(`\n${pass}/${results.length} passed`);
A.ws.close(); B.ws.close(); chrome.kill();
process.exit(pass === results.length ? 0 : 1);
