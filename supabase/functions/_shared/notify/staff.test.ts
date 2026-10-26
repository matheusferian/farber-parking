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

// ── Reminders ──
import { notifyReminders, reminderPushPayloads } from './staff.ts';
const RI = (code: string, category: string, n: number) => ({ code, category, key: `REM:${code}:${n}`, ticket: `T-${n}`, body: `${code} for T-${n}` });
function remDb(items: unknown[], targets: unknown[]) {
  const calls: { fn: string; args: Record<string, unknown> }[] = [];
  return { calls, rpc(fn: string, args: Record<string, unknown>) {
    calls.push({ fn, args });
    if (fn === 'airvalet_staff_reminders_claim') return Promise.resolve({ data: items, error: null });
    if (fn === 'airvalet_push_reminder_targets') return Promise.resolve({ data: targets, error: null });
    return Promise.resolve({ data: null, error: null });
  } };
}
Deno.test('reminders: up to 3 → one alert each; more → one summary', () => {
  assertEquals(reminderPushPayloads([RI('H19_WB', 'WELCOME_BACK', 1), RI('MOVE', 'POSITION', 2)]).length, 2);
  const five = reminderPushPayloads([1, 2, 3, 4, 5].map((n) => RI('CW_DAY', 'CARWASH', n)));
  assertEquals(five.length, 1); assertEquals(five[0].title, '5 AIRVALET REMINDERS'); assertStringIncludes(five[0].body, '…');
});
Deno.test('reminders: each phone gets only its categories; audit closed per reminder', async () => {
  const items = [RI('CW_D3', 'CARWASH', 1), RI('NODATE_ADMIN', 'NODATE_ADMIN', 2), RI('H19_WB', 'WELCOME_BACK', 3)];
  const targets = [
    { id: 'owner', endpoint: 'https://web.push.apple.com/o', p256dh: 'p', auth: 'a', categories: ['CARWASH', 'NODATE_ADMIN', 'WELCOME_BACK'] },
    { id: 'ipad', endpoint: 'https://web.push.apple.com/i', p256dh: 'p', auth: 'a', categories: ['CARWASH', 'WELCOME_BACK'] },
    { id: 'tv', endpoint: 'https://web.push.apple.com/t', p256dh: 'p', auth: 'a', categories: ['DAILY'] },
  ];
  const db = remDb(items, targets); const p = fakePush();
  const r = await notifyReminders({ db, vapid: VAPID, pushImpl: p.impl });
  assertEquals(r.items, 3); assertEquals(r.push, 5);                       // owner 3 + iPad 2, other phone 0
  assertEquals(p.sent.filter((s) => s.endpoint.endsWith('/i')).length, 2);
  assertFalse(p.sent.some((s) => s.endpoint.endsWith('/i') && s.data.body.includes('NODATE_ADMIN')));   // admin-only stays on the admin phone
  assertFalse(p.sent.some((s) => s.endpoint.endsWith('/t')));
  const fin = db.calls.filter((c) => c.fn === 'airvalet_notify_finish');
  assertEquals(fin.length, 3);
  assertEquals(fin.find((f) => f.args.p_dedupe_key === 'REM:CW_D3:1')!.args.p_detail, 'CW_D3: 2 device(s)');
  assertEquals(fin.find((f) => f.args.p_dedupe_key === 'REM:NODATE_ADMIN:2')!.args.p_detail, 'NODATE_ADMIN: 1 device(s)');
});
Deno.test('reminders: nothing due → no phone list read, no push', async () => {
  const db = remDb([], []); const p = fakePush();
  assertEquals((await notifyReminders({ db, vapid: VAPID, pushImpl: p.impl })).items, 0);
  assertFalse(db.calls.some((c) => c.fn === 'airvalet_push_reminder_targets')); assertEquals(p.sent.length, 0);
});
Deno.test('reminders: no phone for a reminder → audited as skipped (not lost silently)', async () => {
  const db = remDb([RI('OVERDUE', 'DAILY', 1)], [{ id: 'x', endpoint: 'https://web.push.apple.com/x', p256dh: 'p', auth: 'a', categories: ['CARWASH'] }]);
  await notifyReminders({ db, vapid: VAPID, pushImpl: fakePush().impl });
  const f = db.calls.find((c) => c.fn === 'airvalet_notify_finish')!;
  assertEquals(f.args.p_status, 'skipped'); assertEquals(f.args.p_detail, 'OVERDUE: 0 device(s)');
});
Deno.test('reminders: a phone that is gone stops at the first failure; database errors never throw', async () => {
  let n = 0;
  // deno-lint-ignore no-explicit-any
  const gone = (_s: any, _d: any) => { n++; return Promise.resolve({ ok: false, status: 410, gone: true }); };
  const db = remDb([RI('MOVE', 'POSITION', 1), RI('MOVE', 'POSITION', 2)], [{ id: 'g', endpoint: 'https://web.push.apple.com/g', p256dh: 'p', auth: 'a', categories: ['POSITION'] }]);
  await notifyReminders({ db, vapid: VAPID, pushImpl: gone });
  assertEquals(n, 1);
  assertEquals((await notifyReminders({ db: { rpc: () => Promise.reject(new Error('down')) }, vapid: VAPID })).push, 0);
});
Deno.test('staff-alert: REMINDERS kind is routed to the reminders sender', async () => {
  const db = remDb([], []);
  const r = await handle(new Request('http://x', { method: 'POST', headers: { 'X-Staff-Alert-Secret': 's3cr3t' }, body: '{"kind":"REMINDERS"}' }),
    (k) => k === 'STAFF_ALERT_SECRET' ? 's3cr3t' : undefined, () => ({ db, vapid: VAPID }));
  assertEquals(r.status, 200); assertEquals((await r.json()).kind, 'REMINDERS');
  assert(db.calls.some((c) => c.fn === 'airvalet_staff_reminders_claim'));
});
Deno.test('a phone whose push throws (bad key) never stops the other phones or the audit', async () => {
  // deno-lint-ignore no-explicit-any
  const sent: string[] = [], impl = (s: any) => { if (s.endpoint.endsWith('/bad')) throw new DOMException('bad key', 'DataError'); sent.push(s.endpoint); return Promise.resolve({ ok: true, status: 201, gone: false }); };
  const t = [{ id: 'b', endpoint: 'https://web.push.apple.com/bad', p256dh: 'p', auth: 'a', show_preview: true, categories: ['POSITION'] },
             { id: 'g', endpoint: 'https://web.push.apple.com/good', p256dh: 'p', auth: 'a', show_preview: true, categories: ['POSITION'] }];
  const rdb = remDb([RI('NO_HANGAR', 'POSITION', 1)], t);
  const r = await notifyReminders({ db: rdb, vapid: VAPID, pushImpl: impl });
  assertEquals(r.push, 1); assertEquals(sent, ['https://web.push.apple.com/good']);
  assertEquals(rdb.calls.find((c) => c.fn === 'airvalet_notify_finish')!.args.p_status, 'sent');
  const cdb = fakeDb({ mode: 'single', key: 'push:CHECK_IN:7', ticket: '1026-7' }, t);
  const c = await notifyStaff({ db: cdb, vapid: VAPID, pushImpl: impl }, 'CHECK_IN', 7);
  assertEquals(c.push, 1);
  assertEquals(cdb.calls.find((x) => x.fn === 'airvalet_notify_finish')!.args.p_detail, 'single: 1 device(s)');
});
Deno.test('same flight: three cars landing together → one alert listing the tickets', () => {
  const wb = (n: number) => ({ ...RI('H19_WB', 'WELCOME_BACK', n), grp: 'H19_WB:2026-10-26:1022', gtext: 'Send Welcome Back, lands 5:02 PM: {t}' });
  const p = reminderPushPayloads([wb(1), wb(2), wb(3)]);
  assertEquals(p.length, 1);
  assertEquals(p[0].body, 'Send Welcome Back, lands 5:02 PM: T-1, T-2, T-3'); assertEquals(p[0].title, 'AIRVALET REMINDER');
  // another flight stays apart; one car alone keeps its own text
  const other = { ...RI('H19_WB', 'WELCOME_BACK', 9), grp: 'H19_WB:2026-10-26:1110', gtext: 'Send Welcome Back, lands 6:30 PM: {t}' };
  const q = reminderPushPayloads([wb(1), wb(2), other]);
  assertEquals(q.length, 2); assertEquals(q[1].body, 'H19_WB for T-9');
});
Deno.test('grouping counts as one alert for the "more than 3 → summary" rule', () => {
  const g = (code: string, n: number, grp: string) => ({ ...RI(code, 'POSITION', n), grp, gtext: `${code}: {t}` });
  const items = [g('NO_HANGAR', 1, 'NO_HANGAR'), g('NO_HANGAR', 2, 'NO_HANGAR'), g('NO_HANGAR', 3, 'NO_HANGAR'), g('NO_HANGAR', 4, 'NO_HANGAR'), RI('OVERDUE', 'DAILY', 5)];
  const p = reminderPushPayloads(items);
  assertEquals(p.length, 2); assertEquals(p[0].body, 'NO_HANGAR: T-1, T-2, T-3, T-4');
});
Deno.test('grouped reminders: each one still audited on its own', async () => {
  const wb = (n: number) => ({ ...RI('H19_WB', 'WELCOME_BACK', n), grp: 'H19_WB:x', gtext: 'WB: {t}' });
  const db = remDb([wb(1), wb(2), wb(3)], [{ id: 'o', endpoint: 'https://web.push.apple.com/o', p256dh: 'p', auth: 'a', categories: ['WELCOME_BACK'] }]);
  const p = fakePush();
  const r = await notifyReminders({ db, vapid: VAPID, pushImpl: p.impl });
  assertEquals(p.sent.length, 1); assertEquals(r.push, 1);
  const fin = db.calls.filter((c) => c.fn === 'airvalet_notify_finish');
  assertEquals(fin.length, 3); assert(fin.every((f) => f.args.p_status === 'sent' && f.args.p_detail === 'H19_WB: 1 device(s)'));
});
