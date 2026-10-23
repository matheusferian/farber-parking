// Integration tests for supabase/functions/event-valet against the LOCAL
// Supabase stack (real PostgREST + DB). Twilio is never called: the live
// path uses an intercepted fetch; mock mode never touches the network.
//
// deno test -A tests/event_valet/edge_test.ts
// env: EV_SB_URL, EV_SERVICE_KEY_FILE, EV_ANON_KEY_FILE, EV_PW_FILE
import { assert, assertEquals } from 'jsr:@std/assert@1';
import { makeHandler } from '../../supabase/functions/event-valet/handler.ts';
import { computeSignature, composeSms, parseInbound, normalizePhone, maskLink } from '../../supabase/functions/event-valet/lib.ts';

const SB = Deno.env.get('EV_SB_URL') ?? 'http://127.0.0.1:55331';
const SERVICE = Deno.readTextFileSync(Deno.env.get('EV_SERVICE_KEY_FILE')!).trim();
const ANON = Deno.readTextFileSync(Deno.env.get('EV_ANON_KEY_FILE')!).trim();
const PW = Deno.readTextFileSync(Deno.env.get('EV_PW_FILE')!).trim();
const EVENT = 'makers-halloween-2026';
const PUBLIC = 'https://example.test/functions/v1/event-valet';
const AUTH = 'test_auth_token_0123456789abcdef';
const ACCOUNT = 'ACtest0000000000000000000000000000';
const MG = 'MGtest0000000000000000000000000000';

const sh = { apikey: SERVICE, Authorization: `Bearer ${SERVICE}`, 'Content-Type': 'application/json' };
async function rest(path: string, init: RequestInit = {}) {
  const r = await fetch(`${SB}/rest/v1/${path}`, { ...init, headers: { ...sh, ...(init.headers ?? {}) } });
  const t = await r.text();
  return t ? JSON.parse(t) : null;
}
async function login(email: string) {
  const r = await fetch(`${SB}/auth/v1/token?grant_type=password`, {
    method: 'POST', headers: { apikey: ANON, 'Content-Type': 'application/json' }, body: JSON.stringify({ email, password: PW }),
  });
  return (await r.json()).access_token as string;
}
async function staffRpc(jwt: string, fn: string, args: Record<string, unknown>) {
  const r = await fetch(`${SB}/rest/v1/rpc/${fn}`, { method: 'POST', headers: { apikey: ANON, Authorization: `Bearer ${jwt}`, 'Content-Type': 'application/json' }, body: JSON.stringify(args) });
  return await r.json();
}
async function reset(settings: Record<string, unknown>) {
  await rest(`event_valet_messages?event_id=eq.${EVENT}`, { method: 'DELETE' });
  await rest(`event_valet_audit?event_id=eq.${EVENT}`, { method: 'DELETE' });
  await rest(`event_valet_tickets?event_id=eq.${EVENT}`, { method: 'DELETE' });
  await rest(`event_valet_events?id=eq.${EVENT}`, { method: 'PATCH', body: JSON.stringify({
    sms_enabled: true, sms_test_only: false, sms_test_phones: [], tip_enabled: true, include_ticket_link: true,
    tip_links: { '5': 'https://buy.stripe.com/test5', other: 'https://buy.stripe.com/testother' }, is_open: true, ...settings }) });
}
const env = (extra: Record<string, string> = {}) => (k: string) => ({
  SUPABASE_URL: SB, SUPABASE_SERVICE_ROLE_KEY: SERVICE, SUPABASE_ANON_KEY: ANON,
  EVENT_VALET_PUBLIC_URL: PUBLIC, EVENT_VALET_SITE_URL: 'https://airvalet.farberos.com',
  TWILIO_AUTH_TOKEN: AUTH, TWILIO_ACCOUNT_SID: ACCOUNT, TWILIO_MESSAGING_SERVICE_SID: MG, ...extra,
} as Record<string, string>)[k];

