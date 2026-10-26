// deno test --allow-env supabase/functions/_shared/notify/staff.test.ts
import { assert, assertEquals, assertFalse, assertStringIncludes } from 'jsr:@std/assert@1';
import { notifyStaff, staffPushPayload } from './staff.ts';
import { handle } from '../../staff-alert/index.ts';

const VAPID = { privateJwk: {} as JsonWebKey, publicKey: 'x', subject: 'mailto:t@t' };

function fakeDb(claim: unknown, targets: unknown[] = [{ id: 't1', endpoint: 'https://web.push.apple.com/a', p256dh: 'p', auth: 'a', show_preview: true },
                                                     { id: 't2', endpoint: 'https://web.push.apple.com/b', p256dh: 'p', auth: 'a', show_preview: false }]) {
  const calls: { fn: string; args: Record<string, unknown> }[] = [];
  return {
    calls,
    rpc(fn: string, args: Record<string, unknown>) {
      calls.push({ fn, args });
      if (fn === 'airvalet_staff_alert_claim') return Promise.resolve({ data: claim, error: null });
      if (fn === 'airvalet_push_staff_targets') return Promise.resolve({ data: targets, error: null });
      return Promise.resolve({ data: null, error: null });
    },
  };
}
function fakePush() {
  const sent: { endpoint: string; data: { title: string; body: string } }[] = [];
  // deno-lint-ignore no-explicit-any
  const impl = (sub: any, data: any) => { sent.push({ endpoint: sub.endpoint, data }); return Promise.resolve({ ok: true, status: 201, gone: false }); };
  return { sent, impl };
}

Deno.test('check-in alert: name only on phones that show details; ticket and place always', () => {
  const c = { mode: 'single' as const, key: 'k', name: 'JOHN SMITH', ticket: '1026-3', loc: 'HANGAR 19' };
  const a = staffPushPayload('CHECK_IN', c, true), b = staffPushPayload('CHECK_IN', c, false);
  assertEquals(a.title, 'NEW CHECK-IN');
  assertStringIncludes(a.body, 'JOHN SMITH'); assertStringIncludes(a.body, '1026-3'); assertStringIncludes(a.body, 'HANGAR 19');
  assertFalse(b.body.includes('JOHN')); assertStringIncludes(b.body, '1026-3');
});
Deno.test('check-in burst: one summary alert', () => {
  const p = staffPushPayload('CHECK_IN', { mode: 'summary', key: 'k' }, true);
  assertEquals(p.title, 'NEW CHECK-INS'); assertEquals(p.tag, 'airvalet-checkin-batch');
});
Deno.test('tip alert: amount in the title; name only with details on', () => {
  const c = { mode: 'single' as const, key: 'push:TIP:9', amount_cents: 1500, ticket: '1026-2', name: 'ANA LIMA' };
  const a = staffPushPayload('TIP', c, true), b = staffPushPayload('TIP', c, false);
  assertEquals(a.title, 'NEW TIP · $15.00'); assertStringIncludes(a.body, 'ANA LIMA'); assertStringIncludes(a.body, 'Stripe');
  assertFalse(b.body.includes('ANA')); assertStringIncludes(b.body, '1026-2');
  assertEquals(staffPushPayload('TIP', { mode: 'single', key: 'k', amount_cents: 500 }, false).body, 'Valet tip · Stripe');
});
Deno.test('notifyStaff: claim → every opted-in phone → result and log closed', async () => {
  const db = fakeDb({ mode: 'single', key: 'push:CHECK_IN:5', name: 'JOHN', ticket: '1026-3', loc: '' });
  const p = fakePush();
  const r = await notifyStaff({ db, vapid: VAPID, pushImpl: p.impl }, 'CHECK_IN', 5);
  assertEquals(r, { kind: 'CHECK_IN', mode: 'single', push: 2 });
  assertEquals(p.sent.length, 2);
  assertStringIncludes(p.sent[0].data.body, 'JOHN'); assertFalse(p.sent[1].data.body.includes('JOHN'));
  assertEquals(db.calls.filter((c) => c.fn === 'airvalet_push_result').length, 2);
  const fin = db.calls.find((c) => c.fn === 'airvalet_notify_finish')!;
  assertEquals(fin.args.p_status, 'sent'); assertEquals(fin.args.p_dedupe_key, 'push:CHECK_IN:5');
  assertEquals(db.calls.find((c) => c.fn === 'airvalet_push_staff_targets')!.args.p_kind, 'CHECK_IN');
});
Deno.test('notifyStaff: skip (duplicate / not a check-in / burst) sends nothing', async () => {
  const db = fakeDb({ mode: 'skip' }); const p = fakePush();
  assertEquals((await notifyStaff({ db, vapid: VAPID, pushImpl: p.impl }, 'CHECK_IN', 5)).push, 0);
  assertEquals(p.sent.length, 0); assertFalse(db.calls.some((c) => c.fn === 'airvalet_push_staff_targets'));
});
Deno.test('notifyStaff: push not configured → closed as skipped, nothing sent', async () => {
  const db = fakeDb({ mode: 'single', key: 'push:TIP:1', amount_cents: 100 }); const p = fakePush();
  await notifyStaff({ db, vapid: null, pushImpl: p.impl }, 'TIP', 1);
  assertEquals(p.sent.length, 0);
  assertEquals(db.calls.find((c) => c.fn === 'airvalet_notify_finish')!.args.p_status, 'skipped');
});
Deno.test('notifyStaff: unknown kind / bad id never reach the database', async () => {
  for (const [k, id] of [['SMS', 1], ['TIP', 0], ['CHECK_IN', -3], ['CHECK_IN', 1.5]] as const) {
    const db = fakeDb({ mode: 'single', key: 'x' });
    assertEquals((await notifyStaff({ db, vapid: VAPID }, k, id)).mode, 'skip');
    assertEquals(db.calls.length, 0);
  }
});
Deno.test('notifyStaff: a database error never throws', async () => {
  const db = { rpc: () => Promise.reject(new Error('down')) };
  assertEquals((await notifyStaff({ db, vapid: VAPID }, 'TIP', 1)).push, 0);
});
Deno.test('staff-alert: secret required, compared before anything else', async () => {
  const req = (h: Record<string, string>, body = '{"kind":"TIP","id":1}') => new Request('http://x/staff-alert', { method: 'POST', headers: h, body });
  let made = 0;
  const deps = () => { made++; return { db: fakeDb({ mode: 'skip' }), vapid: null }; };
  assertEquals((await handle(req({}), () => undefined, deps)).status, 500);                 // not configured
  assertEquals((await handle(req({}), (k) => k === 'STAFF_ALERT_SECRET' ? 's3cr3t' : undefined, deps)).status, 401);
  assertEquals((await handle(req({ 'X-Staff-Alert-Secret': 'wrong!' }), (k) => k === 'STAFF_ALERT_SECRET' ? 's3cr3t' : undefined, deps)).status, 401);
  assertEquals(made, 0);
  const ok = await handle(req({ 'X-Staff-Alert-Secret': 's3cr3t' }), (k) => k === 'STAFF_ALERT_SECRET' ? 's3cr3t' : undefined, deps);
  assertEquals(ok.status, 200); assertEquals(made, 1);
  assertEquals((await handle(new Request('http://x', { method: 'GET' }), () => 's', deps)).status, 405);
  assert((await handle(req({ 'X-Staff-Alert-Secret': 's3cr3t' }, 'not json'), (k) => k === 'STAFF_ALERT_SECRET' ? 's3cr3t' : undefined, deps)).status === 400);
});
