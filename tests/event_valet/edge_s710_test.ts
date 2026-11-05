// Watermakers S710 staff API — edge tests against the LOCAL stack (real PostgREST + DB).
// SMS run in mock mode (EVENT_VALET_SMS_MODE=mock): nothing leaves the machine.
//
// EV_SERVICE_KEY_FILE=… EV_ANON_KEY_FILE=… EV_PW_FILE=… deno test -A --no-check tests/event_valet/edge_s710_test.ts
import { assert, assertEquals, assertStringIncludes } from 'jsr:@std/assert@1';
import { makeHandler } from '../../supabase/functions/event-valet/handler.ts';
import { computeSignature } from '../../supabase/functions/event-valet/lib.ts';
import { handleInbound, WebhookStore } from '../../supabase/functions/_shared/sms/webhooks.ts';

const SB = Deno.env.get('EV_SB_URL') ?? 'http://127.0.0.1:55331';
const SERVICE = Deno.readTextFileSync(Deno.env.get('EV_SERVICE_KEY_FILE')!).trim();
const ANON = Deno.readTextFileSync(Deno.env.get('EV_ANON_KEY_FILE')!).trim();
const PW = Deno.readTextFileSync(Deno.env.get('EV_PW_FILE')!).trim();
const EV = 'watermakers-veterans-2026';
const REV = 'https://revenue.example.test';
const PARTNER = 'partner_key_for_tests_only_0123456789';
const ACCOUNT = 'ACtest0000000000000000000000000000';
const MG = 'MGtest0000000000000000000000000000';
const AUTH = 'test_auth_token_0123456789abcdef';

const sh = { apikey: SERVICE, Authorization: `Bearer ${SERVICE}`, 'Content-Type': 'application/json' };
async function rest(path: string, init: RequestInit = {}) {
  const r = await fetch(`${SB}/rest/v1/${path}`, { ...init, headers: { ...sh, ...(init.headers ?? {}) } });
  const t = await r.text();
  if (!r.ok) throw new Error(`${path} ${r.status} ${t.slice(0, 200)}`);
  return t ? JSON.parse(t) : null;
}
const hex = async (s: string) => '\\x' + [...new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(s)))].map((b) => b.toString(16).padStart(2, '0')).join('');
const tok = (p: string) => (p + 'x'.repeat(43)).slice(0, 43);
const DEV = tok('edgedev'), LNK = tok('edgelnk'), REVK = tok('edgerev'), HWD = tok('edgehwd');

async function wipe() {
  for (const t of ['event_valet_messages', 'event_valet_audit', 'event_valet_tips', 'event_valet_holds']) await rest(`${t}?event_id=eq.${EV}`, { method: 'DELETE' });
  const acc: { id: string }[] = await rest(`event_valet_access?label=like.EDGE*&select=id`);
  for (const a of acc) {
    for (const t of ['event_valet_ops', 'event_valet_rate', 'event_valet_sessions']) await rest(`${t}?access_id=eq.${a.id}`, { method: 'DELETE' });
  }
  await rest(`event_valet_access?label=like.EDGE*`, { method: 'DELETE' });
  await rest(`event_valet_tickets?event_id=eq.${EV}`, { method: 'DELETE' });
  await rest(`passengers?phone=eq.(954) 555-0177`, { method: 'DELETE' });
  await rest(`event_valet_events?id=eq.${EV}`, { method: 'PATCH', body: JSON.stringify({ is_open: true, closed_at: null,
    staff_access_enabled: false, sms_enabled: false, sms_test_only: true, sms_test_phones: [], tip_enabled: false, thanks_enabled: false, sms_replies_enabled: false }) });
}
async function setup() {
  await wipe();
  await rest(`event_valet_events?id=eq.${EV}`, { method: 'PATCH', body: JSON.stringify({ staff_access_enabled: true }) });
  const until = new Date(Date.now() + 3600_000).toISOString();
  await rest('event_valet_access', { method: 'POST', body: JSON.stringify([
    { event_id: EV, kind: 'DEVICE', label: 'EDGE S710', token_hash: await hex(DEV), valid_until: until, revoked_at: null },
    { event_id: EV, kind: 'LINK', label: 'EDGE phone', token_hash: await hex(LNK), valid_until: until, revoked_at: null },
    { event_id: EV, kind: 'LINK', label: 'EDGE revoked', token_hash: await hex(REVK), valid_until: until, revoked_at: new Date().toISOString() },
    { event_id: 'makers-halloween-2026', kind: 'DEVICE', label: 'EDGE halloween', token_hash: await hex(HWD), valid_until: until, revoked_at: null },
  ]) });
}

