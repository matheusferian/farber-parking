// deno test --allow-env --allow-net --allow-read supabase/functions/stripe-webhook/webhook.test.ts
import { assert, assertEquals } from 'jsr:@std/assert@1';
import Stripe from 'npm:stripe@17';
import { gratuityLinkIds, handle, refundUpdate, tipFromSession, type TipRow } from './index.ts';

const GRAT = 'plink_1GratuityAAA';
const CARWASH = 'plink_1CarWashBBB';
const SECRET = 'whsec_test_' + 'x'.repeat(24);
const stripe = new Stripe('sk_signature_only');

function session(o: Record<string, unknown> = {}) {
  return { id: 'cs_test_1', object: 'checkout.session', payment_status: 'paid', payment_link: GRAT, amount_total: 2000, client_reference_id: null, payment_intent: 'pi_1', metadata: {}, ...o };
}
async function signed(type: string, obj: unknown, secret = SECRET, id = 'evt_1') {
  const payload = JSON.stringify({ id, object: 'event', type, data: { object: obj } });
  const header = await stripe.webhooks.generateTestHeaderStringAsync({ payload, secret });
  return new Request('https://x/stripe-webhook', { method: 'POST', headers: { 'stripe-signature': header }, body: payload });
}
function deps(saved: TipRow[], over: Record<string, unknown> = {}) {
  const seen = new Set<string>();
  return {
    webhookSecret: SECRET, links: [GRAT], stripe,
    save: (r: TipRow) => {
      if (seen.has(r.stripe_event_id)) return Promise.resolve({ error: { message: 'dup', code: '23505' } });
      seen.add(r.stripe_event_id); saved.push(r); return Promise.resolve({ error: null });
    },
    refund: (_pi: string, _s: string, _a: number) => Promise.resolve({ updated: 1, error: null }),
    log: () => {}, ...over,
  };
}

Deno.test('gratuity link ids: only plink_ values kept', () => {
  assertEquals(gratuityLinkIds(' plink_1A ,junk, plink_2B,'), ['plink_1A', 'plink_2B']);
  assertEquals(gratuityLinkIds(undefined), []);
});
Deno.test('decision: gratuity link and AirValet checkout count; car wash link, unpaid, zero do not', () => {
  assert(tipFromSession(session(), 'e', [GRAT]));
  assertEquals(tipFromSession(session({ payment_link: CARWASH }), 'e', [GRAT]), null);
  assertEquals(tipFromSession(session({ payment_status: 'unpaid' }), 'e', [GRAT]), null);
  assertEquals(tipFromSession(session({ amount_total: 0 }), 'e', [GRAT]), null);
  assertEquals(tipFromSession(session({ payment_link: null }), 'e', [GRAT]), null);
  const co = tipFromSession(session({ payment_link: null, metadata: { source: 'AIRVALET', type: 'TIP', passenger_id: '3701', ticket: '1025-2' } }), 'e', []);
  assertEquals([co?.passenger_id, co?.ticket, co?.amount_cents], [3701, '1025-2', 2000]);
  assertEquals(tipFromSession(session({ client_reference_id: 'pax-42' }), 'e', [GRAT])?.passenger_id, 42);
  assertEquals(tipFromSession(session({ client_reference_id: 'abc' }), 'e', [GRAT])?.passenger_id, null);
});
Deno.test('handler: signed gratuity payment recorded once; retries are no-ops', async () => {
  const saved: TipRow[] = [];
  const d = deps(saved);
  const r1 = await handle(await signed('checkout.session.completed', session()), d);
  assertEquals(r1.status, 200); assertEquals((await r1.json()).recorded, true);
  const r2 = await handle(await signed('checkout.session.completed', session()), d);
  assertEquals(r2.status, 200);
  assertEquals(saved.length, 1);
  assertEquals([saved[0].type, saved[0].method, saved[0].status, saved[0].amount_cents], ['TIP', 'STRIPE', 'succeeded', 2000]);
});
Deno.test('handler: refuses bad / missing signatures and works only when configured', async () => {
  const saved: TipRow[] = [];
  assertEquals((await handle(await signed('checkout.session.completed', session(), 'whsec_other_' + 'y'.repeat(20)), deps(saved))).status, 400);
  assertEquals((await handle(new Request('https://x', { method: 'POST', body: '{}' }), deps(saved))).status, 400);
  assertEquals((await handle(await signed('checkout.session.completed', session()), deps(saved, { webhookSecret: undefined }))).status, 503);
  assertEquals((await handle(new Request('https://x'), deps(saved))).status, 405);
  assertEquals(saved.length, 0);
});
Deno.test('handler: other event types and car wash payments are acknowledged, not recorded', async () => {
  const saved: TipRow[] = [];
  assertEquals((await (await handle(await signed('payment_intent.succeeded', { id: 'pi' }), deps(saved))).json()).skipped, 'payment_intent.succeeded');
  assertEquals((await (await handle(await signed('checkout.session.completed', session({ payment_link: CARWASH }), SECRET, 'evt_2'), deps(saved))).json()).ignored, true);
  assertEquals(saved.length, 0);
});
Deno.test('handler: a database error asks Stripe to retry (500)', async () => {
  const r = await handle(await signed('checkout.session.completed', session()), deps([], { save: () => Promise.resolve({ error: { message: 'db down' } }) }));
  assertEquals(r.status, 500);
});

