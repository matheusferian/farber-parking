// deno test supabase/functions/_shared/sms/link-fallback.test.ts — fake DB, no Twilio.
import { assertEquals } from 'jsr:@std/assert@1';
import { countSegments } from './templates.ts';
import { isPassWord, NO_LINK_BODY, noLinkCopyFor, passReply, passReplyBody, sendNoLinkCopy, type BlockedRow } from './link-fallback.ts';

const row = (o: Partial<BlockedRow> = {}): BlockedRow => ({
  id: 'orig-1', direction: 'outbound', template_key: 'CHECK_IN_PASS', message_type: 'CHECK_IN',
  body: 'Welcome to Makers Air Valet! ... https://airvalet.farberos.com/a#abc', passenger_id: 7, ticket_snapshot: '1116-6',
  phone_e164: '+15615550100', status: 'undelivered', ...o,
});

Deno.test('no-link copies are 1 segment and carry no link', () => {
  for (const b of Object.values(NO_LINK_BODY)) {
    assertEquals(countSegments(b), 1);
    assertEquals(/https?:|www\.|\.com/.test(b), false);
    assertEquals(b.includes('Reply PASS'), true);
  }
});

Deno.test('only a carrier-filtered link text gets a copy', () => {
  assertEquals(noLinkCopyFor('30007', 'undelivered', row()), NO_LINK_BODY.CHECK_IN_PASS);
  assertEquals(noLinkCopyFor('30007', 'undelivered', row({ template_key: 'DELIVERED' })), NO_LINK_BODY.DELIVERED);
  assertEquals(noLinkCopyFor('30005', 'undelivered', row()), null);                                   // number can't get texts
  assertEquals(noLinkCopyFor('30007', 'delivered', row()), null);
  assertEquals(noLinkCopyFor('30007', 'undelivered', row({ template_key: 'HANGAR19_WELCOME_BACK' })), null);
  assertEquals(noLinkCopyFor('30007', 'undelivered', row({ template_key: 'CHECK_IN_PASS_NOLINK' })), null); // the copy never loops
  assertEquals(noLinkCopyFor('30007', 'undelivered', row({ body: 'no link here' })), null);
  assertEquals(noLinkCopyFor('30007', 'undelivered', null), null);
});

// Minimal fake of the supabase-js calls sendNoLinkCopy makes.
function fakeAdmin(orig: BlockedRow | null) {
  const inserted: Record<string, unknown>[] = [], updates: Record<string, unknown>[] = [], rpcs: Record<string, unknown>[] = [];
  const keys = new Set<string>();
  const admin = {
    from: (_t: string) => ({
      select: () => ({ eq: () => ({ maybeSingle: async () => ({ data: orig }) }) }),
      insert: (v: Record<string, unknown>) => ({ select: () => ({ maybeSingle: async () => {
        if (keys.has(String(v.idempotency_key))) return { data: null, error: { code: '23505' } };
        keys.add(String(v.idempotency_key)); inserted.push(v); return { data: { id: 'copy-' + inserted.length }, error: null };
      } }) }),
      update: (v: Record<string, unknown>) => ({ eq: (_c: string, id: string) => ({ is: async () => { updates.push({ id, ...v }); return {}; } }) }),
    }),
    rpc: async (_fn: string, a: Record<string, unknown>) => { rpcs.push(a); return { data: null, error: null }; },
  };
  return { admin, inserted, updates, rpcs };
}

Deno.test('blocked welcome → one copy without link, alert closed; Twilio retry sends nothing more', async () => {
  const f = fakeAdmin(row());
  const sent: string[] = [];
  const send = async (_to: string, body: string, _mid: string) => { sent.push(body); return { ok: true, sid: 'SMcopy', status: 'accepted', errorCode: null, errorMessage: null }; };
  await sendNoLinkCopy(f.admin, 'SMorig', 'undelivered', '30007', send);
  await sendNoLinkCopy(f.admin, 'SMorig', 'undelivered', '30007', send);   // Twilio retries the callback
  assertEquals(sent, [NO_LINK_BODY.CHECK_IN_PASS]);
  assertEquals(f.inserted.length, 1);
  assertEquals([f.inserted[0].idempotency_key, f.inserted[0].template_key, f.inserted[0].passenger_id], ['nolink:orig-1', 'CHECK_IN_PASS_NOLINK', 7]);
  assertEquals(f.rpcs[0].p_status, 'accepted');
  assertEquals(f.updates.map((u) => [u.id, u.resolution]), [['orig-1', 'acknowledged']]);
});

Deno.test('copy refused by Twilio → stored as failed, original alert stays open', async () => {
  const f = fakeAdmin(row({ template_key: 'DELIVERED' }));
  await sendNoLinkCopy(f.admin, 'SMorig', 'undelivered', '30007', async () => ({ ok: false, sid: null, status: 'failed', errorCode: '21610', errorMessage: 'opted out' }));
  assertEquals(f.rpcs[0].p_status, 'failed');
  assertEquals(f.updates.length, 0);
});

