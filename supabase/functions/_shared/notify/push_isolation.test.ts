// deno test --allow-env supabase/functions/_shared/notify/push_isolation.test.ts
// Audit 2026-10 (A2-01): one subscription with malformed keys must never stop
// the other devices nor the Super Admin SMS copy, and must leave the list.
import { assertEquals } from 'jsr:@std/assert@1';
import { notifyEvent } from './notify.ts';
import { MockProvider } from '../sms/provider.ts';
import { b64u, sendPush } from '../push/webpush.ts';

async function setup(order: 'bad-first' | 'good-first') {
  const ua = await crypto.subtle.generateKey({ name: 'ECDH', namedCurve: 'P-256' }, true, ['deriveBits']);
  const p256dh = b64u(new Uint8Array(await crypto.subtle.exportKey('raw', ua.publicKey)));
  const auth = b64u(crypto.getRandomValues(new Uint8Array(16)));
  const vk = await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign']);
  const vapid = { privateJwk: await crypto.subtle.exportKey('jwk', vk.privateKey), publicKey: b64u(new Uint8Array(await crypto.subtle.exportKey('raw', vk.publicKey))), subject: 'mailto:test@example.com' };
  const bad = { id: 'bad', endpoint: 'https://push.example/bad', p256dh: 'x', auth: 'y', show_preview: false };
  const good = { id: 'good', endpoint: 'https://push.example/good', p256dh, auth, show_preview: false };
  const results: Array<Record<string, unknown>> = [];
  const finished: string[] = [];
  const db = {
    rpc(fn: string, args: Record<string, unknown>) {
      let data: unknown = null;
      if (fn === 'airvalet_notify_details') data = { kind: 'GUEST_MESSAGE', passenger_id: 7, phone_e164: '+13055550142', name: 'John Smith', ticket: '1025-2', text: 'hello' };
      if (fn === 'airvalet_notify_claim') data = true;
      if (fn === 'airvalet_push_targets') data = order === 'bad-first' ? [bad, good] : [good, bad];
      if (fn === 'airvalet_push_result') results.push(args);
      if (fn === 'airvalet_notify_finish') finished.push(String(args.p_dedupe_key));
      if (fn === 'airvalet_admin_alert_claim') data = '+17545550101';
      return Promise.resolve({ data, error: null });
    },
  };
  return { db, vapid, results, finished };
}

for (const order of ['bad-first', 'good-first'] as const) {
  Deno.test(`push isolation (${order}): good device pushed, bad one marked gone, admin SMS sent, log finished`, async () => {
    const { db, vapid, results, finished } = await setup(order);
    let delivered = 0;
    const pushImpl: typeof sendPush = (sub, data, v) => sendPush(sub, data, v, (() => { delivered++; return Promise.resolve(new Response(null, { status: 201 })); }) as typeof fetch);
    const sms = new MockProvider();
    const r = await notifyEvent({ db, vapid, adminProvider: sms, appUrl: 'https://airvalet.farberos.com', pushImpl }, 'GUEST_MESSAGE', 'm1');
    assertEquals(delivered, 1);
    assertEquals(r, { push: 1, adminSms: 'sent' });
    assertEquals(sms.calls.length, 1);
    assertEquals(results.find((x) => x.p_id === 'bad'), { p_id: 'bad', p_ok: false, p_gone: true });
    assertEquals(results.find((x) => x.p_id === 'good'), { p_id: 'good', p_ok: true, p_gone: false });
    assertEquals(finished.length, 2); // push + admin SMS both closed
  });
}

Deno.test('push isolation: a device whose push throws (db/network) does not stop the next one', async () => {
  const { db, vapid } = await setup('good-first');
  let n = 0;
  const pushImpl = (() => { n++; if (n === 1) throw new Error('boom'); return Promise.resolve({ ok: true, status: 201, gone: false }); }) as unknown as typeof sendPush;
  const r = await notifyEvent({ db, vapid, adminProvider: new MockProvider(), appUrl: 'https://x', pushImpl }, 'GUEST_MESSAGE', 'm2');
  assertEquals(r.push, 1);
  assertEquals(r.adminSms, 'sent');
});
