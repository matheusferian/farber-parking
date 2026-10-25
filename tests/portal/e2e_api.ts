// LOCAL ONLY end-to-end test of the passenger portal through the real APIs
// (PostgREST + Edge Functions, real JWTs per role, mock SMS provider).
//   deno run -A tests/portal/e2e_api.ts <scratch dir with env + tokens>
// Refuses to run against anything but 127.0.0.1. Never contacts Twilio/Stripe.
const DIR = Deno.args[0];
const API = 'http://127.0.0.1:56331';
const ANON = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0';
if (!API.startsWith('http://127.0.0.1:')) throw new Error('local only');
const PW = (await Deno.readTextFile(`${DIR}/test_password.txt`)).trim();
const TOK: Record<string, string> = Object.fromEntries((await Deno.readTextFile(`${DIR}/tokens_plain.txt`)).trim().split('\n').map((l) => l.split(' ')));

let pass = 0, fail = 0;
function check(cond: unknown, label: string) {
  if (cond) { pass++; console.log('ok  ' + label); } else { fail++; console.log('FAIL ' + label); }
}
async function login(u: string): Promise<string> {
  const r = await fetch(`${API}/auth/v1/token?grant_type=password`, { method: 'POST', headers: { apikey: ANON, 'Content-Type': 'application/json' }, body: JSON.stringify({ email: `${u}@airvalet.local`, password: PW }) });
  return (await r.json()).access_token;
}
async function rpc(jwt: string | null, fn: string, args: unknown = {}) {
  const r = await fetch(`${API}/rest/v1/rpc/${fn}`, { method: 'POST', headers: { apikey: ANON, Authorization: `Bearer ${jwt || ANON}`, 'Content-Type': 'application/json' }, body: JSON.stringify(args) });
  const t = await r.text(); let j: any = null; try { j = JSON.parse(t); } catch { j = t; }
  return { status: r.status, body: j };
}
async function rest(jwt: string | null, path: string) {
  const r = await fetch(`${API}/rest/v1/${path}`, { headers: { apikey: ANON, Authorization: `Bearer ${jwt || ANON}` } });
  const t = await r.text(); let j: any = null; try { j = JSON.parse(t); } catch { j = t; }
  return { status: r.status, body: j };
}
async function fn(name: string, body: unknown, jwt?: string, extra: Record<string, string> = {}) {
  const r = await fetch(`${API}/functions/v1/${name}`, { method: 'POST', headers: { 'Content-Type': 'application/json', Origin: 'http://127.0.0.1:8781', ...(jwt ? { Authorization: `Bearer ${jwt}` } : {}), ...extra }, body: JSON.stringify(body) });
  const t = await r.text(); let j: any = null; try { j = JSON.parse(t); } catch { j = t; }
  return { status: r.status, body: j, headers: r.headers };
}
const view = (t: string, ip = crypto.randomUUID()) => fn('valet-pass', { t }, undefined, { 'x-forwarded-for': `10.${ip.charCodeAt(0)}.${ip.charCodeAt(1)}.${ip.charCodeAt(2)}` });
const ck = () => 'ck_' + crypto.randomUUID().replace(/-/g, '');
const iso = (d: number) => { const x = new Date(); x.setDate(x.getDate() + d); return x.toISOString().slice(0, 10); };

const admin = await login('localadmin'), ipad = await login('localipad'), iphone = await login('localiphone'), tv = await login('localtv'), mgr = await login('localmanager');
check(admin && ipad && iphone && tv && mgr, 'all role logins work (local test users)');