Deno.test('refunds: full refund → refunded, partial → lower amount, nothing refunded → ignored', () => {
  assertEquals(refundUpdate({ payment_intent: 'pi_1', amount: 2000, amount_refunded: 2000, refunded: true }), { paymentIntent: 'pi_1', status: 'refunded', amount_cents: 2000 });
  assertEquals(refundUpdate({ payment_intent: 'pi_1', amount: 2000, amount_refunded: 500, refunded: false }), { paymentIntent: 'pi_1', status: 'succeeded', amount_cents: 1500 });
  assertEquals(refundUpdate({ payment_intent: 'pi_1', amount: 2000, amount_refunded: 0 }), null);
  assertEquals(refundUpdate({ payment_intent: null, amount: 2000, amount_refunded: 2000 }), null);
});
Deno.test('handler: signed charge.refunded updates the tip; a DB error asks for a retry', async () => {
  const calls: Array<[string, string, number]> = [];
  const d = deps([], { refund: (pi: string, st: string, a: number) => { calls.push([pi, st, a]); return Promise.resolve({ updated: 1, error: null }); } });
  const r = await handle(await signed('charge.refunded', { id: 'ch_1', object: 'charge', payment_intent: 'pi_1', amount: 100, amount_refunded: 100, refunded: true }, SECRET, 'evt_r1'), d);
  assertEquals(r.status, 200); assertEquals(calls, [['pi_1', 'refunded', 100]]);
  const bad = deps([], { refund: () => Promise.resolve({ updated: 0, error: { message: 'db' } }) });
  assertEquals((await handle(await signed('charge.refunded', { id: 'ch_2', object: 'charge', payment_intent: 'pi_2', amount: 100, amount_refunded: 100, refunded: true }, SECRET, 'evt_r2'), bad)).status, 500);
});

Deno.test('dynamic Checkout Session (metadata set by valet-pass): tip with the car; async success handled', async () => {
  const s = session({ payment_link: null, client_reference_id: 'pax-77', metadata: { source: 'AIRVALET', type: 'TIP', channel: 'PASS', passenger_id: '77', ticket: '1027-3' } });
  const row = tipFromSession(s, 'e', [GRAT]);
  assertEquals([row?.passenger_id, row?.ticket], [77, '1027-3']);
  const saved: TipRow[] = [];
  const r = await handle(await signed('checkout.session.async_payment_succeeded', s, SECRET, 'evt_async'), deps(saved));
  assertEquals(r.status, 200); assertEquals(saved.length, 1);
  const r2 = await handle(await signed('payment_intent.succeeded', { object: 'payment_intent' }, SECRET, 'evt_pi'), deps(saved));
  assertEquals((await r2.json()).skipped, 'payment_intent.succeeded'); assertEquals(saved.length, 1);
});
Deno.test('printed QR (current Payment Link, no reference): still a tip, no car', () => {
  const row = tipFromSession(session({ client_reference_id: null }), 'e', [GRAT]);
  assertEquals([row?.passenger_id, row?.amount_cents], [null, 2000]);
});
