// deno test --allow-env supabase/functions/_shared/notify/notify.test.ts
import { assert, assertEquals, assertFalse, assertStringIncludes } from 'jsr:@std/assert@1';
import { adminSmsBody, notifyEvent, pushPayload, toGsm7 } from './notify.ts';
import { adminSmsProvider, readVapid } from './runtime.ts';
import { countSegments, isGsm7 } from '../sms/templates.ts';
import { MockProvider } from '../sms/provider.ts';
import { readSmsConfig } from '../sms/config.ts';
import { previewAirValetSms, type SendDeps, type SmsStore } from '../sms/service.ts';

const D = (over: Record<string, unknown> = {}) => ({
  kind: 'GUEST_MESSAGE' as const, passenger_id: 7, phone_e164: '+13055550142', name: 'John Smith', ticket: '1025-2',
  text: 'Hi, my flight is delayed, landing around 6pm', ...over,
});
const APP = 'https://airvalet.farberos.com';

Deno.test('admin SMS copy: compact owner format, one GSM-7 segment, login link', () => {
  const b = adminSmsBody(D(), APP);
  assertEquals(b, 'AIRVALET MESSAGE\nGuest: John Smith\nTicket: 1025-2\nMsg: Hi, my flight is delayed, landing around 6pm\nOpen: https://airvalet.farberos.com/#messages');
  assertEquals(countSegments(b), 1);
  assertFalse(b.includes('+1305'));
});
Deno.test('admin SMS copy: long or emoji texts are cut to ONE segment and stay GSM-7', () => {
  for (const text of ['x'.repeat(600), 'Landing late 😀🛬 please wait — thanks “a lot”', 'Olá, chegarei às 18h, avião atrasado ' + 'muito '.repeat(40)]) {
    const b = adminSmsBody(D({ text }), APP);
    assertEquals(countSegments(b), 1, text.slice(0, 20));
    assert(Array.from(b).every(isGsm7));
    assertStringIncludes(b, 'Open: https://airvalet.farberos.com/#messages');
  }
  assertStringIncludes(adminSmsBody(D({ text: 'y'.repeat(300) }), APP), '...');
  assertEquals(adminSmsBody(D({ kind: 'PASS_REQUEST', text: 'Return change to Oct 31 06:00 PM' }), APP).split('\n')[0], 'AIRVALET REQUEST');
});
Deno.test('toGsm7 keeps GSM letters, transliterates the rest, drops emoji', () => {
  assertEquals(toGsm7('José João 😀 ok'), 'José Joao  ok');
  assert(Array.from(toGsm7('Ñandú “quotes” — dash')).every(isGsm7));
});
Deno.test('push payload: lock screen shows no name or text unless the device enabled previews', () => {
  const priv = pushPayload(D(), false);
  assertEquals(priv.title, 'NEW GUEST MESSAGE');
  assertEquals(priv.body, 'Ticket #1025-2 · Tap to read');
  assertFalse(priv.body.includes('John')); assertFalse(priv.body.includes('delayed'));
  const full = pushPayload(D(), true);
  assertStringIncludes(full.body, 'John Smith - Ticket #1025-2'); assertStringIncludes(full.body, 'delayed');
  assertEquals(full.url, '/#messages');
});

// Fake service-role db for notifyEvent.
function fakeDb(opts: { adminPhone?: string | null; targets?: number; claimOnce?: boolean } = {}) {
  const calls: Array<[string, Record<string, unknown>]> = [];
  const claimed = new Set<string>();
  const db = {
    rpc(fn: string, args: Record<string, unknown>) {
      calls.push([fn, args]);
      let data: unknown = null;
      if (fn === 'airvalet_notify_details') data = D();
      if (fn === 'airvalet_notify_claim') { const k = String(args.p_dedupe_key); data = !claimed.has(k); claimed.add(k); }
      if (fn === 'airvalet_push_targets') data = Array.from({ length: opts.targets ?? 0 }, (_, i) => ({ id: `s${i}`, endpoint: `https://push.example/${i}`, p256dh: 'x', auth: 'y', show_preview: i === 0 }));
      if (fn === 'airvalet_admin_alert_claim') { const k = String(args.p_dedupe_key); data = claimed.has(k) ? null : (claimed.add(k), opts.adminPhone ?? null); }
      return Promise.resolve({ data, error: null });
    },
  };
  return { db, calls };
}
const VAPID = { privateJwk: {} as JsonWebKey, publicKey: 'k', subject: 'mailto:x@y.z' };