// ── Portal view ──
const v1 = await view(TOK['900101']);
check(v1.status === 200 && v1.body.state === 'ok', 'portal view ok');
check(v1.headers.get('cache-control') === 'no-store', 'portal: Cache-Control no-store');
const txt = JSON.stringify(v1.body);
check(!txt.includes('1025-11') && !txt.includes('555') && !txt.includes('900101'), 'portal JSON never contains ticket, phone digits or ids');
check((await view('AAAAAAAAAAAAAAAAA')).body.state === 'expired', 'unknown token → expired');
check((await view("' or 1=1 --")).body.state === 'expired', 'injection-looking token → expired');
check((await fn('valet-pass', 'x'.repeat(5000))).status === 413, 'oversized body refused');
check((await fetch(`${API}/functions/v1/valet-pass`)).status === 405, 'GET refused (POST only)');
let limited = false;
for (let i = 0; i < 12; i++) { const r = await fn('valet-pass', { t: 'B'.repeat(17) }, undefined, { 'x-forwarded-for': '10.9.9.9' }); if (r.status === 429) { limited = true; break; } }
check(limited, 'brute force from one client is throttled (429)');

// ── Requests: concurrency + idempotency ──
const key = ck();
// One passenger phone tapping 20 times (same client) → one request.
const same = await Promise.all(Array.from({ length: 20 }, () => fn('valet-pass', { t: TOK['900104'], action: 'request', kind: 'RETURN_CHANGE', reason: 'NEW_DATE_TIME', date: iso(2), time: '17:15', ck: key }, undefined, { 'x-forwarded-for': '10.20.0.1' })));
const pend1 = await rest(ipad, 'airvalet_pass_requests?passenger_id=eq.900104&select=id,status');
check(same.every((r) => r.body.result === 'OK') && pend1.body.length === 1, '20 parallel sends with one client key → exactly 1 request');
// The same link opened on 10 devices at once → still one PENDING.
const diff = await Promise.all(Array.from({ length: 10 }, (_, i) => fn('valet-pass', { t: TOK['900104'], action: 'request', kind: 'RETURN_CHANGE', reason: 'NEW_DATE_TIME', date: iso(3 + i % 3), ck: ck() }, undefined, { 'x-forwarded-for': `10.21.0.${i + 1}` })));
const pend2 = await rest(ipad, 'airvalet_pass_requests?passenger_id=eq.900104&status=eq.PENDING&select=id');
check(diff.every((r) => r.status === 200 && ['OK', 'LIMITED'].includes(r.body.result)) && pend2.body.length === 1, '10 parallel different requests → still one PENDING (others superseded or braked)');
const more: string[] = [];
for (let i = 0; i < 4; i++) more.push((await fn('valet-pass', { t: TOK['900104'], action: 'request', kind: 'RETURN_CHANGE', reason: 'NEW_DATE_TIME', date: iso(4), ck: ck() }, undefined, { 'x-forwarded-for': `10.23.0.${i + 1}` })).body.result);
check(more.includes('LIMITED'), 'per-link daily brake (12 requests) stops a flood from a leaked link');
check((await rest(ipad, 'passengers?id=eq.900104&select=ret')).body[0].ret !== iso(2), 'requests never change the operational return');
const wash = await fn('valet-pass', { t: TOK['900102'], action: 'request', kind: 'CAR_WASH', ck: ck() }, undefined, { 'x-forwarded-for': '10.22.0.1' });
check(wash.body.result === 'CONTACT_TEAM' || wash.body.result === 'NOT_AVAILABLE', 'car wash under 48 h → contact the team');

