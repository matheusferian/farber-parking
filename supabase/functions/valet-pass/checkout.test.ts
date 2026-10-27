// deno test --allow-env supabase/functions/valet-pass/checkout.test.ts
import { assert, assertEquals } from 'jsr:@std/assert@1';
import { createSession, idempotencyKey, sessionForm } from './checkout.ts';

const C = { amount_cents: 2000, passenger_id: 77, ticket: '1027-3', link_id: 9 };

Deno.test('session form: server-set reference, metadata, amount; no token in return URLs', () => {
  const f = sessionForm(C, 'https://airvalet.farberos.com/a');
  assertEquals(f.get('client_reference_id'), 'pax-77');
  assertEquals(f.get('line_items[0][price_data][unit_amount]'), '2000');
  assertEquals([f.get('metadata[source]'), f.get('metadata[type]'), f.get('metadata[passenger_id]'), f.get('metadata[ticket]')], ['AIRVALET', 'TIP', '77', '1027-3']);
  assertEquals(f.get('payment_intent_data[metadata][passenger_id]'), '77');
  assertEquals([f.get('success_url'), f.get('cancel_url')], ['https://airvalet.farberos.com/a?gratuity=thanks', 'https://airvalet.farberos.com/a?gratuity=cancel']);
  assert(!f.has('payment_method_types'), 'payment methods come from the Stripe dashboard (Apple Pay / Google Pay)');
  assert(![...f.values()].some((v) => /percent|%/i.test(v)), 'no percentages');
});
Deno.test('idempotency key per tap', () => {
  assertEquals(idempotencyKey(C, 'ckABCDEFGHIJKLMNOP'), 'avtip-9-2000-ckABCDEFGHIJKLMNOP');
});
Deno.test('no key → null (page falls back to the current Payment Link)', async () => {
  assertEquals(await createSession(C, 'ck', () => undefined), null);
});
Deno.test('live key never uses the API base override; non-Stripe URL refused', async () => {
  const seen: string[] = [];
  const f = ((u: string) => { seen.push(u); return Promise.resolve(new Response(JSON.stringify({ id: 'cs_1', url: 'https://evil.example/x' }))); }) as unknown as typeof fetch;
  const env: Record<string, string> = { AIRVALET_STRIPE_CHECKOUT_KEY: 'rk_live_' + 'a'.repeat(20), AIRVALET_STRIPE_API_BASE: 'http://127.0.0.1:1' };
  assertEquals(await createSession(C, 'ck', (k) => env[k], f), null);
  assertEquals(seen, ['https://api.stripe.com/v1/checkout/sessions']);
});
Deno.test('the same claim always gives the same form (idempotent retries)', async () => {
  const a = sessionForm(C, 'https://x/a').toString();
  await new Promise((r) => setTimeout(r, 1100));
  assertEquals(sessionForm(C, 'https://x/a').toString(), a);
});
