// deno test supabase/functions/_shared/sms/sms.test.ts
// deno-lint-ignore-file require-await
// Pure unit tests — no network, no database, no real Twilio credentials.
// All SIDs/tokens below are fake fixtures.
import { assert, assertEquals, assertFalse, assertStringIncludes } from 'jsr:@std/assert@1';
import twilio from 'npm:twilio@5'; // reference oracle for the signature algorithm only
import { maskPhone, normalizePhoneE164 } from './phone.ts';
import { countSegments, isGsm7, departureOperator, firstName, PassengerCtx, pickupPlace, renderMessage, returnLocation, Template, TemplateError, TEMPLATES } from './templates.ts';
import { computeTwilioSignature, isValidTwilioSignature } from './twilio-signature.ts';
import { MOCK_FAULTS, MockProvider, SendOutcome, TwilioProvider } from './provider.ts';
import { makeRedactor, sanitizeProviderText } from './sanitize.ts';
import { readSmsConfig } from './config.ts';
import { buildIdempotencyKey, PASS_TOKEN_MASK, ClaimArgs, ClaimRow, Passenger, ResultArgs, sendAirValetSms, SendDeps, SmsStore } from './service.ts';
import { classifyKeyword, handleInbound, handleStatusCallback, WebhookStore } from './webhooks.ts';
import { deviceKeyHash, staffLabel } from './device.ts';

const FAKE_TOKEN = 'test_auth_token_not_real_0000000';
const FAKE_AC = 'AC' + '0'.repeat(32);
const FAKE_SK = 'SK' + '1'.repeat(32);
const FAKE_MG = 'MG' + '2'.repeat(32);
const FAKE_SECRET = 'fake_api_key_secret_123456';
const FAKE_AUTH_HEX = 'f'.repeat(32); // shape of a Twilio Auth Token (config tests only)

// ── E.164 ────────────────────────────────────────────────────────────────
Deno.test('E.164: every real production phone shape normalizes', () => {
  for (const raw of ['3055550101', '(305) 555-0101', '(305)555-0101', '305 555-0101', '(305) 5550101', '1 305 555 0101', ' 305.555.0101 ']) {
    assertEquals(normalizePhoneE164(raw), { valid: true, e164: '+13055550101' }, raw);
  }
});
Deno.test('E.164: international kept only with +, never guessed', () => {
  assertEquals(normalizePhoneE164('+44 20 7946 0958'), { valid: true, e164: '+442079460958' });
  assertFalse(normalizePhoneE164('44 20 7946 0958').valid);
  assertFalse(normalizePhoneE164('+12').valid);
  assertFalse(normalizePhoneE164('+0123456789').valid);
});
Deno.test('E.164: invalid inputs rejected with a reason', () => {
  for (const raw of [null, undefined, '', '   ', '12345', '305555010', '23055550101', 'abc']) {
    const r = normalizePhoneE164(raw);
    assertFalse(r.valid, String(raw));
    assert(!r.valid && r.reason.length > 0);
  }
});
Deno.test('E.164: NANP area code / exchange sanity', () => {
  assertFalse(normalizePhoneE164('0055550101').valid);
  assertFalse(normalizePhoneE164('1055550101').valid);
  assertFalse(normalizePhoneE164('3050550101').valid);
});
Deno.test('maskPhone never shows the full number', () => {
  assertEquals(maskPhone('+13055550101'), '+1•••0101');
});

// ── Templates ────────────────────────────────────────────────────────────
const P = (o: Partial<PassengerCtx> = {}): PassengerCtx => ({
  name: 'ANA SOUZA', ticket: '0714-3', ret: '10/15', car: 'Escalade', status: 'PENDING',
  return_operator: null, delivery_at_customs: false, customs_exception_requested_at: null,
  delivery_type: null, customs_welcome_sent: false, tip_received: null, ...o,
});
const approve = (t: Template): Template => ({ ...t, status: 'APPROVED', version: 'test' });
const A: Record<string, Template> = Object.fromEntries(Object.entries(TEMPLATES).map(([k, t]) => [k, approve(t)]));
const codeOf = (fn: () => unknown) => { try { fn(); return 'none'; } catch (e) { return (e as TemplateError).code; } };
const PASS = 'https://airvalet.farberos.com/a#Ab3dE6gH9jK2mN4pQ'; // 17-char token in the #fragment
const ENV = { passUrl: PASS };
const seg = (b: string) => countSegments(b);