// fetch that answers Revenue's partner summary; everything else goes to the local stack
let revenueMode: 'ok' | 'down' = 'down';
const partnerCalls: Headers[] = [];
const fakeFetch: typeof fetch = async (input, init) => {
  const url = String(input instanceof Request ? input.url : input);
  if (url.startsWith(REV)) {
    partnerCalls.push(new Headers(init?.headers));
    if (revenueMode === 'down') throw new TypeError('connection refused');
    return new Response(JSON.stringify({ eventCode: 'WATERMAKERS_2026_11_11', currency: 'usd', s710: { count: 2, cents: 3000 }, digital: { count: 1, cents: 1000 },
      pending: { count: 0, cents: 0 }, failed: { count: 1 }, refunded: { count: 0, cents: 0 }, payments: [] }), { status: 200 });
  }
  return fetch(input, init);
};
const env = (k: string) => ({
  SUPABASE_URL: SB, SUPABASE_SERVICE_ROLE_KEY: SERVICE, SUPABASE_ANON_KEY: ANON, EVENT_VALET_SMS_MODE: 'mock',
  EVENT_VALET_PUBLIC_URL: 'https://example.test/functions/v1/event-valet', EVENT_VALET_SITE_URL: 'https://airvalet.farberos.com',
  REVENUE_PUBLIC_BASE_URL: REV, EVENT_PAY_PARTNER_KEY: PARTNER, TWILIO_ACCOUNT_SID: ACCOUNT, TWILIO_MESSAGING_SERVICE_SID: MG, TWILIO_AUTH_TOKEN: AUTH,
} as Record<string, string>)[k];
const h = makeHandler(env, fakeFetch);

async function call(method: 'GET' | 'POST', op: string, key: string, session: string | null, body?: unknown, origin?: string) {
  const headers: Record<string, string> = { 'x-ev-key': key, 'content-type': 'application/json' };
  if (session) headers['x-ev-session'] = session;
  if (origin) headers.origin = origin;
  const q = method === 'GET' && body ? '?' + new URLSearchParams(body as Record<string, string>) : '';
  const r = await h(new Request(`http://localhost/event-valet/staff/${op}${q}`, { method, headers, body: method === 'POST' ? JSON.stringify(body ?? {}) : undefined }));
  return { code: r.status, body: await r.json(), headers: r.headers };
}
const ck = () => 'edge-' + crypto.randomUUID();
const msgs = async (ticket: string, kind?: string) => await rest(`event_valet_messages?ticket_id=eq.${ticket}&direction=eq.OUT${kind ? `&kind=eq.${kind}` : ''}&order=id`);
const keyAt = new Date().toISOString();

let SD = '', SL = '', T1 = '', T2 = '';

Deno.test('setup + sessions + auth errors (plain English, right HTTP codes)', async () => {
  await setup();
  const s1 = await call('POST', 'session', DEV, null, { name: 'carlos' });
  assertEquals(s1.code, 200); assertEquals(s1.body.employeeName, 'Carlos'); assertEquals(s1.body.access.pool, [1, 40]);
  SD = s1.body.sessionId;
  SL = (await call('POST', 'session', LNK, null, { name: 'Ana' })).body.sessionId;
  const bad = await call('GET', 'state', tok('nobody'), SD);
  assertEquals(bad.code, 401); assertEquals(bad.body.error, 'AUTH'); assertStringIncludes(bad.body.message, 'Ask your supervisor');
  const rv = await call('GET', 'state', REVK, SD);
  assertEquals(rv.code, 401); assertEquals(rv.body.error, 'REVOKED');
  const ns = await call('GET', 'state', DEV, null);
  assertEquals(ns.code, 401);
  const wrong = await call('POST', 'state', DEV, SD);
  assertEquals(wrong.code, 405);
  const unknown = await call('POST', 'teleport', DEV, SD, {});
  assertEquals(unknown.code, 405);
});