// Fake Twilio: records sends, answers like the Messages API (or fails on demand).
function fakeTwilio(behaviour: 'ok' | 'reject' | 'timeout' = 'ok') {
  const sent: { to: string; body: string; cb: string | null }[] = [];
  const f: typeof fetch = async (input, init) => {
    const url = String(input instanceof Request ? input.url : input);
    if (url.startsWith('https://api.twilio.com/')) {
      const form = new URLSearchParams(String(init?.body));
      if (behaviour === 'timeout') { const e = new Error('t'); e.name = 'TimeoutError'; throw e; }
      if (behaviour === 'reject') return new Response(JSON.stringify({ code: 21610, message: 'Attempt to send to unsubscribed recipient' }), { status: 400 });
      sent.push({ to: form.get('To')!, body: form.get('Body')!, cb: form.get('StatusCallback') });
      return new Response(JSON.stringify({ sid: 'SM' + crypto.randomUUID().replace(/-/g, ''), status: 'accepted' }), { status: 201 });
    }
    return fetch(input, init);
  };
  return { f, sent };
}
async function twilioPost(h: (r: Request) => Promise<Response>, path: string, params: Record<string, string>, opts: { badSig?: boolean; query?: string } = {}) {
  const q = opts.query ?? '';
  const sig = await computeSignature(opts.badSig ? 'wrong' : AUTH, `${PUBLIC}${path}${q}`, Object.entries(params));
  return await h(new Request(`http://localhost:9999/event-valet${path}${q}`, {
    method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded', 'X-Twilio-Signature': sig }, body: new URLSearchParams(params),
  }));
}
const inbound = (from: string, body: string, sid = 'SM' + crypto.randomUUID().replace(/-/g, '')) =>
  ({ MessageSid: sid, From: from, To: '+19545269800', Body: body, AccountSid: ACCOUNT, MessagingServiceSid: MG });
async function send(h: (r: Request) => Promise<Response>, jwt: string, body: Record<string, unknown>) {
  const r = await h(new Request('http://localhost:9999/event-valet/send', { method: 'POST', headers: { Authorization: `Bearer ${jwt}`, 'Content-Type': 'application/json' }, body: JSON.stringify(body) }));
  return { code: r.status, body: await r.json() };
}
const outMsgs = async (ticketId: string) => await rest(`event_valet_messages?ticket_id=eq.${ticketId}&direction=eq.OUT&order=id`);

// ── pure helpers ──
Deno.test('parseInbound', () => {
  assertEquals(parseInbound('READY'), { type: 'ready', ticketRef: null });
  assertEquals(parseInbound(' ready! '), { type: 'ready', ticketRef: null });
  assertEquals(parseInbound('Ready 0101'), { type: 'ready', ticketRef: '0101' });
  assertEquals(parseInbound('ready #0101-b'), { type: 'ready', ticketRef: '0101B' });
  assertEquals(parseInbound('READY 0101 please'), { type: 'ready', ticketRef: '0101' });
  assertEquals(parseInbound('#0101 ready'), { type: 'ready', ticketRef: '0101' });
  assertEquals(parseInbound('STOP'), { type: 'keyword' });
  assertEquals(parseInbound('help'), { type: 'keyword' });
  assertEquals(parseInbound('already there?'), { type: 'other' });
  assertEquals(parseInbound('thanks'), { type: 'other' });
});
Deno.test('normalizePhone', () => {
  assertEquals(normalizePhone('(954) 555-0101'), '+19545550101');
  assertEquals(normalizePhone('1 954 555 0101'), '+19545550101');
  assertEquals(normalizePhone('123'), null);
  assertEquals(normalizePhone('(054) 555-0101'), null);
});
Deno.test('templates: dynamic number, opt-out, link masked in storage', () => {
  const b = composeSms('CHECKIN', '0101', 'https://airvalet.farberos.com/events/x/t#abc');
  assert(b.includes('VALET TICKET: #0101') && b.includes('reply READY') && b.includes('Reply STOP to opt out.'));
  assert(!maskLink(b, 'https://airvalet.farberos.com/events/x/t#abc').includes('#abc'));
  assert(composeSms('REQUESTED', '0101-B', null).includes('Ticket #0101-B'));
  assert(composeSms('AMBIGUOUS', null, null, [{ code: '0500', vehicle: 'BMW' }]).includes('READY 0500 — BMW'));
  assert(composeSms('TIP', '0101', 'L').includes('optional tip'));
});