Deno.test('templates: only REPLY and the owner-approved CHECK_IN (D1) are APPROVED; every other template refuses', () => {
  assertEquals(Object.keys(TEMPLATES).sort(), ['AFTER_HOURS_CONFIRMED', 'CHECK_IN', 'CUSTOM_OPERATIONAL', 'REPLY', 'RETURN_CONFIRMATION', 'RETURN_UPDATED', 'VEHICLE_DELIVERED', 'VEHICLE_READY']);
  for (const t of Object.values(TEMPLATES)) {
    if (t.type === 'REPLY') { assertEquals(t.status, 'APPROVED'); assert(t.freeText); continue; }
    if (t.type === 'CHECK_IN') { assertEquals(t.status, 'APPROVED'); assertEquals(t.version, 'checkin-d1-2026-10-25'); continue; }
    assertEquals(t.status, 'PENDING_APPROVAL');
    assertEquals(codeOf(() => renderMessage(t, P({ status: 'DELIVERED', delivery_type: 'CUSTOMS', customs_welcome_sent: true, return_operator: 'MAKERS' }), ENV, 'x')), 'TEMPLATE_NOT_APPROVED');
  }
});
Deno.test('identity: every templated SMS names Makers Air (CHECK_IN D1 = "welcome to Makers Air!", others "Makers Air Valet:"), Ascend included', () => {
  const ci = renderMessage(A.CHECK_IN, P({ ticket: 'A-0714-1' }), ENV).body;
  assertStringIncludes(ci, 'welcome to Makers Air!'); assertFalse(ci.includes('Ascend'));
  const cases: Array<[string, PassengerCtx]> = [
    ['RETURN_CONFIRMATION', P({ ticket: 'A-1' })], ['RETURN_UPDATED', P({ ticket: 'A-1', ret: '10/31/2026', ret_time: '18:00' })], ['AFTER_HOURS_CONFIRMED', P({ ticket: 'A-1' })],
    ['VEHICLE_READY', P({ ticket: 'A-1', return_operator: 'ASCEND' })], ['VEHICLE_READY', P({ ticket: 'A-1', return_operator: 'MAKERS' })],
    ['VEHICLE_DELIVERED', P({ ticket: 'A-1', status: 'DELIVERED', delivery_type: 'NORMAL', tip_received: false })],
  ];
  for (const [t, p] of cases) {
    const b = renderMessage(A[t], p, ENV).body;
    assert(b.startsWith('Makers Air Valet: '), t);
    assertFalse(b.includes('Ascend Valet'), t);
  }
});
Deno.test('CHECK_IN D1: exact owner wording, real link, STOP line, ONE GSM-7 segment, no pickup instructions', () => {
  const b = renderMessage(A.CHECK_IN, P({ name: 'ANA SILVA' }), ENV).body;
  assertEquals(b, `Hi Ana, welcome to Makers Air! Your vehicle is checked in.\nYour valet pass: ${PASS}\nReply STOP to opt out.`);
  assertFalse(/Hangar|Customs|tip|gratuity/i.test(b));
  assertEquals(seg(b), 1);
  assertEquals(codeOf(() => renderMessage(A.CHECK_IN, P(), {})), 'PASS_LINK_MISSING');
});
Deno.test('CHECK_IN D1: long names shorten the wording first; the name is dropped only last', () => {
  const at = (n: string) => renderMessage(A.CHECK_IN, P({ name: n }), ENV).body;
  // up to 15 letters: exact owner wording
  assertStringIncludes(at('CHRISTOPHERSONN X'), 'Hi Christophersonn, welcome to Makers Air! Your vehicle is checked in.');
  // 16–19 letters: shorter wording, name kept
  const b16 = at('Maximilianusabcd'); assertStringIncludes(b16, 'Hi Maximilianusabcd,'); assertStringIncludes(b16, 'Your car is checked in.');
  // every name fits ONE segment, always with the link and the STOP line
  for (const n of ['A', 'Jo', 'John', 'Alexandria', 'Bartholomew', 'Maximilianusabcdefgh', 'Wolfeschlegelsteinhausen']) {
    const b = at(n); assertEquals(seg(b), 1, n); assertStringIncludes(b, PASS); assertStringIncludes(b, 'STOP to opt out');
  }
});
Deno.test('CHECK_IN D1: accents / emoji in names never switch the text to UCS-2', () => {
  for (const n of ['JOÃO', 'José', 'Zoë', 'Åsa', 'Łukasz', 'Ana😀', 'Nguyễn']) {
    const b = renderMessage(A.CHECK_IN, P({ name: n }), ENV).body;
    assertEquals(seg(b), 1, n);
    assert(Array.from(b).every((ch) => isGsm7(ch)), n);
  }
  assertStringIncludes(renderMessage(A.CHECK_IN, P({ name: 'JOÃO' }), ENV).body, 'Hi Joao,');
  assertStringIncludes(renderMessage(A.CHECK_IN, P({ name: 'José' }), ENV).body, 'Hi José,');
});
Deno.test('RETURN_UPDATED / AFTER_HOURS_CONFIRMED: one segment, no lockbox code, pending approval', () => {
  const tpl = { ...A.RETURN_UPDATED, status: 'APPROVED' as const, version: 't' };
  const b = renderMessage(tpl, P({ ret: '10/31/2026', ret_time: '18:00' }), ENV).body;
  assertEquals(b, 'Makers Air Valet: Your return is updated to Sat, Oct 31, 6:00 PM. Reply here if anything changes.');
  assertEquals(renderMessage(tpl, P({ ret: '10/31/2026', ret_time: null }), ENV).body, 'Makers Air Valet: Your return is updated to Sat, Oct 31. Reply here if anything changes.');
  const ah = renderMessage({ ...A.AFTER_HOURS_CONFIRMED, status: 'APPROVED' as const, version: 't' }, P(), ENV).body;
  assertEquals(seg(b), 1); assertEquals(seg(ah), 1); assertFalse(/\d{3,}/.test(ah));
  assertEquals(TEMPLATES.RETURN_UPDATED.status, 'PENDING_APPROVAL'); assertEquals(TEMPLATES.AFTER_HOURS_CONFIRMED.status, 'PENDING_APPROVAL');
});
// The four departure/return scenarios + unconfirmed (owner rule: pickup place
// comes from the RETURN flight only).
Deno.test('VEHICLE_READY scenario matrix (departure → return)', () => {
  const v = (ticket: string, ret: 'MAKERS' | 'ASCEND' | 'OTHER' | null) => {
    try { return renderMessage(A.VEHICLE_READY, P({ ticket, return_operator: ret }), ENV); } catch (e) { return { variant: (e as TemplateError).code, body: '' }; }
  };
  const mm = v('0714-3', 'MAKERS'); assertEquals(mm.variant, 'HANGAR19_WELCOME_BACK'); assertFalse(mm.body.includes('ready at Customs'));
  const aa = v('A-0714-1', 'ASCEND'); assertEquals(aa.variant, 'CUSTOMS_WELCOME'); assertFalse(aa.body.includes('Hangar 19'));
  const am = v('A-0714-1', 'MAKERS'); assertEquals(am.variant, 'HANGAR19_WELCOME_BACK'); assertFalse(am.body.includes('ready at Customs'));
  const ma = v('0714-3', 'ASCEND'); assertEquals(ma.variant, 'CUSTOMS_WELCOME'); assertFalse(ma.body.includes('Hangar 19'));
  // Key handoff follows the RETURN operation, not the departure ticket:
  assertEquals(ma.body, aa.body);
  assertEquals(am.body, mm.body);
  assertEquals(v('0714-3', 'OTHER').variant, 'RETURN_OTHER_MANUAL');   // Makers → Other: no instruction
  assertEquals(v('A-0714-1', 'OTHER').variant, 'RETURN_OTHER_MANUAL'); // Ascend → Other: no instruction
  assertEquals(v('0714-3', null).variant, 'RETURN_NOT_SET');
  assertEquals(codeOf(() => renderMessage(A.VEHICLE_READY, P({ status: 'DELIVERED', return_operator: 'MAKERS' }), ENV)), 'NOT_IN_CUSTODY');
});
// Makers return + Customs EXCEPTION (existing delivery_at_customs), approved case by case.
Deno.test('Makers Customs exception: 8 owner scenarios (template + pickup rules)', () => {
  const ready = (o: Partial<PassengerCtx>) => { try { return renderMessage(A.VEHICLE_READY, P(o), ENV); } catch (e) { return { variant: (e as TemplateError).code, body: '' }; } };
  // 1 Makers → Makers, no exception → Hangar 19
  assertEquals(pickupPlace(P({ return_operator: 'MAKERS' })), 'HANGAR_19');
  assertEquals(ready({ return_operator: 'MAKERS' }).variant, 'HANGAR19_WELCOME_BACK');
  // 2 requested, not approved → Hangar 19 stays; no definitive instruction sent
  const pend = { return_operator: 'MAKERS' as const, customs_exception_requested_at: '2026-10-09T15:00:00Z' };
  assertEquals(pickupPlace(P(pend)), 'HANGAR_19');
  assertEquals(ready(pend).variant, 'CUSTOMS_REQUEST_PENDING');
  // 3 approved → Customs, exception text (no key location, contact on arrival)
  const ok = ready({ return_operator: 'MAKERS', delivery_at_customs: true });
  assertEquals(pickupPlace(P({ return_operator: 'MAKERS', delivery_at_customs: true })), 'CUSTOMS');
  assertEquals(ok.variant, 'CUSTOMS_EXCEPTION'); assertStringIncludes(ok.body, 'As arranged'); assertStringIncludes(ok.body, '(954) 352-1010');
  assertEquals(seg(ok.body), 1);
  // 4 approved then revoked → Hangar 19
  assertEquals(ready({ return_operator: 'MAKERS', delivery_at_customs: false }).variant, 'HANGAR19_WELCOME_BACK');
  // 5 return changed to Ascend → Customs is the rule (Ascend handoff), not the exception
  const asc = ready({ return_operator: 'ASCEND' });
  assertEquals(asc.variant, 'CUSTOMS_WELCOME'); assertFalse(asc.body.includes('As arranged'));
  // 6 Ascend → Makers → Hangar 19 (DB resets the flag; template follows it)
  assertEquals(ready({ ticket: 'A-1', return_operator: 'MAKERS', delivery_at_customs: false }).variant, 'HANGAR19_WELCOME_BACK');
  // 7/8 are data rules (trigger) — covered in tests/sms/sql_tests.sql
  // Never presented as always available: no template mentions Customs for a
  // Makers return unless approved.
  for (const t of ['CHECK_IN', 'RETURN_CONFIRMATION']) assertFalse(/Customs/.test(renderMessage(A[t], P({ return_operator: 'MAKERS' }), ENV).body), t);
});
Deno.test('ready idempotency key follows the instruction variant (exception ≠ Ascend Customs ≠ Hangar 19)', () => {
  const k = (o: Partial<PassengerCtx>) => TEMPLATES.VEHICLE_READY.defaultEventRef!(new Date(), P(o));
  assertEquals(k({ return_operator: 'MAKERS' }), 'ready:HANGAR19_WELCOME_BACK');
  assertEquals(k({ return_operator: 'MAKERS', delivery_at_customs: true }), 'ready:CUSTOMS_EXCEPTION');
  assertEquals(k({ return_operator: 'ASCEND' }), 'ready:CUSTOMS_WELCOME');
});
Deno.test('security: no SMS ever states where a key is left', () => {
  const bodies: string[] = [];
  for (const dep of ['0714-3', 'A-0714-1']) {
    for (const ret of ['MAKERS', 'ASCEND', 'OTHER', null] as const) {
      for (const [t, extra] of [
        ['CHECK_IN', {}], ['RETURN_CONFIRMATION', {}], ['VEHICLE_READY', {}], ['VEHICLE_READY', { delivery_at_customs: true }],
        ['VEHICLE_DELIVERED', { status: 'DELIVERED', delivery_type: 'NORMAL', tip_received: false }],
        ['VEHICLE_DELIVERED', { status: 'DELIVERED', delivery_type: 'LOCKBOX', tip_received: true }],
      ] as Array<[string, Partial<PassengerCtx>]>) {
        try { bodies.push(renderMessage(A[t], P({ ticket: dep, return_operator: ret, ...extra }), ENV).body); } catch { /* refused = nothing sent */ }
      }
    }
  }
  assert(bodies.length > 20);
  for (const b of bodies) assertFalse(/tire|key is (on|in|under|at)|keys? (left|placed|located)|lockbox code|driver.?s.?side/i.test(b), b);
});
Deno.test('return location derived from the return operator only', () => {
  assertEquals(returnLocation('MAKERS'), 'HANGAR_19'); assertEquals(returnLocation('ASCEND'), 'CUSTOMS');
  assertEquals(returnLocation('OTHER'), null); assertEquals(returnLocation(null), null);
  assertEquals(departureOperator('A-0714-1'), 'ASCEND'); assertEquals(departureOperator('0714-3'), 'MAKERS'); assertEquals(departureOperator(null), 'MAKERS');
});
Deno.test('VEHICLE_DELIVERED: one plain confirmation, never a gratuity / tip link; no Customs gratuity type', () => {
  assertEquals(codeOf(() => renderMessage(A.VEHICLE_DELIVERED, P(), ENV)), 'NOT_DELIVERED');
  const bodies = [
    renderMessage(A.VEHICLE_DELIVERED, P({ status: 'DELIVERED', delivery_type: 'NORMAL', tip_received: true }), ENV),
    renderMessage(A.VEHICLE_DELIVERED, P({ status: 'DELIVERED', delivery_type: 'LOCKBOX', tip_received: false }), ENV),
    renderMessage(A.VEHICLE_DELIVERED, P({ status: 'DELIVERED', delivery_type: 'CUSTOMS' }), ENV),
  ];
  for (const b of bodies) {
    assertEquals(b.variant, 'DELIVERED');
    assertFalse(/https?:|www\.|stripe|gratuity|tip\b|generosity/i.test(b.body), b.body);
  }
  assertEquals(new Set(bodies.map((b) => b.body)).size, 1);
  assertFalse('CUSTOMS_GRATUITY' in TEMPLATES);
});
Deno.test('RETURN_CONFIRMATION: asks Makers Air or Ascend while the return is unconfirmed (1 segment)', () => {
  const ask = renderMessage(A.RETURN_CONFIRMATION, P({ name: 'CHRISTOPHER LONGNAME' }), ENV);
  assertEquals(ask.variant, 'RETURN_CONFIRMATION_OPERATOR'); assertStringIncludes(ask.body, 'Makers Air or Ascend'); assertEquals(seg(ask.body), 1);
  const known = renderMessage(A.RETURN_CONFIRMATION, P({ return_operator: 'MAKERS' }), ENV);
  assertStringIncludes(known.body, 'Hi Ana,'); assertEquals(seg(known.body), 1);
  assertEquals(codeOf(() => renderMessage(A.RETURN_CONFIRMATION, P({ status: 'DELIVERED' }), ENV)), 'NOT_IN_CUSTODY');
  assertEquals(firstName('JOHN\nCLICK evil'), 'John');
});
Deno.test('segment budget per message (cost guard) and GSM-7 only', () => {
  const budget: Array<[string, PassengerCtx, number]> = [
    ['CHECK_IN', P(), 2],
    ['RETURN_CONFIRMATION', P({ name: 'MAXIMILIANA' }), 1],
    ['VEHICLE_READY', P({ return_operator: 'MAKERS' }), 2],
    ['VEHICLE_READY', P({ ticket: 'A-1', return_operator: 'ASCEND' }), 1],
    ['VEHICLE_READY', P({ return_operator: 'ASCEND' }), 1],
    ['VEHICLE_DELIVERED', P({ status: 'DELIVERED', delivery_type: 'NORMAL', tip_received: true }), 1],
    ['VEHICLE_DELIVERED', P({ status: 'DELIVERED', delivery_type: 'NORMAL', tip_received: false }), 1],
  ];
  for (const [t, p, max] of budget) {
    const { body, variant } = renderMessage(A[t], p, ENV);
    // countSegments() falls back to UCS-2 math for any non-GSM char; equal
    // to the GSM-7 count proves the body is pure GSM-7.
    const gsm = body.length <= 160 ? 1 : Math.ceil(body.length / 153);
    assertEquals(seg(body), gsm, `${variant} has non-GSM-7 characters`);
    assert(seg(body) <= max, `${variant}: ${seg(body)} segments > budget ${max} (${body.length} chars)`);
  }
});
Deno.test('free text (REPLY): empty / too long refused', () => {
  assertEquals(renderMessage(TEMPLATES.REPLY, P(), ENV, ' Your car is ready ').body, 'Your car is ready');
  assertEquals(codeOf(() => renderMessage(TEMPLATES.REPLY, P(), ENV, '   ')), 'EMPTY_BODY');
  assertEquals(codeOf(() => renderMessage(TEMPLATES.REPLY, P(), ENV, 'x'.repeat(481))), 'BODY_TOO_LONG');
});
Deno.test('segments: GSM-7 vs UCS-2', () => {
  assertEquals(countSegments('x'.repeat(160)), 1);
  assertEquals(countSegments('x'.repeat(161)), 2);
  assertEquals(countSegments('€'.repeat(80)), 1); // extension chars cost 2
  assertEquals(countSegments('✈ ' + 'x'.repeat(60)), 1);
  assertEquals(countSegments('✈ ' + 'x'.repeat(80)), 2);
});