Deno.test('CORS preflight allows the staff headers', async () => {
  const r = await h(new Request('http://localhost/event-valet/staff/state', { method: 'OPTIONS', headers: { origin: 'http://localhost:8790' } }));
  assertEquals(r.status, 204);
  assertStringIncludes(r.headers.get('access-control-allow-headers') ?? '', 'x-ev-key');
  assertStringIncludes(r.headers.get('access-control-allow-methods') ?? '', 'GET');
});

Deno.test('state + check-in (SMS off → OFF) + idempotent replay sends nothing twice', async () => {
  const st = await call('GET', 'state', DEV, SD, { pending: '0' });
  assertEquals(st.code, 200); assertEquals(st.body.counts.hooksFree, 50); assertEquals(st.headers.get('cache-control'), 'no-store');
  const k = ck();
  const body = { clientKey: k, phone: '(954) 555-0101', vehicle: { color: 'Black', make: 'BMW', model: 'X5' }, location: 'FRONT', keyStoredAt: keyAt };
  const c = await call('POST', 'checkin', DEV, SD, body);
  assertEquals(c.code, 200); assertEquals(c.body.ticket.hook, 1); assertEquals(c.body.sms, { welcome: 'OFF' });
  assert(!('notify' in c.body)); assert(!JSON.stringify(c.body).includes('+19545550101'));
  T1 = c.body.ticket.id;
  const again = await call('POST', 'checkin', DEV, SD, body);
  assertEquals(again.body.replayed, true); assertEquals(again.body.ticket.id, T1); assert(!again.body.sms);
  assertEquals((await msgs(T1)).length, 1);  // the one SKIPPED_SMS_OFF row
});

Deno.test('welcome SMS (mock) carries the pass link and Farber signature', async () => {
  await rest(`event_valet_events?id=eq.${EV}`, { method: 'PATCH', body: JSON.stringify({ sms_enabled: true, sms_test_only: false }) });
  const c = await call('POST', 'checkin', LNK, SL, { clientKey: ck(), phone: '9545550102', vehicle: { plate: 'LXR 4417' }, location: 'SIDE', keyStoredAt: keyAt });
  assertEquals(c.code, 200); assertEquals(c.body.ticket.hook, 41); assertEquals(c.body.sms, { welcome: 'SENT' });
  T2 = c.body.ticket.id;
  const m = (await msgs(T2, 'CHECKIN'))[0];
  assertEquals(m.status, 'MOCK_SENT');
  assertStringIncludes(m.body, '/events/watermakers-veterans-2026/t#********');
  assertStringIncludes(m.body, '— Farber Parking Valet'); assertStringIncludes(m.body, 'Reply STOP');
});

Deno.test('HOOK_TAKEN / pool messages for employees', async () => {
  const r = await call('POST', 'checkin', DEV, SD, { clientKey: ck(), phone: '9545550103', vehicle: { make: 'KIA' }, location: 'BACK', hook: 41, keyStoredAt: keyAt });
  assertEquals(r.code, 409); assertEquals(r.body.error, 'HOOK_TAKEN'); assertEquals(r.body.suggestedHook, 2);
  assertEquals(r.body.message, 'HOOK 41 ALREADY USED — MOVE KEY TO HOOK 02');
  const p = await call('POST', 'checkin', LNK, SL, { clientKey: ck(), phone: '9545550103', vehicle: { make: 'KIA' }, location: 'BACK', hook: 3, keyStoredAt: keyAt });
  assertEquals(p.code, 400); assertEquals(p.body.message, 'THAT HOOK BELONGS TO THE S710 — CHOOSE ANOTHER');
  const v = await call('POST', 'checkin', DEV, SD, { clientKey: ck(), phone: '12', vehicle: { make: 'KIA' }, location: 'BACK', keyStoredAt: keyAt });
  assertEquals(v.code, 400); assertEquals(v.body.message, 'CHECK THE PHONE NUMBER');
  const hold = await call('POST', 'hold', DEV, SD, { clientKey: ck() });
  assertEquals(hold.code, 200); assertEquals(hold.body.hook, 2);
});

