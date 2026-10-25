// deno test --allow-env --allow-net --allow-read supabase/functions/stripe-webhook/webhook.test.ts
import { assert, assertEquals } from 'jsr:@std/assert@1';
import Stripe from 'npm:stripe@17';
import { gratuityLinkIds, handle, tipFromSession, type TipRow } from './index.ts';

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