// ── Staff APIs (safe-update mode, grants, roles) ──
check((await rpc(admin, 'airvalet_portal_settings_set', { p_patch: { reservations_phone: '' } })).status === 200, 'ADMIN can save settings through the API');
check((await rpc(iphone, 'airvalet_portal_settings_set', { p_patch: { portal_enabled: false } })).status >= 400, 'IPHONE_OPS cannot change settings (API)');
check((await rpc(ipad, 'airvalet_portal_settings_set', { p_patch: { portal_enabled: false } })).status >= 400, 'IPAD_OPS cannot change settings (API)');
check((await rpc(mgr, 'airvalet_portal_settings_set', { p_patch: { portal_enabled: false } })).status >= 400, 'MANAGER cannot change settings (API)');
const devs = await rest(admin, 'airvalet_sms_devices?select=id,label&label=eq.E2E%20iPad');
check((await rpc(iphone, 'airvalet_sms_device_decide', { p_device_id: devs.body[0]?.id, p_status: 'revoked' })).status >= 400, 'IPHONE_OPS cannot approve/revoke devices (API)');
check((await rpc(iphone, 'airvalet_admin_alerts_get')).status >= 400, 'IPHONE_OPS cannot read admin alerts');
check((await rpc(admin, 'airvalet_admin_alerts_set', { p_patch: { daily_cap: 25 } })).status === 200, 'Super Admin saves alert settings through the API');
check((await rpc(iphone, 'airvalet_pass_state_set', { p_passenger_id: 900105, p_field: 'ready', p_value: { on: true } })).status === 200, 'staff (IPHONE_OPS) sets Ready through the API');
check((await rpc(tv, 'airvalet_pass_state_set', { p_passenger_id: 900105, p_field: 'ready', p_value: { on: false } })).status >= 400, 'TV cannot set Ready');
check((await view(TOK['900105'])).body.pass.status === 'READY', 'portal shows Ready');
const reqs = await rpc(ipad, 'airvalet_pass_requests_list', { p_days: 7 });
const r4 = reqs.body.find((q: any) => q.passenger_id === 900104 && q.status === 'PENDING');
check((await rpc(tv, 'airvalet_pass_request_decide', { p_id: r4.id, p_decision: 'APPROVE' })).status >= 400, 'TV cannot approve requests');
const dec = await rpc(ipad, 'airvalet_pass_request_decide', { p_id: r4.id, p_decision: 'APPROVE' });
check(dec.status === 200 && dec.body.result === 'APPROVED', 'staff approves through the API');
const twice = await Promise.all([rpc(ipad, 'airvalet_pass_request_decide', { p_id: r4.id, p_decision: 'APPROVE' }), rpc(iphone, 'airvalet_pass_request_decide', { p_id: r4.id, p_decision: 'DECLINE' })]);
check(twice.every((r) => r.body.result === 'ALREADY_DECIDED'), 'a decided request cannot be decided again (concurrent)');

// ── TV: minimal data, RLS ──
const tva = await rpc(tv, 'airvalet_tv_alerts');
check(tva.status === 200 && typeof tva.body.unread === 'number', 'TV reads alerts');
check(!JSON.stringify(tva.body).match(/\+1\d{10}|\(\d{3}\) \d{3}/), 'TV alerts carry no phone numbers');
check((await rest(tv, 'airvalet_sms_messages?select=id')).body.length === 0, 'TV reads no SMS messages (RLS)');
check((await rest(tv, 'passengers?select=id')).body.length === 0, 'TV_ONLY reads no passengers rows (RLS unchanged)');
check((await rest(null, 'airvalet_pass_requests?select=id')).status >= 400 || (await rest(null, 'airvalet_pass_requests?select=id')).body.length === 0, 'anon reads no requests');

// ── Inbound webhook → Inbox + admin copy (mock) ──
await rpc(admin, 'airvalet_admin_alerts_set', { p_patch: { notify_guest_messages: true } });
const sv = await fn('airvalet-admin-alerts', { action: 'start_verify', phone: '(754) 555-0101' }, admin);
check(sv.body.ok === true && sv.body.segments === 1, 'Super Admin: verification code texted (mock, 1 segment)');
check((await fn('airvalet-admin-alerts', { action: 'start_verify', phone: '(754) 555-0101' }, iphone)).status === 403, 'non Super Admin cannot request a code');
const wrong = await rpc(admin, 'airvalet_admin_alerts_confirm', { p_code: '000000' });
check(wrong.body.result === 'WRONG_CODE' || wrong.body.result === 'EXPIRED', 'wrong verification code refused');