Deno.test('GET CAR → CAR READY → DELIVERED: on-the-way, ready, one thank-you; ownership conflict', async () => {
  const g = await call('POST', 'status', DEV, SD, { clientKey: ck(), ticketId: T2, to: 'RETRIEVING' });
  assertEquals(g.code, 200); assertEquals(g.body.ticket.status, 'RETRIEVING'); assertEquals(g.body.sms, { onway: 'SENT' });
  const taken = await call('POST', 'status', LNK, SL, { clientKey: ck(), ticketId: T2, to: 'RETRIEVING' });
  assertEquals(taken.code, 409); assertEquals(taken.body.message, 'CARLOS IS ALREADY GETTING THIS CAR');
  const rd = await call('POST', 'status', DEV, SD, { clientKey: ck(), ticketId: T2, to: 'READY' });
  assertEquals(rd.body.sms, { ready: 'SENT' });
  // thanks switch OFF → no thank-you text
  const dl = await call('POST', 'status', DEV, SD, { clientKey: ck(), ticketId: T2, to: 'DELIVERED' });
  assertEquals(dl.body.ticket.status, 'DELIVERED'); assertEquals(dl.body.sms, { thanks: 'OFF' });
  assertEquals((await msgs(T2, 'THANKS'))[0].status, 'SKIPPED_THANKS_OFF');
  assertStringIncludes((await msgs(T2, 'ONWAY'))[0].body, 'on the way');
  // thanks ON → exactly one thank-you with the contract text
  await rest(`event_valet_events?id=eq.${EV}`, { method: 'PATCH', body: JSON.stringify({ thanks_enabled: true }) });
  const c = await call('POST', 'checkin', DEV, SD, { clientKey: ck(), phone: '9545550104', vehicle: { make: 'Tesla' }, location: 'FRONT', keyStoredAt: keyAt });
  const id = c.body.ticket.id;
  const d1 = await call('POST', 'status', DEV, SD, { clientKey: ck(), ticketId: id, to: 'DELIVERED' });
  assertEquals(d1.body.sms, { thanks: 'SENT' });
  const d2 = await call('POST', 'status', DEV, SD, { clientKey: ck(), ticketId: id, to: 'DELIVERED' });
  assertEquals(d2.code, 400);                                       // already delivered: no second note
  const th = await msgs(id, 'THANKS');
  assertEquals(th.length, 1);
  assert(/^Thank you for joining us at Watermakers! Your valet has left you a note\. View it here: https:\/\/airvalet\.farberos\.com\/events\/watermakers-veterans-2026\/t#\*{8} — Farber Parking Valet$/.test(th[0].body), th[0].body);
});

Deno.test('cash tip duplicate guard, search, edit, move-hook', async () => {
  const a = await call('POST', 'cash-tip', LNK, SL, { clientKey: ck(), ticketId: T1, amountCents: 1000 });
  assertEquals(a.code, 200); assertEquals(a.body.tip.employeeName, 'Ana');
  const dup = await call('POST', 'cash-tip', DEV, SD, { clientKey: ck(), ticketId: T1, amountCents: 1000 });
  assertEquals(dup.code, 409); assertEquals(dup.body.error, 'DUPLICATE_CASH'); assertEquals(dup.body.existing.employeeName, 'Ana');
  const lo = await call('POST', 'cash-tip', DEV, SD, { clientKey: ck(), amountCents: 50 });
  assertEquals(lo.body.message, 'TIP MUST BE $1 TO $500');
  const s = await call('GET', 'search', DEV, SD, { q: '1' });
  assertEquals(s.body.tickets.length, 1); assertEquals(s.body.tickets[0].id, T1);
  const s2 = await call('GET', 'search', DEV, SD, { q: 'lxr 4417' });
  assert(s2.body.tickets.some((t: { id: string }) => t.id === T2));
  const e = await call('POST', 'edit', DEV, SD, { clientKey: ck(), ticketId: T1, location: 'BACK' });
  assertEquals(e.body.ticket.location, 'BACK');
  const m = await call('POST', 'move-hook', DEV, SD, { clientKey: ck(), ticketId: T1, hook: 7 });
  assertEquals(m.body.ticket.hook, 7);
});

Deno.test('cross-event isolation through HTTP', async () => {
  await rest('event_valet_events?id=eq.makers-halloween-2026', { method: 'PATCH', body: JSON.stringify({ staff_access_enabled: true }) });
  const sh = (await call('POST', 'session', HWD, null, { name: 'Hal' })).body.sessionId;
  const r = await call('POST', 'status', HWD, sh, { clientKey: ck(), ticketId: T1, to: 'READY' });
  assertEquals(r.code, 404);
  const st = await call('GET', 'state', HWD, sh);
  assert(!st.body.tickets.some((t: { id: string }) => t.id === T1));
  await rest('event_valet_events?id=eq.makers-halloween-2026', { method: 'PATCH', body: JSON.stringify({ staff_access_enabled: false }) });
});

Deno.test('rate limit → 429', async () => {
  const acc = (await rest(`event_valet_access?label=eq.EDGE phone&select=id`))[0].id;
  const bucket = new Date(); bucket.setSeconds(0, 0);
  await rest('event_valet_rate?on_conflict=access_id,bucket', { method: 'POST', headers: { Prefer: 'resolution=merge-duplicates' },
    body: JSON.stringify({ access_id: acc, bucket: bucket.toISOString(), n: 240 }) });
  const r = await call('GET', 'state', LNK, SL);
  assertEquals(r.code, 429); assertEquals(r.body.error, 'RATE_LIMIT');
  await rest(`event_valet_rate?access_id=eq.${acc}`, { method: 'DELETE' });
});

async function mintGuest(ticket: string) { return await (await fetch(`${SB}/rest/v1/rpc/event_valet_mint_guest_token`, { method: 'POST', headers: sh, body: JSON.stringify({ p_ticket: ticket }) })).json(); }
async function guest(token: string, action = 'view') {
  const r = await h(new Request('http://localhost/event-valet/guest', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ token, action }) }));
  return await r.json();
}