// ── integration ──
Deno.test('end-to-end: check-in SMS, READY, duplicate, delivered tip (once), guest link', async () => {
  await reset({});
  const jwt = await login('localipad@airvalet.local');
  const tw = fakeTwilio();
  const h = makeHandler(env(), tw.f);

  const c = await staffRpc(jwt, 'event_valet_checkin', { p_event: EVENT, p_phone: '9545550101', p_vehicle: 'Honda Civic', p_client_key: 'e2e1' });
  const tid = c.ticket.id;
  let s = await send(h, jwt, { ticket_id: tid, kind: 'CHECKIN' });
  assertEquals(s.code, 200); assertEquals(s.body.status, 'ACCEPTED');
  assertEquals(tw.sent.length, 1);
  assert(tw.sent[0].body.includes('#0101') && tw.sent[0].to === '+19545550101');
  assert(tw.sent[0].cb!.startsWith(`${PUBLIC}/status?mid=`));
  const link = tw.sent[0].body.match(/https:\/\/\S+#([0-9a-f]{64})/)!;
  // second CHECKIN for same ticket is deduped; RESEND sends
  s = await send(h, jwt, { ticket_id: tid, kind: 'CHECKIN' });
  assertEquals(s.body.status, 'DUPLICATE'); assertEquals(tw.sent.length, 1);
  s = await send(h, jwt, { ticket_id: tid, kind: 'CHECKIN', resend: true });
  assertEquals(s.body.status, 'ACCEPTED'); assertEquals(tw.sent.length, 2);
  // resend rotated the link → old token invalid, new one valid
  const newTok = tw.sent[1].body.match(/#([0-9a-f]{64})/)![1];
  let g = await (await h(new Request('http://x/event-valet/guest', { method: 'POST', body: JSON.stringify({ token: link[1], action: 'view' }) }))).json();
  assertEquals(g.state, 'invalid');
  g = await (await h(new Request('http://x/event-valet/guest', { method: 'POST', body: JSON.stringify({ token: newTok, action: 'view' }) }))).json();
  assertEquals(g.state, 'ok'); assertEquals(g.ticket_code, '0101'); assertEquals(g.status, 'PARKED');
  assert(!('slot_no' in g) && !('phone_e164' in g) && !('ticket_id' in g));
  // stored body never has the live token
  const stored = await outMsgs(tid);
  assert(stored.every((m: any) => !m.body || !/#[0-9a-f]{64}/.test(m.body)));

  // status callback updates the row
  const m0 = stored[0];
  let r = await twilioPost(h, '/status', { MessageSid: m0.twilio_sid, MessageStatus: 'delivered', AccountSid: ACCOUNT }, { query: `?mid=${m0.id}` });
  assertEquals(r.status, 204);
  assertEquals((await rest(`event_valet_messages?id=eq.${m0.id}`))[0].status, 'DELIVERED');

  // READY by SMS → REQUESTED + confirmation; repeat (Twilio retry, same SID) → nothing new
  const msg = inbound('+19545550101', 'Ready');
  r = await twilioPost(h, '/inbound', msg);
  assertEquals(r.status, 200); assert((await r.text()).includes('<Response>'));
  let t = (await rest(`event_valet_tickets?id=eq.${tid}`))[0];
  assertEquals(t.status, 'REQUESTED'); assertEquals(t.request_source, 'SMS');
  assertEquals(tw.sent.length, 3); assert(tw.sent[2].body.includes('Your vehicle has been requested') && tw.sent[2].body.includes('#0101'));
  await twilioPost(h, '/inbound', msg);
  await twilioPost(h, '/inbound', inbound('+19545550101', 'READY'));   // new SID, already requested
  assertEquals(tw.sent.length, 3);

  // guest link request when already requested → no change, no SMS
  g = await (await h(new Request('http://x/event-valet/guest', { method: 'POST', body: JSON.stringify({ token: newTok, action: 'request' }) }))).json();
  assertEquals(g.changed, false); assertEquals(tw.sent.length, 3);

  // TIP before delivery is refused
  s = await send(h, jwt, { ticket_id: tid, kind: 'TIP' });
  assertEquals(s.code, 409);
  // delivered → TIP once, even with repeated clicks
  await staffRpc(jwt, 'event_valet_set_status', { p_ticket: tid, p_status: 'DELIVERED' });
  for (let i = 0; i < 3; i++) await send(h, jwt, { ticket_id: tid, kind: 'TIP' });
  const tips = tw.sent.filter((x) => x.body.includes('optional tip'));
  assertEquals(tips.length, 1);
  const tipTok = tips[0].body.match(/#([0-9a-f]{64})/)![1];
  g = await (await h(new Request('http://x/event-valet/guest', { method: 'POST', body: JSON.stringify({ token: tipTok, action: 'view' }) }))).json();
  assertEquals(g.status, 'DELIVERED'); assertEquals(g.tip_links.other, 'https://buy.stripe.com/testother');
  // READY after delivery → no change, no SMS
  await twilioPost(h, '/inbound', inbound('+19545550101', 'READY'));
  assertEquals((await rest(`event_valet_tickets?id=eq.${tid}`))[0].status, 'DELIVERED');
  assertEquals(tw.sent.length, 4);
});

Deno.test('guest link request → REQUESTED + one confirmation SMS', async () => {
  await reset({});
  const jwt = await login('localipad@airvalet.local');
  const tw = fakeTwilio(); const h = makeHandler(env(), tw.f);
  const c = await staffRpc(jwt, 'event_valet_checkin', { p_event: EVENT, p_phone: '9545550102', p_vehicle: 'Tesla', p_client_key: 'g1' });
  await send(h, jwt, { ticket_id: c.ticket.id, kind: 'CHECKIN' });
  const tok = tw.sent[0].body.match(/#([0-9a-f]{64})/)![1];
  for (let i = 0; i < 2; i++) await h(new Request('http://x/event-valet/guest', { method: 'POST', body: JSON.stringify({ token: tok, action: 'request' }) }));
  const t = (await rest(`event_valet_tickets?id=eq.${c.ticket.id}`))[0];
  assertEquals(t.status, 'REQUESTED'); assertEquals(t.request_source, 'GUEST_LINK');
  assertEquals(tw.sent.filter((x) => x.body.includes('has been requested')).length, 1);
});

Deno.test('two cars on one phone: READY asks for ticket number; READY <n> requests only that car', async () => {
  await reset({});
  const jwt = await login('localipad@airvalet.local');
  const tw = fakeTwilio(); const h = makeHandler(env(), tw.f);
  const a = await staffRpc(jwt, 'event_valet_checkin', { p_event: EVENT, p_phone: '9545550500', p_vehicle: 'BMW', p_client_key: 'm1' });
  const b = await staffRpc(jwt, 'event_valet_checkin', { p_event: EVENT, p_phone: '9545550500', p_vehicle: 'Audi', p_client_key: 'm2' });
  await twilioPost(h, '/inbound', inbound('+19545550500', 'READY'));
  assertEquals(tw.sent.length, 1); assert(tw.sent[0].body.includes('more than one vehicle') && tw.sent[0].body.includes('READY 0500-B — AUDI'));
  for (const id of [a.ticket.id, b.ticket.id]) assertEquals((await rest(`event_valet_tickets?id=eq.${id}`))[0].status, 'PARKED');
  await twilioPost(h, '/inbound', inbound('+19545550500', `ready ${b.ticket.ticket_code}`));
  assertEquals((await rest(`event_valet_tickets?id=eq.${b.ticket.id}`))[0].status, 'REQUESTED');
  assertEquals((await rest(`event_valet_tickets?id=eq.${a.ticket.id}`))[0].status, 'PARKED');
  // another person's ticket number from this phone → NO_MATCH, nothing changes
  const other = await staffRpc(jwt, 'event_valet_checkin', { p_event: EVENT, p_phone: '9545550600', p_vehicle: 'Kia', p_client_key: 'm3' });
  await twilioPost(h, '/inbound', inbound('+19545550500', `READY ${other.ticket.ticket_code}`));
  assertEquals((await rest(`event_valet_tickets?id=eq.${other.ticket.id}`))[0].status, 'PARKED');
  assert(tw.sent.at(-1)!.body.includes('could not match'));
});

Deno.test('security: bad signature, unknown numbers, keywords, wrong service, non-staff', async () => {
  await reset({});
  const tw = fakeTwilio(); const h = makeHandler(env(), tw.f);
  const jwt = await login('localipad@airvalet.local');
  const c = await staffRpc(jwt, 'event_valet_checkin', { p_event: EVENT, p_phone: '9545550700', p_vehicle: 'Camry', p_client_key: 's1' });
  let r = await twilioPost(h, '/inbound', inbound('+19545550700', 'READY'), { badSig: true });
  assertEquals(r.status, 403);
  r = await twilioPost(h, '/inbound', { ...inbound('+19545550700', 'READY'), MessagingServiceSid: 'MGother' });
  assertEquals(r.status, 403);
  assertEquals((await rest(`event_valet_tickets?id=eq.${c.ticket.id}`))[0].status, 'PARKED');
  // unknown sender: no reply, nothing stored
  r = await twilioPost(h, '/inbound', inbound('+19545559999', 'READY'));
  assertEquals(r.status, 200); assertEquals(tw.sent.length, 0);
  assertEquals((await rest(`event_valet_messages?phone_e164=eq.%2B19545559999`)).length, 0);
  // STOP: ignored by us (Twilio Advanced Opt-Out handles it)
  await twilioPost(h, '/inbound', inbound('+19545550700', 'STOP'));
  assertEquals((await rest(`event_valet_tickets?id=eq.${c.ticket.id}`))[0].status, 'PARKED');
  // TV_ONLY and anon cannot use /send
  const tv = await login('localtv@airvalet.local');
  assertEquals((await send(h, tv, { ticket_id: c.ticket.id, kind: 'CHECKIN' })).code, 403);
  assertEquals((await send(h, ANON, { ticket_id: c.ticket.id, kind: 'CHECKIN' })).code, 403);
  // missing auth token → inbound refuses (fail closed)
  const h2 = makeHandler(env({ TWILIO_AUTH_TOKEN: '' }), tw.f);
  r = await twilioPost(h2, '/inbound', inbound('+19545550700', 'READY'));
  assertEquals(r.status, 503);
  assertEquals(tw.sent.length, 0);
});

Deno.test('safety switches: SMS off, test-only, tip off, not configured', async () => {
  const jwt = await login('localipad@airvalet.local');
  const tw = fakeTwilio();
  await reset({ sms_enabled: false });
  let h = makeHandler(env(), tw.f);
  let c = await staffRpc(jwt, 'event_valet_checkin', { p_event: EVENT, p_phone: '9545550801', p_vehicle: 'A', p_client_key: 'w1' });
  assertEquals((await send(h, jwt, { ticket_id: c.ticket.id, kind: 'CHECKIN' })).body.status, 'SKIPPED_SMS_OFF');
  await reset({ sms_test_only: true, sms_test_phones: ['+19545550802'] });
  c = await staffRpc(jwt, 'event_valet_checkin', { p_event: EVENT, p_phone: '9545550801', p_vehicle: 'A', p_client_key: 'w2' });
  assertEquals((await send(h, jwt, { ticket_id: c.ticket.id, kind: 'CHECKIN' })).body.status, 'SKIPPED_TEST_MODE');
  const c2 = await staffRpc(jwt, 'event_valet_checkin', { p_event: EVENT, p_phone: '9545550802', p_vehicle: 'B', p_client_key: 'w3' });
  assertEquals((await send(h, jwt, { ticket_id: c2.ticket.id, kind: 'CHECKIN' })).body.status, 'ACCEPTED');
  await reset({ tip_enabled: false });
  c = await staffRpc(jwt, 'event_valet_checkin', { p_event: EVENT, p_phone: '9545550803', p_vehicle: 'C', p_client_key: 'w4' });
  await staffRpc(jwt, 'event_valet_set_status', { p_ticket: c.ticket.id, p_status: 'DELIVERED' });
  assertEquals((await send(h, jwt, { ticket_id: c.ticket.id, kind: 'TIP' })).body.status, 'SKIPPED_TIP_OFF');
  h = makeHandler(env({ TWILIO_ACCOUNT_SID: '', TWILIO_AUTH_TOKEN: '' }), tw.f);
  c = await staffRpc(jwt, 'event_valet_checkin', { p_event: EVENT, p_phone: '9545550804', p_vehicle: 'D', p_client_key: 'w5' });
  assertEquals((await send(h, jwt, { ticket_id: c.ticket.id, kind: 'CHECKIN' })).body.status, 'NOT_CONFIGURED');
  // ticket creation never depends on SMS
  assertEquals((await rest(`event_valet_tickets?id=eq.${c.ticket.id}`))[0].status, 'PARKED');
});

Deno.test('Twilio failure: rejected → FAILED, timeout → UNCONFIRMED; ticket unaffected; resend later works', async () => {
  await reset({});
  const jwt = await login('localipad@airvalet.local');
  const c = await staffRpc(jwt, 'event_valet_checkin', { p_event: EVENT, p_phone: '9545550901', p_vehicle: 'Volvo', p_client_key: 'f1' });
  let s = await send(makeHandler(env(), fakeTwilio('reject').f), jwt, { ticket_id: c.ticket.id, kind: 'CHECKIN' });
  assertEquals(s.body.status, 'FAILED'); assertEquals(s.body.error_code, '21610');
  const c2 = await staffRpc(jwt, 'event_valet_checkin', { p_event: EVENT, p_phone: '9545550902', p_vehicle: 'Mini', p_client_key: 'f2' });
  s = await send(makeHandler(env(), fakeTwilio('timeout').f), jwt, { ticket_id: c2.ticket.id, kind: 'CHECKIN' });
  assertEquals(s.body.status, 'UNCONFIRMED');
  assertEquals((await rest(`event_valet_tickets?id=eq.${c.ticket.id}`))[0].status, 'PARKED');
  const ok = fakeTwilio();
  s = await send(makeHandler(env(), ok.f), jwt, { ticket_id: c.ticket.id, kind: 'CHECKIN', resend: true });
  assertEquals(s.body.status, 'ACCEPTED'); assertEquals(ok.sent.length, 1);
  await reset({ sms_enabled: false, sms_test_only: true, tip_enabled: false, tip_links: {} });
});

Deno.test('webhook URL key (no Auth Token): right key accepted, wrong/missing key refused', async () => {
  await reset({});
  const KEY = 'k'.repeat(20) + crypto.randomUUID().replace(/-/g, '');
  const tw = fakeTwilio();
  const h = makeHandler(env({ TWILIO_AUTH_TOKEN: '', TWILIO_API_KEY_SID: 'SKtest', TWILIO_API_KEY_SECRET: 'secret', EVENT_VALET_INBOUND_KEY: KEY }), tw.f);
  const jwt = await login('localipad@airvalet.local');
  const c = await staffRpc(jwt, 'event_valet_checkin', { p_event: EVENT, p_phone: '9545551201', p_vehicle: 'Lexus', p_client_key: 'uk1' });
  const s = await send(h, jwt, { ticket_id: c.ticket.id, kind: 'CHECKIN' });
  assertEquals(s.body.status, 'ACCEPTED');
  assert(tw.sent[0].cb!.includes(`&k=${KEY}`));
  let r = await twilioPost(h, '/inbound', inbound('+19545551201', 'READY'), { query: '?k=wrong' });
  assertEquals(r.status, 403);
  r = await twilioPost(h, '/inbound', inbound('+19545551201', 'READY'));
  assertEquals(r.status, 403);
  assertEquals((await rest(`event_valet_tickets?id=eq.${c.ticket.id}`))[0].status, 'PARKED');
  r = await twilioPost(h, '/inbound', { ...inbound('+19545551201', 'READY'), AccountSid: 'ACother' }, { query: `?k=${KEY}` });
  assertEquals(r.status, 403);
  r = await twilioPost(h, '/inbound', inbound('+19545551201', 'Ready'), { query: `?k=${KEY}` });
  assertEquals(r.status, 200);
  assertEquals((await rest(`event_valet_tickets?id=eq.${c.ticket.id}`))[0].status, 'REQUESTED');
  // short key is never accepted
  const h2 = makeHandler(env({ TWILIO_AUTH_TOKEN: '', EVENT_VALET_INBOUND_KEY: 'short' }), tw.f);
  assertEquals((await twilioPost(h2, '/inbound', inbound('+19545551201', 'READY'), { query: '?k=short' })).status, 503);
  await reset({ sms_enabled: false, sms_test_only: true, tip_enabled: false, tip_links: {} });
});

Deno.test('tip SMS uses the direct Stripe link when tip_links.sms is set; check-in without link', async () => {
  await reset({ include_ticket_link: false, tip_links: { sms: 'https://buy.stripe.com/8x214mccK0uh9TjgIM6Vq00', other: 'https://buy.stripe.com/8x214mccK0uh9TjgIM6Vq00' } });
  const jwt = await login('localipad@airvalet.local');
  const tw = fakeTwilio(); const h = makeHandler(env(), tw.f);
  const c = await staffRpc(jwt, 'event_valet_checkin', { p_event: EVENT, p_phone: '9545551301', p_vehicle: 'Mini', p_client_key: 'tl1' });
  await send(h, jwt, { ticket_id: c.ticket.id, kind: 'CHECKIN' });
  assert(!tw.sent[0].body.includes('http'));
  await staffRpc(jwt, 'event_valet_set_status', { p_ticket: c.ticket.id, p_status: 'DELIVERED' });
  await send(h, jwt, { ticket_id: c.ticket.id, kind: 'TIP' });
  assert(tw.sent[1].body.includes('\nhttps://buy.stripe.com/8x214mccK0uh9TjgIM6Vq00\n'));
  await reset({ sms_enabled: false, sms_test_only: true, tip_enabled: false, tip_links: {} });
});
