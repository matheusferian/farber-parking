// LOCAL ONLY — headless-Chrome E2E for the Watermakers S710-era pages against
import { writeFileSync } from 'node:fs';
// tests/event_valet/devserver.ts (local DB, mock SMS):
//   staff.html (backup phone link) · t.html (customer pass + thank-you) · admin.html
// node tests/event_valet/e2e_s710_pages.mjs <password> <anonKey> <serviceKey>
import { spawn } from 'node:child_process';
import { createHash, randomBytes } from 'node:crypto';
const [PW, ANON, SERVICE] = process.argv.slice(2);
const EV = 'watermakers-veterans-2026', SB = 'http://127.0.0.1:55331', SITE = 'http://localhost:8789', FN = 'http://127.0.0.1:8790/event-valet', PORT = 9377;
const chrome = spawn('/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', ['--headless=new', '--disable-gpu', `--remote-debugging-port=${PORT}`, `--user-data-dir=/tmp/ev-s710-e2e-${Date.now()}`, '--window-size=390,844', 'about:blank'], { stdio: 'ignore' });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
for (let i = 0; i < 50; i++) { try { await fetch(`http://127.0.0.1:${PORT}/json/version`); break; } catch { await sleep(200); } }
const results = [];
const check = (name, ok, info = '') => { results.push(!!ok); console.log((ok ? 'PASS ' : 'FAIL ') + name + (ok ? '' : '  → ' + JSON.stringify(info).slice(0, 300))); };
const rest = async (path, init = {}) => { const r = await fetch(`${SB}/rest/v1/${path}`, { ...init, headers: { apikey: SERVICE, Authorization: `Bearer ${SERVICE}`, 'Content-Type': 'application/json', ...(init.headers ?? {}) } }); const t = await r.text(); return t ? JSON.parse(t) : null; };
const waitFor = async (fn, ms = 12000) => { const end = Date.now() + ms; while (Date.now() < end) { try { const v = await fn(); if (v) return v; } catch {} await sleep(300); } return false; };

// fixtures: clean event, staff access on, SMS mock on, thanks on, tips on, one phone LINK credential
const tok = randomBytes(32).toString('base64url');
async function wipe() {
  for (const t of ['event_valet_messages', 'event_valet_audit', 'event_valet_tips', 'event_valet_holds']) await rest(`${t}?event_id=eq.${EV}`, { method: 'DELETE' });
  const acc = await rest(`event_valet_access?label=like.E2E*&select=id`);
  for (const a of acc) for (const t of ['event_valet_ops', 'event_valet_rate', 'event_valet_sessions']) await rest(`${t}?access_id=eq.${a.id}`, { method: 'DELETE' });
  await rest(`event_valet_access?label=like.E2E*`, { method: 'DELETE' });
  await rest(`event_valet_tickets?event_id=eq.${EV}`, { method: 'DELETE' });
}
await wipe();
await rest(`event_valet_events?id=eq.${EV}`, { method: 'PATCH', body: JSON.stringify({ is_open: true, closed_at: null, staff_access_enabled: true, sms_enabled: true, sms_test_only: false, thanks_enabled: true, tip_enabled: true }) });
await rest('event_valet_access', { method: 'POST', body: JSON.stringify({ event_id: EV, kind: 'LINK', label: 'E2E phone', token_hash: '\\x' + createHash('sha256').update(tok).digest('hex'), valid_until: new Date(Date.now() + 3600e3).toISOString() }) });