Deno.test('customer pass: never the hook; RETRIEVING; thank-you + tip URL only with tips ON', async () => {
  const c = await call('POST', 'checkin', DEV, SD, { clientKey: ck(), phone: '9545550105', vehicle: { color: 'White', make: 'Lexus' }, location: 'SIDE', keyStoredAt: keyAt });
  const id = c.body.ticket.id;
  const g0 = await guest(await mintGuest(id));
  assertEquals(g0.status, 'PARKED'); assertEquals(g0.vehicle_text, 'White Lexus'); assertEquals(g0.thank_you, false);
  assert(!('slot_no' in g0) && !('hook' in g0) && !JSON.stringify(g0).includes('"' + c.body.ticket.hook + '"'));
  await call('POST', 'status', DEV, SD, { clientKey: ck(), ticketId: id, to: 'RETRIEVING' });
  assertEquals((await guest(await mintGuest(id))).status, 'RETRIEVING');
  await call('POST', 'status', DEV, SD, { clientKey: ck(), ticketId: id, to: 'DELIVERED' });
  const g1 = await guest(await mintGuest(id));
  assertEquals(g1.thank_you, true); assertEquals(g1.tip_url, null);
  await rest(`event_valet_events?id=eq.${EV}`, { method: 'PATCH', body: JSON.stringify({ tip_enabled: true }) });
  const g2 = await guest(await mintGuest(id));
  assertEquals(g2.tip_url, `${REV}/e/watermakers-2026-11-11/tip?ref=${id}`);
  await rest(`event_valet_events?id=eq.${EV}`, { method: 'PATCH', body: JSON.stringify({ tip_enabled: false }) });
});

Deno.test('guest link request → REQUESTED shows on the staff board', async () => {
  const c = await call('POST', 'checkin', DEV, SD, { clientKey: ck(), phone: '9545550106', vehicle: { make: 'Jeep' }, location: 'BACK', keyStoredAt: keyAt });
  const id = c.body.ticket.id;
  const g = await guest(await mintGuest(id), 'request');
  assertEquals(g.status, 'REQUESTED');
  const st = await call('GET', 'state', DEV, SD);
  assertEquals(st.body.tickets.find((t: { id: string }) => t.id === id).requestSource, 'GUEST_LINK');
});