// ── Signature ────────────────────────────────────────────────────────────
Deno.test('signature: matches the official Twilio SDK (oracle), incl. query string', async () => {
  const url = 'https://example.supabase.co/functions/v1/twilio-status-callback?env=test';
  const params = { MessageSid: 'SM' + 'a'.repeat(32), MessageStatus: 'delivered', AccountSid: FAKE_AC, MessagingServiceSid: FAKE_MG, ErrorCode: '' };
  const ours = await computeTwilioSignature(FAKE_TOKEN, url, Object.entries(params));
  assert(twilio.validateRequest(FAKE_TOKEN, ours, url, params));
  assert(await isValidTwilioSignature(FAKE_TOKEN, url, Object.entries(params), ours));
});
Deno.test('signature: wrong token, tampered param, wrong URL, missing header all fail closed', async () => {
  const url = 'https://example.supabase.co/functions/v1/twilio-inbound';
  const p: [string, string][] = [['Body', 'hi'], ['From', '+13055550101']];
  const sig = await computeTwilioSignature(FAKE_TOKEN, url, p);
  assertFalse(await isValidTwilioSignature('other_token_000000', url, p, sig));
  assertFalse(await isValidTwilioSignature(FAKE_TOKEN, url, [['Body', 'hi!'], ['From', '+13055550101']], sig));
  assertFalse(await isValidTwilioSignature(FAKE_TOKEN, url + '?x=1', p, sig));
  assertFalse(await isValidTwilioSignature(FAKE_TOKEN, url, p, null));
  assertFalse(await isValidTwilioSignature(undefined, url, p, sig));
});

// ── Provider (fake fetch; never the network) ────────────────────────────
function fakeFetch(status: number, body: unknown, seen: Request[] = []): typeof fetch {
  return ((input: string | URL | Request, init?: RequestInit) => {
    seen.push(new Request(input, init));
    return Promise.resolve(new Response(JSON.stringify(body), { status }));
  }) as typeof fetch;
}
const cfg = { accountSid: FAKE_AC, apiKeySid: FAKE_SK, apiKeySecret: FAKE_SECRET, messagingServiceSid: FAKE_MG, timeoutMs: 50 };

Deno.test('provider: request uses API key + Messaging Service + StatusCallback, no From', async () => {
  const seen: Request[] = [];
  const p = new TwilioProvider(cfg, fakeFetch(201, { sid: 'SM' + 'b'.repeat(32), status: 'queued', messaging_service_sid: FAKE_MG }, seen));
  const out = await p.send({ to: '+13055550101', body: 'hi', statusCallbackUrl: 'https://x/cb' });
  assertEquals(out, { kind: 'accepted', sid: 'SM' + 'b'.repeat(32), status: 'queued', messagingServiceSid: FAKE_MG });
  const req = seen[0];
  assertEquals(req.url, `https://api.twilio.com/2010-04-01/Accounts/${FAKE_AC}/Messages.json`);
  assertEquals(req.headers.get('authorization'), 'Basic ' + btoa(`${FAKE_SK}:${FAKE_SECRET}`));
  const form = new URLSearchParams(await req.text());
  assertEquals(form.get('MessagingServiceSid'), FAKE_MG);
  assertEquals(form.get('StatusCallback'), 'https://x/cb');
  assertEquals(form.get('From'), null);
  assertEquals(form.get('ValidityPeriod'), '3600'); // stale operational texts are dropped, not delivered late
});
Deno.test('provider: 4xx → rejected, 429 → throttled, 5xx → unknown, timeout → unknown', async () => {
  assertEquals((await new TwilioProvider(cfg, fakeFetch(400, { code: 21211, message: "The 'To' number +13055550101 is not valid" })).send({ to: '+1', body: 'x' })),
    { kind: 'rejected', errorCode: '21211', errorMessage: "The 'To' number [phone] is not valid" });
  assertEquals((await new TwilioProvider(cfg, fakeFetch(429, { code: 20429, message: 'Too Many Requests' })).send({ to: '+1', body: 'x' })).kind, 'throttled');
  assertEquals((await new TwilioProvider(cfg, fakeFetch(503, {})).send({ to: '+1', body: 'x' })).kind, 'unknown');
  const hang = ((_i: unknown, init?: RequestInit) => new Promise((_r, rej) => init?.signal?.addEventListener('abort', () => rej(new DOMException('aborted', 'AbortError'))))) as typeof fetch;
  assertEquals(await new TwilioProvider(cfg, hang).send({ to: '+1', body: 'x' }), { kind: 'unknown', errorCode: 'TIMEOUT', errorMessage: 'no response within 50 ms' });
  const boom = (() => Promise.reject(new TypeError('connection reset'))) as typeof fetch;
  assertEquals((await new TwilioProvider(cfg, boom).send({ to: '+1', body: 'x' })).kind, 'unknown');
});