Deno.test('notifyEvent: push to every target once; admin SMS once; a repeat of the same event notifies nobody', async () => {
  const { db, calls } = fakeDb({ adminPhone: '+17545550101', targets: 2 });
  const sms = new MockProvider();
  const pushed: Array<{ body: string }> = [];
  const deps = { db, vapid: VAPID, adminProvider: sms, appUrl: APP,
    pushImpl: (_s: unknown, data: unknown) => { pushed.push(data as { body: string }); return Promise.resolve({ ok: true, status: 201, gone: false }); } };
  const r1 = await notifyEvent(deps, 'GUEST_MESSAGE', 'm1');
  assertEquals(r1, { push: 2, adminSms: 'sent' });
  assertEquals(sms.calls.length, 1); assertEquals(sms.calls[0].to, '+17545550101');
  assertStringIncludes(pushed[0].body, 'John Smith'); assertEquals(pushed[1].body, 'Ticket #1025-2 · Tap to read');
  const r2 = await notifyEvent(deps, 'GUEST_MESSAGE', 'm1');
  assertEquals(r2, { push: 0, adminSms: 'skipped' });
  assertEquals(sms.calls.length, 1);
  assert(calls.some(([f, a]) => f === 'airvalet_notify_finish' && a.p_status === 'sent' && a.p_segments === 1));
});
Deno.test('notifyEvent: no admin phone / texting disabled / no VAPID → nothing sent, never throws', async () => {
  const { db } = fakeDb({ adminPhone: null, targets: 3 });
  const sms = new MockProvider();
  assertEquals(await notifyEvent({ db, vapid: null, adminProvider: sms, appUrl: APP }, 'GUEST_MESSAGE', 'm2'), { push: 0, adminSms: 'skipped' });
  assertEquals(sms.calls.length, 0);
  const broken = { rpc: () => Promise.reject(new Error('db down')) };
  assertEquals(await notifyEvent({ db: broken, vapid: VAPID, adminProvider: sms, appUrl: APP }, 'GUEST_MESSAGE', 'm3'), { push: 0, adminSms: 'skipped' });
});
Deno.test('runtime: admin SMS follows the SMS mode (disabled → none; allowlist → only allowlisted)', async () => {
  assertEquals(adminSmsProvider(readSmsConfig(() => undefined)), null);
  assert(adminSmsProvider(readSmsConfig((k) => (k === 'AIRVALET_SMS_MODE' ? 'mock' : undefined))) instanceof MockProvider);
  assertEquals(readVapid(() => undefined), null);
  assertEquals(readVapid((k) => (k === 'AIRVALET_VAPID_PRIVATE_JWK' ? '{"kty":"RSA"}' : 'x'.repeat(87))), null);
  const env: Record<string, string> = {
    AIRVALET_SMS_MODE: 'allowlist', AIRVALET_SMS_TEST_ALLOWLIST: '+17545550101', AIRVALET_SMS_PUBLIC_FUNCTIONS_URL: 'https://x.supabase.co/functions/v1',
    TWILIO_ACCOUNT_SID: 'AC' + 'a'.repeat(32), TWILIO_API_KEY_SID: 'SK' + 'b'.repeat(32), TWILIO_API_KEY_SECRET: 'c'.repeat(32),
    TWILIO_AUTH_TOKEN: 'd'.repeat(32), TWILIO_MESSAGING_SERVICE_SID: 'MG' + 'e'.repeat(32),
  };
  const p = adminSmsProvider(readSmsConfig((k) => env[k]))!;
  const r = await p.send({ to: '+13055550000', body: 'x' });
  assertEquals(r.kind, 'rejected');
});