Deno.test('Halloween guest reply keeps its old shape (no Watermakers fields)', async () => {
  const r = await fetch(`${SB}/rest/v1/rpc/event_valet_checkin`, { method: 'POST', headers: sh, body: '{}' });
  await r.body?.cancel();
  const rows = await rest(`event_valet_tickets?event_id=eq.makers-halloween-2026&select=id&limit=1`);
  if (!rows.length) return;  // no Halloween ticket in this local DB: nothing to compare
  const g = await guest(await mintGuest(rows[0].id));
  assert(!('event_id' in g) && !('tip_url' in g) && !('thank_you' in g), JSON.stringify(g));
});

async function adminJwt(email: string) {
  const r = await fetch(`${SB}/auth/v1/token?grant_type=password`, { method: 'POST', headers: { apikey: ANON, 'Content-Type': 'application/json' }, body: JSON.stringify({ email, password: PW }) });
  return (await r.json()).access_token as string;
}
Deno.test('admin report merges Revenue card tips; tolerates Revenue down; non-admin refused', async () => {
  const jwt = await adminJwt('localadmin@airvalet.local');
  const post = async (j: string) => await h(new Request('http://localhost/event-valet/admin/report', { method: 'POST', headers: { Authorization: `Bearer ${j}`, 'content-type': 'application/json' }, body: JSON.stringify({ event_id: EV }) }));
  revenueMode = 'down';
  const r1 = await (await post(jwt)).json();
  assertEquals(r1.cards, { available: false, error: 'REVENUE_UNAVAILABLE' });
  assert(r1.counts.checkedIn >= 5);
  revenueMode = 'ok';
  const r2 = await (await post(jwt)).json();
  assertEquals(r2.cards.available, true); assertEquals(r2.cards.s710.cents, 3000);
  assertEquals(partnerCalls.at(-1)!.get('x-event-partner-key'), PARTNER);
  const ipad = await adminJwt('localipad@airvalet.local');
  assertEquals((await post(ipad)).status, 403);
});

// ── READY on the shared AirValet number (twilio-inbound path) ──
const inboundParams = (from: string, body: string) => new URLSearchParams({ MessageSid: 'SM' + crypto.randomUUID().replace(/-/g, ''), From: from, To: '+19545269800', Body: body, AccountSid: ACCOUNT, MessagingServiceSid: MG });

Deno.test('routedInbound: OFF switch → not ours; ON → requests the car; chat → not ours', async () => {
  const c = await call('POST', 'checkin', DEV, SD, { clientKey: ck(), phone: '9545550107', vehicle: { make: 'Audi' }, location: 'FRONT', keyStoredAt: keyAt });
  const id = c.body.ticket.id;
  assertEquals(await h.routedInbound(inboundParams('+19545550107', 'READY')), null);         // replies switch off
  await rest(`event_valet_events?id=eq.${EV}`, { method: 'PATCH', body: JSON.stringify({ sms_replies_enabled: true }) });
  assertEquals(await h.routedInbound(inboundParams('+19545550107', 'thanks for the help')), null);
  assertEquals(await h.routedInbound(inboundParams('+13055559999', 'READY')), null);         // unknown phone
  const r = await h.routedInbound(inboundParams('+19545550107', 'ready'));
  assert(r); assertEquals(r!.status, 200);
  const t = (await rest(`event_valet_tickets?id=eq.${id}&select=status,request_source`))[0];
  assertEquals(t, { status: 'REQUESTED', request_source: 'SMS' });
  await h.routedInbound(inboundParams('+19545550107', 'READY'));                             // duplicate READY
  assertEquals((await rest(`event_valet_tickets?id=eq.${id}&select=status`))[0].status, 'REQUESTED');
});