// ── Sanitization ─────────────────────────────────────────────────────────
Deno.test('sanitize: SIDs, auth headers, phones and exact secrets are redacted', () => {
  const s = sanitizeProviderText(`acct ${FAKE_AC} key ${FAKE_SK} Basic ${btoa('a:b'.repeat(5))} to +1 (305) 555-0101`);
  assertFalse(s.includes(FAKE_AC)); assertFalse(s.includes(FAKE_SK)); assertFalse(s.includes('555-0101'));
  const redact = makeRedactor([FAKE_TOKEN, FAKE_SECRET]);
  assertEquals(redact(`token=${FAKE_TOKEN} secret=${FAKE_SECRET}`), 'token=[secret] secret=[secret]');
});

// ── Config ───────────────────────────────────────────────────────────────
Deno.test('config: default is disabled; real modes need complete config', () => {
  assertEquals(readSmsConfig(() => undefined).mode, 'disabled');
  assertEquals(readSmsConfig((k) => ({ AIRVALET_SMS_MODE: 'live' } as Record<string, string>)[k]).mode, 'disabled');
  assertEquals(readSmsConfig((k) => ({ AIRVALET_SMS_MODE: 'LIVE!!' } as Record<string, string>)[k]).mode, 'disabled');
  assertEquals(readSmsConfig((k) => ({ AIRVALET_SMS_MODE: 'mock' } as Record<string, string>)[k]).mode, 'mock');
  const full: Record<string, string> = {
    AIRVALET_SMS_MODE: 'allowlist', AIRVALET_SMS_TEST_ALLOWLIST: '(305) 555-0101, junk',
    AIRVALET_SMS_PUBLIC_FUNCTIONS_URL: 'https://example.supabase.co/functions/v1/',
    TWILIO_ACCOUNT_SID: FAKE_AC, TWILIO_API_KEY_SID: FAKE_SK, TWILIO_API_KEY_SECRET: FAKE_SECRET, TWILIO_MESSAGING_SERVICE_SID: FAKE_MG,
    TWILIO_AUTH_TOKEN: FAKE_AUTH_HEX,
  };
  const c = readSmsConfig((k) => full[k]);
  assertEquals(c.mode, 'allowlist'); assert(c.webhookReady);
  assertEquals(c.allowlist, ['+13055550101']);
  assertEquals(c.publicFunctionsUrl, 'https://example.supabase.co/functions/v1');
  assertEquals(readSmsConfig((k) => ({ ...full, AIRVALET_SMS_TEST_ALLOWLIST: '' })[k]).mode, 'disabled');
});
Deno.test('config: allowlist/live REQUIRE the Auth Token + public URL (webhooks must verify signatures)', () => {
  const base: Record<string, string> = {
    AIRVALET_SMS_MODE: 'live', AIRVALET_SMS_PUBLIC_FUNCTIONS_URL: 'https://example.supabase.co/functions/v1',
    TWILIO_ACCOUNT_SID: FAKE_AC, TWILIO_API_KEY_SID: FAKE_SK, TWILIO_API_KEY_SECRET: FAKE_SECRET, TWILIO_MESSAGING_SERVICE_SID: FAKE_MG,
    TWILIO_AUTH_TOKEN: FAKE_AUTH_HEX,
  };
  assertEquals(readSmsConfig((k) => base[k]).mode, 'live');
  for (const drop of ['TWILIO_AUTH_TOKEN', 'AIRVALET_SMS_PUBLIC_FUNCTIONS_URL', 'TWILIO_MESSAGING_SERVICE_SID']) {
    const c = readSmsConfig((k) => (k === drop ? undefined : base[k]));
    assertEquals(c.mode, 'disabled', drop); assertFalse(c.webhookReady, drop);
  }
  assertEquals(readSmsConfig((k) => ({ ...base, TWILIO_AUTH_TOKEN: 'short' })[k]).mode, 'disabled');
  assertEquals(readSmsConfig((k) => ({ ...base, AIRVALET_SMS_PUBLIC_FUNCTIONS_URL: 'http://plain.example/functions/v1' })[k]).mode, 'disabled');
  // http://localhost only for the local mock stack — never for allowlist/live
  const local: Record<string, string> = { ...base, AIRVALET_SMS_PUBLIC_FUNCTIONS_URL: 'http://127.0.0.1:55331/functions/v1' };
  assertEquals(readSmsConfig((k) => local[k]).mode, 'disabled');
  assertFalse(readSmsConfig((k) => local[k]).webhookReady);
  assert(readSmsConfig((k) => ({ ...local, AIRVALET_SMS_MODE: 'mock' } as Record<string, string>)[k]).webhookReady);
  assertFalse(readSmsConfig((k) => ({ ...local, AIRVALET_SMS_MODE: 'mock', AIRVALET_SMS_PUBLIC_FUNCTIONS_URL: 'http://evil.example/functions/v1' } as Record<string, string>)[k]).webhookReady);
});

// ── Service (in-memory store with the same claim semantics as the SQL) ──
class MemStore implements SmsStore {
  rows = new Map<string, { id: string; key: string; status: string; sid: string | null; error_code: string | null; phone: string }>();
  optOuts = new Set<string>();
  passengers = new Map<number, Passenger>();
  failOn: string | null = null;
  results: ResultArgs[] = [];
  claims: ClaimArgs[] = [];
  noConsent = new Set<string>();
  async getPassenger(id: number) { if (this.failOn === 'get') throw new Error('db down'); return this.passengers.get(id) ?? null; }
  async claim(a: ClaimArgs): Promise<ClaimRow> {
    await Promise.resolve(); // yield, so concurrent callers interleave like real requests
    if (this.failOn === 'claim') throw new Error('db down');
    this.claims.push(a);
    const ex = [...this.rows.values()].find((r) => r.key === a.idempotencyKey);
    if (ex) return { message_id: ex.id, claimed: false, status: ex.status, provider_message_sid: ex.sid, error_code: ex.error_code };
    const blocked = this.optOuts.has(a.phoneE164) ? 'OPTED_OUT' : this.noConsent.has(a.phoneE164) ? 'NO_CONSENT' : null;
    const row = { id: crypto.randomUUID(), key: a.idempotencyKey, status: blocked ? 'blocked' : 'pending', sid: null, error_code: blocked, phone: a.phoneE164 };
    this.rows.set(row.id, row);
    return { message_id: row.id, claimed: !blocked, status: row.status, provider_message_sid: null, error_code: blocked };
  }
  async markResult(a: ResultArgs) {
    if (this.failOn === 'mark') throw new Error('db down');
    this.results.push(a);
    const r = this.rows.get(a.messageId)!;
    if (r.status === 'pending' || r.status === 'send_unknown') { r.status = a.status; r.sid = a.sid; r.error_code = a.errorCode; }
    return r.status;
  }
  async markOptedOut(p: string) { this.optOuts.add(p); }
  passLinks = new Map<number, string>();   // passenger → ACTIVE token (a new mint rotates)
  mints = 0;
  reconciles = 0;
  async reconcile() { this.reconciles += 1; return 0; }
  closed = new Set<number>();              // services no longer open → mint returns null
  async mintPassLink(id: number) {
    if (this.closed.has(id)) return null;
    this.mints += 1;
    const t = 'Tk' + String(this.mints).padStart(5, '0') + String(id).padStart(10, '0'); // 17 chars
    this.passLinks.set(id, t);
    return t;
  }
}

function setup(script: ConstructorParameters<typeof MockProvider>[0] = [], over: Partial<SendDeps> = {}) {
  const store = new MemStore();
  store.passengers.set(1001, { id: 1001, phone: '(305) 555-0101', ...P() });
  store.passengers.set(1002, { id: 1002, phone: '305 555-0202', ...P({ name: 'BO', ticket: 'A-0714-1' }) });
  store.passengers.set(1003, { id: 1003, phone: '12345', ...P({ name: 'CY', ticket: '0714-9' }) });
  store.passengers.set(1004, { id: 1004, phone: '3055550404', ...P({ name: 'DAN', status: 'DELIVERED', delivery_type: 'CUSTOMS', customs_welcome_sent: false }) });
  store.passengers.set(1005, { id: 1005, phone: '3055550505', ...P({ name: 'EVE', ticket: 'A-0901-1', return_operator: 'MAKERS' }) });
  const provider = new MockProvider(script);
  const logs: string[] = [];
  const deps: SendDeps = { mode: 'live', store, provider, allowlist: [], templates: A, passBaseUrl: 'https://airvalet.farberos.com/a#', sleep: () => Promise.resolve(), log: (e, d) => logs.push(e + JSON.stringify(d)), ...over };
  return { store, provider, deps, logs };
}
const ops = { userId: 'u1', role: 'IPAD_OPS' as const, name: 'Valet Ana' };
const mgr = { userId: 'm1', role: 'MANAGER' as const, name: 'Manager Bia' };