// ── Mandatory preview: same renderer, nothing claimed/minted/sent ────────
function previewStore(over: Partial<SmsStore> = {}): SmsStore & { claims: number; mints: number } {
  const s = {
    claims: 0, mints: 0,
    getPassenger: (id: number) => Promise.resolve(id === 1 ? {
      id: 1, name: 'JOHN SMITH', phone: '(305) 555-0142', ticket: '1025-2', ret: '10/30/2026', car: 'GLE', status: 'PENDING',
      return_operator: 'MAKERS' as const, delivery_at_customs: false, customs_exception_requested_at: null, delivery_type: null,
      customs_welcome_sent: null, tip_received: null,
    } : null),
    claim: () => { s.claims++; throw new Error('preview must not claim'); },
    markResult: () => Promise.resolve('x'),
    markOptedOut: () => Promise.resolve(),
    mintPassLink: () => { s.mints++; return Promise.resolve('x'); },
    previewStatus: () => Promise.resolve({ would_send: true, block: null, consent: true, opted_out: false }),
    ...over,
  };
  return s;
}
const ops = { userId: 'u', role: 'IPAD_OPS' as const, name: 'Ana' };
Deno.test('preview: exact D1 text, dots for the token (same length), 1 segment, cost, no claim/mint/send', async () => {
  const store = previewStore();
  const provider = new MockProvider();
  const deps: SendDeps = { mode: 'live', store, provider, allowlist: [], passBaseUrl: 'https://airvalet.farberos.com/a#' };
  const p = await previewAirValetSms(deps, { passengerId: 1, type: 'CHECK_IN', actor: ops });
  assertEquals(p.ok, true);
  assertEquals(p.body, 'Welcome to Makers Air Valet!\nYour vehicle has been checked in.\nYour digital valet pass:\nhttps://airvalet.farberos.com/a#' + '•'.repeat(17) + '\nReply STOP to opt out.');
  assertEquals(p.segments, 1); assertEquals(p.encoding, 'GSM-7'); assertEquals(p.chars, 160);
  assertEquals(p.estimated_cost_usd, 0.0113);
  assertEquals(p.to, '+13055550142');
  assertEquals(p.would_send, true);
  assertEquals(store.claims, 0); assertEquals(store.mints, 0); assertEquals(provider.calls.length, 0);
});
Deno.test('preview: shows WHY it would not send (no consent, opted out, test mode, disabled)', async () => {
  const base = { store: previewStore(), provider: new MockProvider(), allowlist: [] as string[], passBaseUrl: 'https://airvalet.farberos.com/a#' };
  const nc = await previewAirValetSms({ ...base, mode: 'live', store: previewStore({ previewStatus: () => Promise.resolve({ would_send: false, block: 'NO_CONSENT', consent: false, opted_out: false }) }) }, { passengerId: 1, type: 'CHECK_IN', actor: ops });
  assertEquals([nc.would_send, nc.block, nc.consent], [false, 'NO_CONSENT', false]);
  const dis = await previewAirValetSms({ ...base, mode: 'disabled' }, { passengerId: 1, type: 'CHECK_IN', actor: ops });
  assertEquals([dis.would_send, dis.block], [false, 'SMS_DISABLED']);
  const al = await previewAirValetSms({ ...base, mode: 'allowlist', allowlist: ['+17545550101'] }, { passengerId: 1, type: 'CHECK_IN', actor: ops });
  assertEquals(al.block, 'NOT_ALLOWLISTED');
  const tv = await previewAirValetSms({ ...base, mode: 'live' }, { passengerId: 1, type: 'CHECK_IN', actor: { userId: 't', role: 'TV_ONLY' } });
  assertEquals(tv.error?.code, 'FORBIDDEN');
  const reply = await previewAirValetSms({ ...base, mode: 'live' }, { passengerId: 1, type: 'REPLY', customBody: 'On our way 😀', actor: ops });
  assertEquals([reply.encoding, reply.segments], ['UCS-2', 1]);
});