Deno.test('other errors and delivered texts never touch the DB', async () => {
  const f = fakeAdmin(row());
  let calls = 0;
  await sendNoLinkCopy(f.admin, 'SMx', 'undelivered', '30005', async () => { calls++; return { ok: true, sid: 'x', status: 'accepted', errorCode: null, errorMessage: null }; });
  await sendNoLinkCopy(f.admin, 'SMx', 'delivered', null, async () => { calls++; return { ok: true, sid: 'x', status: 'accepted', errorCode: null, errorMessage: null }; });
  assertEquals([calls, f.inserted.length], [0, 0]);
});

// Fake for passReply: one query (latest no-link copy) + inserts with unique keys + rpc mint / mark.
function passAdmin(copy: Record<string, unknown> | null, token: string | null = 'Ab3dE6gH9jK2mN4pQ') {
  const inserted: Record<string, unknown>[] = [], rpcs: [string, Record<string, unknown>][] = [], keys = new Set<string>();
  const chain: Record<string, unknown> = {};
  for (const k of ['select', 'eq', 'gte', 'order', 'limit']) chain[k] = () => chain;
  chain.maybeSingle = async () => ({ data: copy });
  const admin = {
    from: () => ({
      ...chain,
      insert: (v: Record<string, unknown>) => {
        const key = String(v.idempotency_key || v.provider_message_sid);
        const dup = keys.has(key); if (!dup) { keys.add(key); inserted.push(v); }
        const res = dup ? { data: null, error: { code: '23505' } } : { data: { id: 'row-' + inserted.length }, error: null };
        return Object.assign(Promise.resolve(res), { select: () => ({ maybeSingle: async () => res }) });
      },
    }),
    rpc: async (fn: string, a: Record<string, unknown>) => { rpcs.push([fn, a]); return { data: fn === 'airvalet_pass_mint' ? token : null, error: null }; },
  };
  return { admin, inserted, rpcs };
}
const BASE = 'https://airvalet.farberos.com/p/';
const okSend = (sent: string[]) => async (_to: string, body: string) => { sent.push(body); return { ok: true, sid: 'SMr', status: 'accepted', errorCode: null, errorMessage: null }; };

Deno.test('PASS word: only the word itself', () => {
  assertEquals(['PASS', 'pass', ' Pass. ', 'pass!'].map(isPassWord), [true, true, true, true]);
  assertEquals(['passport', 'my pass please', 'STOP', ''].map(isPassWord), [false, false, false, false]);
});

Deno.test('reply PASS after a blocked link → fresh /p/ link, PASS stored as read; second PASS goes to the Inbox', async () => {
  const f = passAdmin({ id: 'copy-1', passenger_id: 7, ticket_snapshot: '1116-6', message_type: 'CHECK_IN' });
  const sent: string[] = [];
  assertEquals(await passReply(f.admin, '+15615550100', 'SMin1', BASE, okSend(sent)), true);
  assertEquals(sent, [passReplyBody(BASE + 'Ab3dE6gH9jK2mN4pQ')]);
  assertEquals(sent[0], 'Makers Air Valet: Here is your valet pass: https://airvalet.farberos.com/p/Ab3dE6gH9jK2mN4pQ');
  assertEquals(f.inserted.map((r) => [r.direction, r.template_key ?? r.body]), [['outbound', 'PASS_REPLY'], ['inbound', 'PASS']]);
  assertEquals(String(f.inserted[0].body).includes('Ab3dE6'), false);           // the token never stored in clear
  assertEquals(f.rpcs.map((r) => r[0]), ['airvalet_pass_mint', 'airvalet_sms_mark_result']);
  assertEquals(await passReply(f.admin, '+15615550100', 'SMin2', BASE, okSend(sent)), false);
  assertEquals(sent.length, 1);
});

Deno.test('PASS from a phone whose link was never blocked → normal Inbox (no link rotated)', async () => {
  const f = passAdmin(null);
  const sent: string[] = [];
  assertEquals(await passReply(f.admin, '+15615550100', 'SMin', BASE, okSend(sent)), false);
  assertEquals([sent.length, f.rpcs.length, f.inserted.length], [0, 0, 0]);
});

Deno.test('no link available (car archived) → reply marked failed, nothing sent', async () => {
  const f = passAdmin({ id: 'copy-1', passenger_id: 7, ticket_snapshot: '1116-6', message_type: 'CHECK_IN' }, null);
  const sent: string[] = [];
  assertEquals(await passReply(f.admin, '+15615550100', 'SMin', BASE, okSend(sent)), true);
  assertEquals(sent.length, 0);
  assertEquals(f.rpcs[1][1].p_error_code, 'PASS_LINK_UNAVAILABLE');
});