Deno.test('service: happy path → one provider call, queued, SID + staff name stored', async () => {
  const { deps, provider, store } = setup();
  const r = await sendAirValetSms(deps, { passengerId: 1001, type: 'CHECK_IN', actor: ops });
  assertEquals(r.ok, true); assertEquals(r.status, 'queued'); assert(r.sid?.startsWith('SMMOCK'));
  assertEquals(provider.calls.length, 1);
  assertEquals(provider.calls[0].to, '+13055550101');
  assert(provider.calls[0].body.startsWith('Hi '));
  assertStringIncludes(provider.calls[0].body, 'welcome to Makers Air! Your vehicle is checked in.\nYour valet pass: https://airvalet.farberos.com/a#');
  assertEquals(countSegments(provider.calls[0].body), 1); // owner D1: one GSM-7 segment with the real link
  const tok = store.passLinks.get(1001)!;
  assertEquals(tok.length, 17);
  assertStringIncludes(provider.calls[0].body, 'https://airvalet.farberos.com/a#' + tok + '\nReply STOP to opt out.');
  // The SMS log never holds the token: same-length GSM-7 mask, same segments.
  assertStringIncludes(store.claims[0].body, 'https://airvalet.farberos.com/a#' + PASS_TOKEN_MASK + '\nReply STOP');
  assertFalse(store.claims[0].body.includes(tok));
  assertEquals(store.claims[0].body.length, provider.calls[0].body.length);
  assertEquals(store.claims[0].segments, 1);
  const row = [...store.rows.values()][0];
  assertEquals(row.key, buildIdempotencyKey(1001, 'CHECK_IN', 'checkin'));
  assertEquals(store.claims[0].templateKey, 'CHECK_IN_D1');
  assertEquals(store.claims[0].sentByName, 'Valet Ana');
});
Deno.test('service: Ascend departure still identified as Makers Air Valet; a resend rotates the link', async () => {
  const { deps, provider, store } = setup();
  await sendAirValetSms(deps, { passengerId: 1002, type: 'CHECK_IN', actor: ops });
  const first = store.passLinks.get(1002)!;
  await sendAirValetSms(deps, { passengerId: 1002, type: 'CHECK_IN', eventRef: 'resend:7f1c0a2b', actor: mgr });
  assertStringIncludes(provider.calls[0].body, 'welcome to Makers Air!'); assertFalse(provider.calls[0].body.includes('Ascend'));
  assertEquals(store.mints, 2);
  assert(store.passLinks.get(1002) !== first);
  assertStringIncludes(provider.calls[1].body, store.passLinks.get(1002)!);
});
Deno.test('service: duplicate / blocked requests never mint or rotate a link', async () => {
  const { deps, provider, store } = setup();
  await sendAirValetSms(deps, { passengerId: 1001, type: 'CHECK_IN', actor: ops });
  const tok = store.passLinks.get(1001);
  assertEquals((await sendAirValetSms(deps, { passengerId: 1001, type: 'CHECK_IN', actor: ops })).duplicate, true);
  assertEquals(store.mints, 1); assertEquals(store.passLinks.get(1001), tok);
  store.noConsent.add('+13055550202');
  assertEquals((await sendAirValetSms(deps, { passengerId: 1002, type: 'CHECK_IN', actor: ops })).status, 'blocked');
  assertEquals(store.mints, 1); assertEquals(provider.calls.length, 1);
});
Deno.test('service: service already closed → no link, message failed, nothing reaches the provider', async () => {
  const { deps, provider, store } = setup();
  store.closed.add(1001);
  const r = await sendAirValetSms(deps, { passengerId: 1001, type: 'CHECK_IN', actor: ops });
  assertEquals(r.error?.code, 'PASS_LINK_UNAVAILABLE');
  assertEquals(provider.calls.length, 0);
  assertEquals(store.results[0].status, 'failed');
});
Deno.test('service: VEHICLE_READY refused while return unconfirmed; mixed trip uses the RETURN flight', async () => {
  const { deps, provider } = setup();
  assertEquals((await sendAirValetSms(deps, { passengerId: 1001, type: 'VEHICLE_READY', actor: ops })).error?.code, 'RETURN_NOT_SET');
  await sendAirValetSms(deps, { passengerId: 1005, type: 'VEHICLE_READY', actor: ops }); // Ascend out, Makers back
  assertStringIncludes(provider.calls[0].body, 'Hangar 19');
  assertEquals(provider.calls.length, 1);
});
Deno.test('service: mid-trip return change → corrected VEHICLE_READY allowed once; same place dedups; OTHER refused', async () => {
  const { deps, provider, store } = setup();
  const p = store.passengers.get(1005)!; // departed Ascend, returning Makers
  await sendAirValetSms(deps, { passengerId: 1005, type: 'VEHICLE_READY', actor: ops });
  assertStringIncludes(provider.calls[0].body, 'Hangar 19');
  assertEquals((await sendAirValetSms(deps, { passengerId: 1005, type: 'VEHICLE_READY', actor: ops })).duplicate, true);
  p.return_operator = 'ASCEND'; // passenger now flying back with Ascend
  const corrected = await sendAirValetSms(deps, { passengerId: 1005, type: 'VEHICLE_READY', actor: ops });
  assert(corrected.ok && !corrected.duplicate);
  assertStringIncludes(provider.calls[1].body, 'ready at Customs');
  assertFalse(provider.calls[1].body.includes('Hangar 19'));
  p.return_operator = 'OTHER';
  assertEquals((await sendAirValetSms(deps, { passengerId: 1005, type: 'VEHICLE_READY', actor: ops })).error?.code, 'RETURN_OTHER_MANUAL');
  assertEquals(provider.calls.length, 2);
});
Deno.test('service: OTHER return still allows return-date question and free replies (no pickup text)', async () => {
  const { deps, provider, store } = setup();
  store.passengers.get(1001)!.return_operator = 'OTHER';
  await sendAirValetSms(deps, { passengerId: 1001, type: 'RETURN_CONFIRMATION', actor: ops });
  assertFalse(/Hangar|Customs|Makers Air or Ascend/.test(provider.calls[0].body));
  assert((await sendAirValetSms(deps, { passengerId: 1001, type: 'REPLY', eventRef: 'reply:x1', customBody: 'We will meet you, call us when you land.', actor: ops })).ok);
});
Deno.test('service: refused sends never mint a passenger link', async () => {
  const { deps, store } = setup();
  await sendAirValetSms({ ...deps, mode: 'disabled' }, { passengerId: 1001, type: 'CHECK_IN', actor: ops });
  store.noConsent.add('+13055550101');
  await sendAirValetSms(deps, { passengerId: 1001, type: 'CHECK_IN', actor: ops });
  assertEquals(store.passLinks.size, 0);
});
Deno.test('service: RETURN_CONFIRMATION at most once per day (date event ref)', async () => {
  const { deps, provider } = setup([], { now: () => new Date('2026-10-09T15:00:00Z') });
  await sendAirValetSms(deps, { passengerId: 1001, type: 'RETURN_CONFIRMATION', actor: ops });
  const again = await sendAirValetSms(deps, { passengerId: 1001, type: 'RETURN_CONFIRMATION', actor: ops });
  assertEquals(again.duplicate, true);
  await sendAirValetSms({ ...deps, now: () => new Date('2026-10-10T15:00:00Z') }, { passengerId: 1001, type: 'RETURN_CONFIRMATION', actor: ops });
  assertEquals(provider.calls.length, 2);
});
Deno.test('service: REPLY needs a compose id; same id twice → sent once', async () => {
  const { deps, provider } = setup();
  assertEquals((await sendAirValetSms(deps, { passengerId: 1001, type: 'REPLY', customBody: 'On our way', actor: ops })).error?.code, 'INVALID_EVENT_REF');
  const a = await sendAirValetSms(deps, { passengerId: 1001, type: 'REPLY', eventRef: 'reply:5b1e', customBody: 'On our way', actor: ops });
  const b = await sendAirValetSms(deps, { passengerId: 1001, type: 'REPLY', eventRef: 'reply:5b1e', customBody: 'On our way', actor: ops });
  assert(a.ok); assertEquals(b.duplicate, true); assertEquals(provider.calls.length, 1);
  assertEquals(provider.calls[0].body, 'On our way');
});
Deno.test('service: double click / retry → second call does NOT reach Twilio', async () => {
  const { deps, provider } = setup();
  const a = await sendAirValetSms(deps, { passengerId: 1001, type: 'CHECK_IN', actor: ops });
  const b = await sendAirValetSms(deps, { passengerId: 1001, type: 'CHECK_IN', actor: ops });
  assertEquals(provider.calls.length, 1);
  assertEquals(b.duplicate, true); assertEquals(b.messageId, a.messageId); assertEquals(b.sid, a.sid);
});
Deno.test('service: 5 simultaneous taps → exactly one send', async () => {
  const { deps, provider } = setup();
  const rs = await Promise.all(Array.from({ length: 5 }, () => sendAirValetSms(deps, { passengerId: 1001, type: 'CHECK_IN', actor: ops })));
  assertEquals(provider.calls.length, 1);
  assertEquals(rs.filter((r) => r.duplicate).length, 4);
});
Deno.test('service: explicit resend is a MANAGER/ADMIN action with resend:<id>; staff cannot force duplicates', async () => {
  const { deps, provider } = setup();
  await sendAirValetSms(deps, { passengerId: 1001, type: 'CHECK_IN', actor: ops });
  assertEquals((await sendAirValetSms(deps, { passengerId: 1001, type: 'CHECK_IN', eventRef: 'resend:7f1c0a2b', actor: ops })).error?.code, 'RESEND_NOT_ALLOWED');
  assertEquals((await sendAirValetSms(deps, { passengerId: 1001, type: 'CHECK_IN', eventRef: 'checkin2', actor: mgr })).error?.code, 'RESEND_NOT_ALLOWED');
  assertEquals(provider.calls.length, 1);
  await sendAirValetSms(deps, { passengerId: 1001, type: 'CHECK_IN', eventRef: 'resend:7f1c0a2b', actor: mgr });
  assertEquals(provider.calls.length, 2);
});
Deno.test('service: duplicate of an UNCONFIRMED send is NOT reported as sent (ok:false, UNCONFIRMED)', async () => {
  const { deps, provider } = setup([{ kind: 'unknown', errorCode: 'TIMEOUT', errorMessage: 't' }]);
  await sendAirValetSms(deps, { passengerId: 1001, type: 'CHECK_IN', actor: ops });
  const again = await sendAirValetSms(deps, { passengerId: 1001, type: 'CHECK_IN', actor: ops });
  assertEquals(again.ok, false); assertEquals(again.duplicate, true);
  assertEquals(again.status, 'send_unknown'); assertEquals(again.error?.code, 'UNCONFIRMED');
  assertEquals(provider.calls.length, 1);
});
Deno.test('service: StatusCallback carries ?mid=<message id> (lets a timed-out send be reconciled); reconcile runs on every call', async () => {
  const { deps, provider, store } = setup([], { statusCallbackUrl: 'https://example.supabase.co/functions/v1/twilio-status-callback' });
  const r = await sendAirValetSms(deps, { passengerId: 1001, type: 'CHECK_IN', actor: ops });
  assertEquals(provider.calls[0].statusCallbackUrl, 'https://example.supabase.co/functions/v1/twilio-status-callback?mid=' + r.messageId);
  assertEquals(store.reconciles, 1);
});
Deno.test('service: free text — max 3 segments (emoji count), links only to our domains', async () => {
  const { deps, provider } = setup();
  const send = (body: string, ref: string) => sendAirValetSms(deps, { passengerId: 1001, type: 'REPLY', eventRef: ref, customBody: body, actor: ops });
  assertEquals((await send('Hi 😀 '.repeat(40), 'reply:e1')).error?.code, 'BODY_TOO_LONG');           // UCS-2 → > 3 segments
  assertEquals((await send('Pay here: https://evil.example/pay', 'reply:l1')).error?.code, 'LINK_NOT_ALLOWED');
  assertEquals((await send('see bit.ly/abc', 'reply:l2')).error?.code, 'LINK_NOT_ALLOWED');
  assert((await send('Your details: https://airvalet.farberos.com/a#x and airvalet.farberos.com/sms.html', 'reply:ok1')).ok);
  assert((await send('Call us at (954) 352-1010, thank you.', 'reply:ok2')).ok);
  assertEquals(provider.calls.length, 2);
});
Deno.test('service: removed gratuity type is rejected outright', async () => {
  const { deps, provider } = setup();
  assertEquals((await sendAirValetSms(deps, { passengerId: 1004, type: 'CUSTOMS_GRATUITY', actor: ops })).error?.code, 'INVALID_TYPE');
  assertEquals(provider.calls.length, 0);
});
Deno.test('service: disabled mode / unapproved template / invalid phone / forbidden role never call Twilio', async () => {
  const { deps, provider, store } = setup();
  assertEquals((await sendAirValetSms({ ...deps, mode: 'disabled' }, { passengerId: 1001, type: 'CHECK_IN', actor: ops })).error?.code, 'SMS_DISABLED');
  assertEquals((await sendAirValetSms({ ...deps, templates: undefined }, { passengerId: 1001, type: 'RETURN_CONFIRMATION', actor: ops })).error?.code, 'TEMPLATE_NOT_APPROVED');
  assertEquals((await sendAirValetSms(deps, { passengerId: 1003, type: 'CHECK_IN', actor: ops })).error?.code, 'INVALID_PHONE');
  assertEquals((await sendAirValetSms(deps, { passengerId: 1001, type: 'CHECK_IN', actor: { userId: 'tv', role: 'TV_ONLY' } })).error?.code, 'FORBIDDEN');
  assertEquals((await sendAirValetSms(deps, { passengerId: 1001, type: 'CUSTOM_OPERATIONAL', eventRef: 'c1', customBody: 'x', actor: ops })).error?.code, 'FORBIDDEN');
  assertEquals((await sendAirValetSms(deps, { passengerId: 1001, type: 'CUSTOM_OPERATIONAL', customBody: 'x', actor: { userId: 'm', role: 'MANAGER' } })).error?.code, 'INVALID_EVENT_REF');
  assertEquals((await sendAirValetSms(deps, { passengerId: 9999, type: 'CHECK_IN', actor: ops })).error?.code, 'PASSENGER_NOT_FOUND');
  assertEquals((await sendAirValetSms(deps, { passengerId: 1001, type: 'DROP TABLE', actor: ops })).error?.code, 'INVALID_TYPE');
  assertEquals((await sendAirValetSms(deps, { passengerId: 1001, type: '__proto__', actor: ops })).error?.code, 'INVALID_TYPE');
  assertEquals((await sendAirValetSms(deps, { passengerId: 1001, type: 'CHECK_IN', eventRef: 'x y', actor: ops })).error?.code, 'INVALID_EVENT_REF');
  assertEquals(provider.calls.length, 0);
  assertEquals(store.rows.size, 0);
});
Deno.test('service: no recorded opt-in → blocked NO_CONSENT, Twilio never called', async () => {
  const { deps, provider, store } = setup();
  store.noConsent.add('+13055550101');
  const r = await sendAirValetSms(deps, { passengerId: 1001, type: 'CHECK_IN', actor: ops });
  assertEquals(r.status, 'blocked'); assertEquals(r.error?.code, 'NO_CONSENT');
  assertEquals(provider.calls.length, 0);
});
Deno.test('service: allowlist mode only reaches allowlisted numbers', async () => {
  const { deps, provider } = setup([], { mode: 'allowlist', allowlist: ['+13055550202'] });
  assertEquals((await sendAirValetSms(deps, { passengerId: 1001, type: 'CHECK_IN', actor: ops })).error?.code, 'NOT_ALLOWLISTED');
  assertEquals((await sendAirValetSms(deps, { passengerId: 1002, type: 'CHECK_IN', actor: ops })).ok, true);
  assertEquals(provider.calls.map((c) => c.to), ['+13055550202']);
});
Deno.test('service: 429 is retried (definitely not sent), then succeeds', async () => {
  const thr: SendOutcome = { kind: 'throttled', errorCode: '20429', errorMessage: 'slow down' };
  const { deps, provider, store } = setup([thr]);
  const r = await sendAirValetSms(deps, { passengerId: 1001, type: 'CHECK_IN', actor: ops });
  assertEquals(r.ok, true); assertEquals(provider.calls.length, 2); assertEquals(store.results[0].attempts, 2);
});
Deno.test('service: persistent 429 → failed after 3 attempts', async () => {
  const thr: SendOutcome = { kind: 'throttled', errorCode: '20429', errorMessage: 'slow down' };
  const { deps, provider } = setup([thr, thr, thr, thr]);
  const r = await sendAirValetSms(deps, { passengerId: 1001, type: 'CHECK_IN', actor: ops });
  assertEquals(r.status, 'failed'); assertEquals(provider.calls.length, 3);
});
Deno.test('service: timeout → send_unknown, NOT retried, and a retry request does not resend', async () => {
  const { deps, provider } = setup([{ kind: 'unknown', errorCode: 'TIMEOUT', errorMessage: 't' }]);
  const r = await sendAirValetSms(deps, { passengerId: 1001, type: 'CHECK_IN', actor: ops });
  assertEquals(r.status, 'send_unknown'); assertEquals(r.ok, false);
  const again = await sendAirValetSms(deps, { passengerId: 1001, type: 'CHECK_IN', actor: ops });
  assertEquals(again.duplicate, true);
  assertEquals(provider.calls.length, 1);
});
Deno.test('service: Twilio rejection → failed with sanitized code; 21610 records opt-out', async () => {
  const { deps, store } = setup([{ kind: 'rejected', errorCode: '21610', errorMessage: 'unsubscribed' }]);
  const r = await sendAirValetSms(deps, { passengerId: 1001, type: 'CHECK_IN', actor: ops });
  assertEquals(r.status, 'failed'); assertEquals(r.error?.code, '21610');
  assert(store.optOuts.has('+13055550101'));
  const next = await sendAirValetSms(deps, { passengerId: 1001, type: 'RETURN_CONFIRMATION', actor: ops });
  assertEquals(next.status, 'blocked'); assertEquals(next.error?.code, 'OPTED_OUT');
});
Deno.test('service: NEVER throws — DB down, provider crash, DB down after claim', async () => {
  for (const failOn of ['get', 'claim', 'mark']) {
    const { deps, store } = setup();
    store.failOn = failOn;
    const r = await sendAirValetSms(deps, { passengerId: 1001, type: 'CHECK_IN', actor: ops });
    assertEquals(r.ok, false); assertEquals(r.status, 'error');
  }
  const { deps, store } = setup([() => Promise.reject(new Error('sdk crash'))]);
  const r = await sendAirValetSms(deps, { passengerId: 1001, type: 'CHECK_IN', actor: ops });
  assertEquals(r.status, 'error');
  assertEquals([...store.rows.values()][0].status, 'send_unknown'); // claimed row left clearly marked
});
Deno.test('service: logs carry no phone, body or secret', async () => {
  const { deps, logs } = setup([{ kind: 'rejected', errorCode: '21211', errorMessage: 'bad' }]);
  await sendAirValetSms(deps, { passengerId: 1001, type: 'CHECK_IN', actor: ops });
  await sendAirValetSms(deps, { passengerId: 1001, type: 'CHECK_IN', actor: ops });
  const all = logs.join('\n');
  assertFalse(all.includes('555')); assertFalse(all.includes('checked in')); assertFalse(all.includes('Tok0')); assertFalse(all.includes(FAKE_SECRET));
});