const bws = new WebSocket((await (await fetch(`http://127.0.0.1:${PORT}/json/version`)).json()).webSocketDebuggerUrl);
await new Promise((r) => bws.addEventListener('open', r));
let bid = 0; const bp = new Map();
bws.addEventListener('message', (e) => { const m = JSON.parse(e.data); if (m.id && bp.has(m.id)) { bp.get(m.id)(m); bp.delete(m.id); } });
const bsend = (method, params = {}) => new Promise((r) => { const i = ++bid; bp.set(i, r); bws.send(JSON.stringify({ id: i, method, params })); });
async function tab() {
  const ctx = (await bsend('Target.createBrowserContext', {})).result.browserContextId;
  const targetId = (await bsend('Target.createTarget', { url: 'about:blank', browserContextId: ctx })).result.targetId;
  const ws = new WebSocket(`ws://127.0.0.1:${PORT}/devtools/page/${targetId}`); await new Promise((r) => ws.addEventListener('open', r));
  let id = 0; const pend = new Map(); const errs = [];
  ws.addEventListener('message', (e) => { const m = JSON.parse(e.data); if (m.id && pend.has(m.id)) { pend.get(m.id)(m); pend.delete(m.id); } if (m.method === 'Runtime.exceptionThrown') errs.push(m.params.exceptionDetails.text + ' ' + (m.params.exceptionDetails.exception?.description ?? '')); });
  const send = (method, params = {}) => new Promise((r) => { const i = ++id; pend.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
  await send('Runtime.enable'); await send('Page.enable');
  await send('Emulation.setDeviceMetricsOverride', { width: 390, height: 844, deviceScaleFactor: 2, mobile: true });
  const ev = async (expr) => { const r = await send('Runtime.evaluate', { expression: expr, awaitPromise: true, returnByValue: true }); return r.result?.result?.value; };
  const nav = async (url) => { await send('Page.navigate', { url }); await sleep(900); };
  const click = (sel) => ev(`(function(){var e=document.querySelector(${JSON.stringify(sel)}); if(!e) return 'missing'; e.click(); return 'ok';})()`);
  const text = () => ev('document.body.innerText');
  const offline = (on) => send('Network.emulateNetworkConditions', { offline: on, latency: 0, downloadThroughput: -1, uploadThroughput: -1 });
  await send('Network.enable');
  return { ev, nav, click, text, errs, offline, send };
}


async function shot(t, name) { await sleep(600); const r = await t.send('Page.captureScreenshot', { format: 'png' }); writeFileSync(`${process.env.SHOTS}/${name}.png`, Buffer.from(r.result.data, 'base64')); }
// ── staff backup page ──
const p = await tab();
await p.nav(`${SITE}/events/${EV}/staff#k=${tok}`);
check('staff: token removed from the address bar', !(await p.ev('location.href')).includes(tok), await p.ev('location.href'));
check('staff: asks for the name once', (await p.text()).includes('YOUR NAME'));
if (process.env.SHOTS) await shot(p, 'staff-name');
await p.ev(`document.getElementById('nm').value='ana'`); await p.click('[data-a=start]');
check('staff: home after START SHIFT', await waitFor(async () => (await p.text()).includes('CHECK IN CAR') && (await p.text()).includes('Ana')), await p.text());
check('staff: counts show 50 hooks free', (await p.text()).includes('50'));
if (process.env.SHOTS) await shot(p, 'staff-home');
await p.click('[data-a=checkin]');
await p.ev(`(function(){var i=document.getElementById('ph'); i.value='9545550191'; i.dispatchEvent(new Event('input',{bubbles:true}));})()`);
await p.click('[data-a=color][data-v=White]'); await p.click('[data-a=make][data-v=Tesla]'); await p.click('[data-a=loc][data-v=SIDE]');
check('staff: ASSIGN enabled once phone + car + location set', await p.ev(`!document.getElementById('assign').disabled`));
await p.click('[data-a=assign]');
check('staff: hook 41 shown big (phone pool)', await waitFor(async () => (await p.text()).includes('PUT KEY ON HOOK 41')), await p.text());
await p.click('[data-a=confirm]');
check('staff: confirmed → toast + home', await waitFor(async () => (await p.text()).includes('CHECKED IN — HOOK 41')), await p.text());
const t1 = (await rest(`event_valet_tickets?event_id=eq.${EV}&select=id,slot_no,status,vehicle,checked_in_by`))[0];
check('staff: DB row hook 41, WHITE TESLA, by Ana', t1 && t1.slot_no === 41 && t1.vehicle === 'WHITE TESLA' && t1.checked_in_by === 'Ana', t1);
check('staff: welcome text logged (mock)', (await rest(`event_valet_messages?ticket_id=eq.${t1.id}&kind=eq.CHECKIN&select=status`))[0]?.status === 'MOCK_SENT');
// session survives a reload (name not asked again)
await p.nav(`${SITE}/events/${EV}/staff`);
check('staff: reload keeps the session (no name prompt)', await waitFor(async () => (await p.text()).includes('CHECK IN CAR')) && !(await p.text()).includes('YOUR NAME'));
// offline: check-in disabled with plain message
await p.offline(true); await p.ev(`window.dispatchEvent(new Event('offline'))`); await sleep(300);
check('staff: offline → check-in disabled + "USE THE S710"', await waitFor(async () => (await p.ev(`document.querySelector('[data-a=checkin]').disabled`)) && (await p.text()).includes('NO INTERNET — USE THE S710')), await p.text());
await p.offline(false); await p.ev(`window.dispatchEvent(new Event('online'))`);
check('staff: back online → check-in enabled', await waitFor(async () => await p.ev(`!document.querySelector('[data-a=checkin]').disabled`)));
// get car flow
await p.click('[data-a=cars]');
await waitFor(async () => (await p.text()).includes('GET CAR'));
await p.click('[data-to=RETRIEVING]');
check('staff: GET CAR → RETRIEVING', await waitFor(async () => (await rest(`event_valet_tickets?id=eq.${t1.id}&select=status`))[0].status === 'RETRIEVING'));
await waitFor(async () => (await p.ev(`!!document.querySelector('[data-to=READY]')`)));
await p.click('[data-to=READY]');
await waitFor(async () => (await p.ev(`!!document.querySelector('[data-to=DELIVERED]')`)));
await p.click('[data-to=DELIVERED]');
check('staff: DELIVERED → hook free toast', await waitFor(async () => (await p.text()).includes('IS FREE')), await p.text());
const thanks = await rest(`event_valet_messages?ticket_id=eq.${t1.id}&kind=eq.THANKS&select=status,body`);
check('staff: one thank-you text (mock) after delivery', thanks.length === 1 && thanks[0].status === 'MOCK_SENT', thanks);
// cash tip + duplicate guard (confirm() auto-answered)
await p.click('[data-a=home]'); await p.click('[data-a=tip]');
await p.click('[data-a=amt][data-v="1000"]'); await p.click('[data-a=recordCash]');
check('staff: $10 cash recorded', await waitFor(async () => (await rest(`event_valet_tips?event_id=eq.${EV}&select=amount_cents`)).length === 1));
await p.ev(`window.confirm = function(){ return false; }`);
await p.click('[data-a=tip]'); await p.click('[data-a=amt][data-v="1000"]'); await p.click('[data-a=recordCash]');
await sleep(1200);
check('staff: duplicate cash refused when not confirmed', (await rest(`event_valet_tips?event_id=eq.${EV}&select=id`)).length === 1);
await p.ev(`window.confirm = function(){ return true; }`);
await p.click('[data-a=recordCash]');
check('staff: second tip recorded only after "is this a SECOND tip?" yes', await waitFor(async () => (await rest(`event_valet_tips?event_id=eq.${EV}&select=id`)).length === 2));
// search
await p.click('[data-a=home]'); await p.click('[data-a=search]');
await p.ev(`(function(){var q=document.getElementById('q'); q.value='tesla'; q.dispatchEvent(new Event('input',{bubbles:true}));})()`);
await p.click('[data-a=doSearch]');
check('staff: search finds the delivered Tesla', await waitFor(async () => (await p.text()).includes('WHITE TESLA')));
check('staff: no JS errors', p.errs.length === 0, p.errs);

// ── customer pass + thank-you ──
const mint = async (id) => await (await fetch(`${SB}/rest/v1/rpc/event_valet_mint_guest_token`, { method: 'POST', headers: { apikey: SERVICE, Authorization: `Bearer ${SERVICE}`, 'Content-Type': 'application/json' }, body: JSON.stringify({ p_ticket: id }) })).json();
// a second car checked in through the API (S710-like path is covered by edge tests; use the same link here)
const sess = await (await fetch(`${FN}/staff/session`, { method: 'POST', headers: { 'x-ev-key': tok, 'content-type': 'application/json' }, body: JSON.stringify({ name: 'Diego' }) })).json();
const c2 = await (await fetch(`${FN}/staff/checkin`, { method: 'POST', headers: { 'x-ev-key': tok, 'x-ev-session': sess.sessionId, 'content-type': 'application/json' },
  body: JSON.stringify({ clientKey: 'e2e-' + Date.now(), phone: '9545550192', vehicle: { color: 'Black', make: 'BMW', model: 'X5' }, location: 'FRONT', keyStoredAt: new Date().toISOString() }) })).json();
const t2 = c2.ticket.id;
const c = await tab();
await c.nav(`${SITE}/events/${EV}/t#${await mint(t2)}`);
check('pass: shows the car + Safely Parked', await waitFor(async () => (await c.text()).includes('Black BMW X5') && (await c.text()).includes('Safely Parked')), await c.text());
check('pass: never shows the hook number', !(await c.text()).match(/HOOK|\b42\b/i), await c.text());
check('pass: official Watermakers logo loaded + THANK YOU VETERANS + VALET PARKING BY FARBER PARKING',
  (await c.ev(`(function(){var i=document.querySelector('img.wmlogo'); return !!i && /watermakers-logo-reverse\.png$/.test(i.src) && i.naturalWidth === 505;})()`))
  && (await c.text()).includes('THANK YOU VETERANS') && (await c.text()).includes('VALET PARKING BY FARBER PARKING'));
check('pass: no orange in the page styles', !(await c.ev('document.documentElement.outerHTML')).match(/#e08a0e|#f2a93b|#ff6a3d|#ff7a1a/i));
if (process.env.SHOTS) await shot(c, 'pass');
await c.click('#reqBtn');
check('pass: asks "Ready to leave?" before requesting', (await c.text()).includes('Ready to leave?'));
await c.click('#yesBtn');
check('pass: request received', await waitFor(async () => (await c.text()).includes('Request received')));
check('pass: DB REQUESTED via GUEST_LINK', (await rest(`event_valet_tickets?id=eq.${t2}&select=status,request_source`))[0].request_source === 'GUEST_LINK');
await fetch(`${FN}/staff/status`, { method: 'POST', headers: { 'x-ev-key': tok, 'x-ev-session': sess.sessionId, 'content-type': 'application/json' }, body: JSON.stringify({ clientKey: 'e2e-r-' + Date.now(), ticketId: t2, to: 'RETRIEVING' }) });
check('pass: updates to "On the way" by itself', await waitFor(async () => (await c.text()).includes('On the way'), 15000));
await fetch(`${FN}/staff/status`, { method: 'POST', headers: { 'x-ev-key': tok, 'x-ev-session': sess.sessionId, 'content-type': 'application/json' }, body: JSON.stringify({ clientKey: 'e2e-d-' + Date.now(), ticketId: t2, to: 'DELIVERED' }) });
await c.nav(`${SITE}/events/${EV}/t#${await mint(t2)}`);
if (process.env.SHOTS) setTimeout(() => {}, 0);
check('thank-you: page text', await waitFor(async () => { const x = await c.text(); return x.includes('THANK YOU FOR JOINING US') && x.includes('It was our pleasure taking care of your vehicle.') && x.includes('Thank you for celebrating our veterans.') && x.includes('Farber Parking Valet'); }), await c.text());
const ty = await c.text();
check('thank-you: optional tip with $5 $10 $20 $40 OTHER', ty.includes('WOULD YOU LIKE TO LEAVE A TIP?') && ['$5', '$10', '$20', '$40', 'OTHER', 'NO THANKS'].every((x) => ty.includes(x)), ty);
const href = await c.ev(`document.getElementById('tipGo').href`);
if (process.env.SHOTS) await shot(c, 'thanks');
check('thank-you: tip link → Revenue tip page with ref = vehicle id', href.startsWith(`http://127.0.0.1:3741/e/watermakers-2026-11-11/tip?ref=${t2}`), href);
await c.click('[data-c="2000"]');
check('thank-you: amount pick reaches the link', (await c.ev(`document.getElementById('tipGo').href`)).endsWith('&amountCents=2000'));
await c.click('#noThanks');
check('thank-you: NO THANKS hides the tip box', await c.ev(`document.getElementById('tipBox').classList.contains('hidden')`));
await c.nav(`${SITE}/events/${EV}/t#${await mint(t2)}`); await sleep(800);
check('thank-you: no repeated reminder after NO THANKS', await waitFor(async () => (await c.text()).includes('THANK YOU FOR JOINING US')) && await c.ev(`document.getElementById('tipBox').classList.contains('hidden')`));
await rest(`event_valet_events?id=eq.${EV}`, { method: 'PATCH', body: JSON.stringify({ tip_enabled: false }) });
const c3 = await tab();
await c3.nav(`${SITE}/events/${EV}/t#${await mint(t2)}`);
check('thank-you: tips switch OFF → no tip box', await waitFor(async () => (await c3.text()).includes('THANK YOU FOR JOINING US')) && await c3.ev(`document.getElementById('tipBox').classList.contains('hidden')`));
check('pass: no JS errors', c.errs.length === 0 && c3.errs.length === 0, [c.errs, c3.errs]);

// ── admin ──
const a = await tab();
await a.nav(`${SITE}/events/${EV}/admin`);
await a.ev(`localStorage.setItem('ev_local_cfg', JSON.stringify({url:'${SB}', key:'${ANON}', fn:'${FN}'}))`);
await a.nav(`${SITE}/events/${EV}/admin`);
await a.ev(`document.getElementById('lgUser').value='localipad'; document.getElementById('lgPwd').value=${JSON.stringify(PW)}`);
await a.click('#lgBtn');
check('admin: non-admin login refused', await waitFor(async () => (await a.text()).includes('not an admin')), await a.text());
await a.ev(`supabase.createClient('${SB}','${ANON}').auth.signOut()`);
await a.nav(`${SITE}/events/${EV}/admin`);
await a.ev(`document.getElementById('lgUser').value='localadmin'; document.getElementById('lgPwd').value=${JSON.stringify(PW)}`);
await a.click('#lgBtn');
check('admin: report renders (CHECKED IN 2, cash $20)', await waitFor(async () => { const x = await a.text(); return x.includes('CHECKED IN') && x.includes('$20.00'); }), await a.text());
check('admin: card totals marked unavailable when Revenue is not running', (await a.text()).includes('Card totals unavailable'));
if (process.env.SHOTS) await shot(a, 'admin');
await a.ev(`window.confirm = function(){ return true; }`);
await a.click('[data-flag=smsReplies]');
check('admin: READY REPLIES switch toggles', await waitFor(async () => (await rest(`event_valet_events?id=eq.${EV}&select=sms_replies_enabled`))[0].sms_replies_enabled === true));
await a.ev(`document.getElementById('newLabel').value='E2E new phone'`); await a.click('#newLink');
check('admin: new link shown once', await waitFor(async () => (await a.text()).includes('/staff#k=')), await a.text());
const fixId = (await rest(`event_valet_tips?event_id=eq.${EV}&select=id&order=created_at&limit=1`))[0].id;
await a.ev(`window.prompt = (function(){ var n = 0; return function(){ n++; return n === 1 ? '7.00' : 'counted $7'; }; })()`);
await a.click(`[data-fix="${fixId}"]`);
check('admin: cash correction saved with reason', await waitFor(async () => (await rest(`event_valet_tips?id=eq.${fixId}&select=amount_cents,corrected_from,correction_reason`))[0].correction_reason === 'counted $7'));
check('admin: close is blocked? (no active cars → allowed)', await a.ev(`!document.getElementById('close').disabled`));
const keepLive = await rest(`event_valet_access?event_id=eq.${EV}&revoked_at=is.null&label=not.like.E2E*&select=id`);  // other local credentials (e.g. the Android E2E key)
await a.click('#close');
check('admin: close → event closed, credentials off', await waitFor(async () => (await rest(`event_valet_events?id=eq.${EV}&select=closed_at`))[0].closed_at !== null
  && (await rest(`event_valet_access?event_id=eq.${EV}&revoked_at=is.null&select=id`)).length === 0));
check('admin: no JS errors', a.errs.length === 0, a.errs);

console.log(`\n${results.filter(Boolean).length}/${results.length} passed`);
for (const k of keepLive) await rest(`event_valet_access?id=eq.${k.id}`, { method: 'PATCH', body: JSON.stringify({ revoked_at: null }) });
await wipe();
await rest(`event_valet_events?id=eq.${EV}`, { method: 'PATCH', body: JSON.stringify({ is_open: true, closed_at: null, staff_access_enabled: keepLive.length > 0, sms_enabled: false, sms_test_only: true, thanks_enabled: false, tip_enabled: false, sms_replies_enabled: false }) });
chrome.kill(); process.exit(results.every(Boolean) ? 0 : 1);