Deno.test('routedInbound: two cars → asks which; Makers Air trip on the same phone → CROSS, no request', async () => {
  for (const make of ['Ford', 'Honda']) await call('POST', 'checkin', DEV, SD, { clientKey: ck(), phone: '9545550108', vehicle: { make }, location: 'SIDE', keyStoredAt: keyAt });
  const r = await h.routedInbound(inboundParams('+19545550108', 'READY'));
  assert(r);
  const amb = await rest(`event_valet_messages?phone_e164=eq.%2B19545550108&kind=eq.AMBIGUOUS&select=body`);
  assertEquals(amb.length, 1); assertStringIncludes(amb[0].body, 'Which vehicle');
  const c = await call('POST', 'checkin', DEV, SD, { clientKey: ck(), phone: '9545550177', vehicle: { make: 'Mini' }, location: 'BACK', keyStoredAt: keyAt });
  await rest('passengers', { method: 'POST', body: JSON.stringify({ phone: '(954) 555-0177', status: 'PENDING' }) });
  const x = await h.routedInbound(inboundParams('+19545550177', 'READY'));
  assert(x);
  assertEquals((await rest(`event_valet_tickets?id=eq.${c.body.ticket.id}&select=status`))[0].status, 'PARKED');
  const cross = await rest(`event_valet_messages?ticket_id=eq.${c.body.ticket.id}&kind=eq.CROSS&select=body,status`);
  assertEquals(cross.length, 1); assertStringIncludes(cross[0].body, 'more than one place');
});

// handleInbound (shared AirValet webhook): preRoute absent → identical path; present → can claim; throwing → falls through
function fakeStore() {
  const calls: string[] = [];
  const store: WebhookStore = {
    applyStatus: async () => 'ok',
    recordInbound: async (sid) => { calls.push(sid); return { message_id: 'm1', inserted: true, passenger_id: 1, match_method: 'active_passenger' }; },
  };
  return { store, calls };
}
async function signed(params: URLSearchParams) {
  const url = 'https://example.test/functions/v1/twilio-inbound';
  const sig = await computeSignature(AUTH, url, params.entries());
  return new Request('http://localhost/twilio-inbound', { method: 'POST', headers: { 'content-type': 'application/x-www-form-urlencoded', 'x-twilio-signature': sig }, body: params });
}
Deno.test('twilio-inbound: flag OFF keeps the AirValet inbox path; ON claims only event READY; errors fall through', async () => {
  const base = { authToken: AUTH, publicUrl: 'https://example.test/functions/v1/twilio-inbound', expectedMessagingServiceSid: MG };
  const off = fakeStore();
  const r0 = await handleInbound({ ...base, store: off.store }, await signed(inboundParams('+19545550107', 'READY')));
  assertEquals(r0.status, 200); assertEquals(off.calls.length, 1);                            // stored as AirValet guest message, as today
  const on = fakeStore();
  const claimed = await handleInbound({ ...base, store: on.store, preRoute: () => Promise.resolve(new Response('<Response/>', { status: 200 })) }, await signed(inboundParams('+19545550107', 'READY')));
  assertEquals(claimed.status, 200); assertEquals(on.calls.length, 0);
  const pass = fakeStore();
  await handleInbound({ ...base, store: pass.store, preRoute: () => Promise.resolve(null) }, await signed(inboundParams('+13055550000', 'hello')));
  assertEquals(pass.calls.length, 1);
  const boom = fakeStore();
  await handleInbound({ ...base, store: boom.store, preRoute: () => Promise.reject(new Error('db down')) }, await signed(inboundParams('+13055550000', 'READY')));
  assertEquals(boom.calls.length, 1);
  const kw = fakeStore(); let asked = false;
  await handleInbound({ ...base, store: kw.store, preRoute: () => { asked = true; return Promise.resolve(null); } }, await signed(inboundParams('+19545550107', 'STOP')));
  assertEquals(asked, false);                                                                  // keywords never reach Event Valet
  const bad = fakeStore();
  const forged = await handleInbound({ ...base, store: bad.store, preRoute: () => Promise.resolve(new Response('x')) },
    new Request('http://localhost/twilio-inbound', { method: 'POST', headers: { 'content-type': 'application/x-www-form-urlencoded', 'x-twilio-signature': 'nope' }, body: inboundParams('+19545550107', 'READY') }));
  assertEquals(forged.status, 403);
});

Deno.test('teardown: Watermakers back to all switches OFF', async () => { await wipe(); });