// ── Webhooks ─────────────────────────────────────────────────────────────
const STATUS_URL = 'https://example.supabase.co/functions/v1/twilio-status-callback';
const INBOUND_URL = 'https://example.supabase.co/functions/v1/twilio-inbound';
const SID = 'SM' + 'c'.repeat(32);

class MemWebhookStore implements WebhookStore {
  statuses: string[] = [];
  inbound: Array<{ from: string; keyword: string | null }> = [];
  fail = false;
  mids: Array<string | null> = [];
  async applyStatus(sid: string, status: string, _c: string | null, _m: string | null, mid: string | null) {
    if (this.fail) throw new Error('db'); this.statuses.push(`${sid}:${status}`); this.mids.push(mid); return 'applied';
  }
  async recordInbound(_sid: string, from: string, _b: string, _m: string | null, keyword: 'STOP' | 'START' | 'HELP' | null) {
    if (this.fail) throw new Error('db');
    this.inbound.push({ from, keyword });
    return { message_id: 'm', inserted: true, passenger_id: 1, match_method: 'last_outbound' };
  }
}
async function signedReq(url: string, params: Record<string, string>, token = FAKE_TOKEN, internalUrl = 'http://edge-runtime.internal/twilio' + new URL(url).search) {
  const sig = await computeTwilioSignature(token, url, Object.entries(params));
  return new Request(internalUrl, { method: 'POST', headers: { 'content-type': 'application/x-www-form-urlencoded', 'x-twilio-signature': sig }, body: new URLSearchParams(params) });
}