// ── Mandatory preview through the API ──
const prev = await fn('send-sms', { passenger_id: 900101, message_type: 'CHECK_IN', preview: true }, ipad, { 'x-airvalet-device': 'e2e_device_key_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx' });
check(prev.body.ok && prev.body.segments === 1 && prev.body.encoding === 'GSM-7' && prev.body.body.startsWith('Welcome to Makers Air Valet!') && prev.body.chars === 160, 'preview: go-live welcome text, 160 chars, 1 GSM-7 segment');
const before = await rest(ipad, 'airvalet_sms_messages?passenger_id=eq.900101&direction=eq.outbound&select=id');
const prevBlocked = await fn('send-sms', { passenger_id: 900101, message_type: 'CHECK_IN', preview: true }, ipad, { 'x-airvalet-device': 'not-approved-device-key-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx' });
check(prevBlocked.body.would_send === false && prevBlocked.body.block === 'DEVICE_NOT_AUTHORIZED', 'preview tells why: unapproved device');
const after = await rest(ipad, 'airvalet_sms_messages?passenger_id=eq.900101&direction=eq.outbound&select=id');
check(before.body.length === after.body.length, 'previews never create a message');

// ── Valet pass chat (no SMS) + Digital Pass switch ──
check((await rpc(ipad, 'airvalet_digital_pass_set', { p_on: true })).status >= 400, 'iPad cannot flip the Digital Pass switch');
const on = await rpc(admin, 'airvalet_digital_pass_set', { p_on: true });
check(on.body.on === true && on.body.chat === true && on.body.requests === true && on.body.portal === true, 'ADMIN: Digital Pass ON (texts, page, chat, requests)');
check((await view(TOK['900101'])).body.pass.chat_enabled === true, 'portal shows the chat button when on');
const chatIp = { 'x-forwarded-for': '10.30.0.1' };
const ckc = ck();
const sent = await Promise.all([1, 2, 3].map(() => fn('valet-pass', { t: TOK['900101'], action: 'send', body: 'Landing 6pm 😀\nThanks!', ck: ckc }, undefined, chatIp)));
check(sent.every((r) => r.body.state === 'ok'), 'passenger chat message accepted');
const inb = await rest(ipad, "airvalet_sms_messages?passenger_id=eq.900101&provider=eq.portal&direction=eq.inbound&select=id,body");
check(inb.body.length === 1 && inb.body[0].body === 'Landing 6pm \nThanks!', 'same message key x3 → one Inbox row, GSM-7, line break kept');
const sr = await rpc(ipad, 'airvalet_portal_staff_reply', { p_passenger_id: 900101, p_body: 'See you at Hangar 19.', p_compose_id: 'compose:' + crypto.randomUUID(), p_staff_name: 'Ana' });
check(sr.body.result === 'OK', 'staff chat-only reply (app compose id) stored');
const th = await fn('valet-pass', { t: TOK['900101'], action: 'messages' }, undefined, chatIp);
const bodies = (th.body.messages || []).map((m: any) => m.body);
check(bodies.includes('See you at Hangar 19.') && bodies.includes('Landing 6pm \nThanks!'), 'guest thread shows both sides');
check(!JSON.stringify(th.body).match(/\+1\d{10}|900101|1025-/), 'guest thread carries no phone, ids or ticket');
check((await fn('valet-pass', { t: TOK['900102'], action: 'messages' }, undefined, { 'x-forwarded-for': '10.30.0.2' })).body.messages.every((m: any) => m.body !== 'See you at Hangar 19.'), 'another passenger never sees this chat');
const off = await rpc(admin, 'airvalet_digital_pass_set', { p_on: false });
check(off.body.on === false && off.body.chat === false && off.body.requests === false, 'ADMIN: Digital Pass OFF (texts, chat, requests off)');
const v2 = await view(TOK['900101']);
check(v2.body.state === 'ok' && v2.body.pass.chat_enabled === false, 'OFF: link still readable, chat hidden');
check((await fn('valet-pass', { t: TOK['900101'], action: 'send', body: 'hello', ck: ck() }, undefined, chatIp)).body.result !== 'OK', 'OFF: chat messages refused');

console.log(`\n${pass} passed, ${fail} failed`);
if (fail) Deno.exit(1);