Deno.test('status webhook: valid signature (public URL, not internal) → applied 204', async () => {
  const store = new MemWebhookStore();
  const res = await handleStatusCallback({ authToken: FAKE_TOKEN, publicUrl: STATUS_URL, store, expectedMessagingServiceSid: FAKE_MG },
    await signedReq(STATUS_URL, { MessageSid: SID, MessageStatus: 'delivered', MessagingServiceSid: FAKE_MG }));
  assertEquals(res.status, 204); assertEquals(store.statuses, [`${SID}:delivered`]);
});
Deno.test('status webhook: forged / unsigned / wrong token → 403, nothing stored', async () => {
  const store = new MemWebhookStore();
  const deps = { authToken: FAKE_TOKEN, publicUrl: STATUS_URL, store, expectedMessagingServiceSid: FAKE_MG };
  assertEquals((await handleStatusCallback(deps, await signedReq(STATUS_URL, { MessageSid: SID, MessageStatus: 'delivered' }, 'attacker_token_000'))).status, 403);
  const unsigned = new Request(STATUS_URL, { method: 'POST', headers: { 'content-type': 'application/x-www-form-urlencoded' }, body: 'MessageSid=' + SID + '&MessageStatus=delivered' });
  assertEquals((await handleStatusCallback(deps, unsigned)).status, 403);
  assertEquals((await handleStatusCallback({ ...deps, authToken: undefined }, await signedReq(STATUS_URL, { MessageSid: SID, MessageStatus: 'sent' }))).status, 403);
  assertEquals(store.statuses.length, 0);
});
Deno.test('status webhook: other Messaging Service (e.g. FarberOS) ignored; junk status ignored', async () => {
  const store = new MemWebhookStore();
  const deps = { authToken: FAKE_TOKEN, publicUrl: STATUS_URL, store, expectedMessagingServiceSid: FAKE_MG };
  assertEquals((await handleStatusCallback(deps, await signedReq(STATUS_URL, { MessageSid: SID, MessageStatus: 'delivered', MessagingServiceSid: 'MG' + '9'.repeat(32) }))).status, 200);
  assertEquals((await handleStatusCallback(deps, await signedReq(STATUS_URL, { MessageSid: SID, MessageStatus: 'hacked' }))).status, 200);
  assertEquals((await handleStatusCallback(deps, await signedReq(STATUS_URL, { MessageSid: 'not-a-sid', MessageStatus: 'sent' }))).status, 200);
  assertEquals(store.statuses.length, 0);
});
Deno.test('status webhook: all 5 Twilio statuses accepted; DB error → 503 so Twilio retries', async () => {
  const store = new MemWebhookStore();
  for (const s of ['queued', 'sent', 'delivered', 'undelivered', 'failed']) {
    assertEquals((await handleStatusCallback({ authToken: FAKE_TOKEN, publicUrl: STATUS_URL, store, expectedMessagingServiceSid: FAKE_MG }, await signedReq(STATUS_URL, { MessageSid: SID, MessageStatus: s, MessagingServiceSid: FAKE_MG }))).status, 204);
  }
  assertEquals(store.statuses.length, 5);
  store.fail = true;
  assertEquals((await handleStatusCallback({ authToken: FAKE_TOKEN, publicUrl: STATUS_URL, store, expectedMessagingServiceSid: FAKE_MG }, await signedReq(STATUS_URL, { MessageSid: SID, MessageStatus: 'sent', MessagingServiceSid: FAKE_MG }))).status, 503);
});
Deno.test('status webhook: signed ?mid= is passed through (unconfirmed send adopts its SID); junk mid ignored; no service SID configured → nothing accepted', async () => {
  const store = new MemWebhookStore();
  const deps = { authToken: FAKE_TOKEN, publicUrl: STATUS_URL, store, expectedMessagingServiceSid: FAKE_MG };
  const mid = '6f1c2a3b-1111-4222-8333-944455556666';
  const withMid = STATUS_URL + '?mid=' + mid;
  assertEquals((await handleStatusCallback(deps, await signedReq(withMid, { MessageSid: SID, MessageStatus: 'sent', MessagingServiceSid: FAKE_MG }))).status, 204);
  assertEquals((await handleStatusCallback(deps, await signedReq(STATUS_URL + '?mid=x%27or1', { MessageSid: SID, MessageStatus: 'delivered', MessagingServiceSid: FAKE_MG }))).status, 204);
  assertEquals(store.mids, [mid, null]);
  // the mid is inside the signed URL: changing it breaks the signature
  const tampered = await signedReq(withMid, { MessageSid: SID, MessageStatus: 'failed', MessagingServiceSid: FAKE_MG }, FAKE_TOKEN, 'http://edge-runtime.internal/twilio?mid=00000000-0000-4000-8000-000000000000');
  assertEquals((await handleStatusCallback(deps, tampered)).status, 403);
  const before = store.statuses.length;
  assertEquals((await handleStatusCallback({ ...deps, expectedMessagingServiceSid: undefined }, await signedReq(STATUS_URL, { MessageSid: SID, MessageStatus: 'sent', MessagingServiceSid: FAKE_MG }))).status, 200);
  assertEquals(store.statuses.length, before);
});
Deno.test('status webhook: GET and wrong content type refused', async () => {
  const deps = { authToken: FAKE_TOKEN, publicUrl: STATUS_URL, store: new MemWebhookStore(), expectedMessagingServiceSid: FAKE_MG };
  assertEquals((await handleStatusCallback(deps, new Request(STATUS_URL))).status, 405);
  assertEquals((await handleStatusCallback(deps, new Request(STATUS_URL, { method: 'POST', headers: { 'content-type': 'application/json' }, body: '{}' }))).status, 415);
});
Deno.test('inbound webhook: reply stored with E.164 sender, empty TwiML back', async () => {
  const store = new MemWebhookStore();
  const res = await handleInbound({ authToken: FAKE_TOKEN, publicUrl: INBOUND_URL, store, expectedMessagingServiceSid: FAKE_MG },
    await signedReq(INBOUND_URL, { MessageSid: SID, From: '+13055550101', To: '+17865550000', Body: 'Back Friday 3pm', MessagingServiceSid: FAKE_MG }));
  assertEquals(res.status, 200); assertStringIncludes(await res.text(), '<Response></Response>');
  assertEquals(store.inbound, [{ from: '+13055550101', keyword: null }]);
});
Deno.test('inbound webhook: STOP/START/HELP classified; "yes" is not an opt-in', () => {
  assertEquals(classifyKeyword('stop', null), 'STOP');
  assertEquals(classifyKeyword(' Unsubscribe. ', null), 'STOP');
  assertEquals(classifyKeyword('anything', 'STOP'), 'STOP');
  assertEquals(classifyKeyword('START', null), 'START');
  assertEquals(classifyKeyword('help', null), 'HELP');
  assertEquals(classifyKeyword('yes', null), null);
  assertEquals(classifyKeyword('please stop by at 3', null), null);
});
Deno.test('inbound: a conversational "Yes" is NEVER consent — even when Twilio labels it OptOutType=START', () => {
  for (const b of ['Yes', 'yes!', 'YES', 'Yes, Friday 3pm', 'yep', 'ok', 'Sure']) {
    assertEquals(classifyKeyword(b, 'START'), null, b);
    assertEquals(classifyKeyword(b, null), null, b);
  }
  assertEquals(classifyKeyword('START', 'START'), 'START');
  assertEquals(classifyKeyword('unstop', null), 'START');
  assertEquals(classifyKeyword('Stop!', null), 'STOP');     // opting out stays generous
  assertEquals(classifyKeyword('cancel', 'STOP'), 'STOP');
});
Deno.test('inbound webhook: "Yes" reply stored as a normal message (no keyword) even if Twilio says START', async () => {
  const store = new MemWebhookStore();
  await handleInbound({ authToken: FAKE_TOKEN, publicUrl: INBOUND_URL, store, expectedMessagingServiceSid: FAKE_MG },
    await signedReq(INBOUND_URL, { MessageSid: SID, From: '+13055550101', Body: 'Yes', OptOutType: 'START', MessagingServiceSid: FAKE_MG }));
  assertEquals(store.inbound, [{ from: '+13055550101', keyword: null }]);
});
Deno.test('inbound webhook: forged request refused', async () => {
  const store = new MemWebhookStore();
  const res = await handleInbound({ authToken: FAKE_TOKEN, publicUrl: INBOUND_URL, store, expectedMessagingServiceSid: FAKE_MG }, await signedReq(INBOUND_URL, { MessageSid: SID, From: '+13055550101', Body: 'STOP' }, 'attacker_token_000'));
  assertEquals(res.status, 403); assertEquals(store.inbound.length, 0);
});

Deno.test('no Twilio secret value is hard-coded in the SMS sources', async () => {
  const dir = new URL('.', import.meta.url);
  for await (const f of Deno.readDir(dir)) {
    if (!f.name.endsWith('.ts') || f.name.endsWith('.test.ts')) continue;
    const src = await Deno.readTextFile(new URL(f.name, dir));
    assertFalse(/\bAC[0-9a-f]{32}\b/i.test(src), f.name);
    assertFalse(/\bSK[0-9a-f]{32}\b/i.test(src), f.name);
    assertFalse(/\bMG[0-9a-f]{32}\b/i.test(src), f.name);
  }
});

Deno.test('service: PENDING_APPROVAL wording runs only in mock mode; allowlist/live still refuse it', async () => {
  const { deps, provider } = setup();
  assertEquals((await sendAirValetSms({ ...deps, mode: 'live', templates: undefined }, { passengerId: 1001, type: 'RETURN_CONFIRMATION', actor: ops })).error?.code, 'TEMPLATE_NOT_APPROVED');
  assertEquals((await sendAirValetSms({ ...deps, mode: 'allowlist', allowlist: ['+13055550101'], templates: undefined }, { passengerId: 1001, type: 'RETURN_CONFIRMATION', actor: ops })).error?.code, 'TEMPLATE_NOT_APPROVED');
  assertEquals(provider.calls.length, 0);
  const mock = new MockProvider();
  const r = await sendAirValetSms({ ...deps, mode: 'mock', provider: mock, templates: undefined }, { passengerId: 1001, type: 'RETURN_CONFIRMATION', actor: ops });
  assertEquals(r.ok, true);
  assertEquals(mock.calls.length, 1);
  assertEquals(mock.calls[0].body.startsWith('Makers Air Valet:'), true);
});
Deno.test('mock provider: SIDs are unique across instances (one per Edge Function call) and match the Twilio SID shape', async () => {
  const sids = new Set<string>();
  for (let i = 0; i < 50; i++) {
    const o = await new MockProvider().send({ to: '+13055550101', body: 'x' });
    if (o.kind !== 'accepted') throw new Error('expected accepted');
    assert(/^SM[0-9a-zA-Z]{32}$/.test(o.sid), o.sid);
    sids.add(o.sid);
  }
  assertEquals(sids.size, 50);
});

// ── Device authorization (shared logins → approved devices) ─────────────
Deno.test('device: key → SHA-256 hex (same rule as SQL); malformed keys give NO device', async () => {
  const k = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJ_-0123456789';
  const h = await deviceKeyHash(k);
  assert(/^[0-9a-f]{64}$/.test(h!));
  assertEquals(await deviceKeyHash(k), h); // deterministic
  for (const bad of [null, undefined, '', 'short', 'x'.repeat(42), 'x'.repeat(129), 'has space ' + 'x'.repeat(40), "quote'" + 'x'.repeat(40)]) {
    assertEquals(await deviceKeyHash(bad as string), null, String(bad));
  }
});
Deno.test('device: staff label is a trimmed 60-char label; junk → null', () => {
  assertEquals(staffLabel('  Ana  '), 'Ana');
  assertEquals(staffLabel('x'.repeat(80))!.length, 60);
  assertEquals(staffLabel('A\u0000na\n'), 'Ana');
  assertEquals(staffLabel(''), null); assertEquals(staffLabel(42), null); assertEquals(staffLabel(null), null);
});
Deno.test('device: the device hash and the UI-picked name reach the claim unchanged', async () => {
  const { deps, store } = setup();
  const dev = (await deviceKeyHash('d'.repeat(43)))!;
  await sendAirValetSms(deps, { passengerId: 1001, type: 'CHECK_IN', actor: { ...ops, name: 'Picked Bo' }, deviceKeyHash: dev });
  assertEquals(store.claims.at(-1)!.deviceKeyHash, dev);
  assertEquals(store.claims.at(-1)!.sentByName, 'Picked Bo');
  await sendAirValetSms(deps, { passengerId: 1002, type: 'CHECK_IN', actor: ops });
  assertEquals(store.claims.at(-1)!.deviceKeyHash, null); // no device → the DB refuses (DEVICE_NOT_AUTHORIZED)
});

Deno.test('mock provider: reserved fictional numbers simulate Twilio failures (mock only)', async () => {
  const m = new MockProvider();
  assertEquals((await m.send({ to: '+13055550199', body: 'x' })).kind, 'rejected');
  assertEquals((await m.send({ to: '+13055550198', body: 'x' })).kind, 'unknown');
  assertEquals((await m.send({ to: '+13055550101', body: 'x' })).kind, 'accepted');
  assertEquals(Object.keys(MOCK_FAULTS).every((n) => /^\+1305555019[89]$/.test(n)), true);
});
Deno.test('service: Twilio rejection → failed (definitely not sent); timeout → send_unknown (never "failed")', async () => {
  const { deps, store } = setup();
  store.passengers.set(1099, { id: 1099, phone: '(305) 555-0199', ...P({ name: 'REJ', ticket: 'R-1' }) });
  store.passengers.set(1098, { id: 1098, phone: '(305) 555-0198', ...P({ name: 'TMO', ticket: 'T-1' }) });
  const r1 = await sendAirValetSms(deps, { passengerId: 1099, type: 'CHECK_IN', actor: ops });
  const r2 = await sendAirValetSms(deps, { passengerId: 1098, type: 'CHECK_IN', actor: ops });
  assertEquals([r1.status, r1.error?.code], ['failed', '30006']);
  assertEquals(r2.status, 'send_unknown');
});
