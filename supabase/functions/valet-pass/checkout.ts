// Gratuity Checkout Session for the Valet Pass (owner 2026-10-27, flag
// gratuity_checkout_enabled, OFF by default). Everything Stripe stores about
// the car is set HERE, from what SQL returned for a valid token — never from
// the guest's request: client_reference_id, metadata (source/type/passenger/
// ticket) and the amount (already bounded in SQL). No token goes to Stripe:
// the return URLs carry only ?gratuity=thanks|cancel; pass.js restores the
// pass from the tab's own sessionStorage.
//
// Key: AIRVALET_STRIPE_CHECKOUT_KEY = a RESTRICTED key of the MATT SOLUTIONS
// account with only "Checkout Sessions: Write". Deliberately NOT named
// STRIPE_SECRET_KEY: setting that name would also arm the old
// create-tip-checkout function (deployed, staff JWT, any passenger_id).
// AIRVALET_STRIPE_API_BASE (local mock) is honored only for *_test_ keys.

export type Claim = { amount_cents: number; passenger_id: number; ticket: string | null; link_id: number };

export function sessionForm(c: Claim, returnUrl: string): URLSearchParams {
  const f = new URLSearchParams();
  const md: Record<string, string> = { source: 'AIRVALET', type: 'TIP', channel: 'PASS', passenger_id: String(c.passenger_id) };
  if (c.ticket) md.ticket = c.ticket;
  f.set('mode', 'payment');
  f.set('line_items[0][quantity]', '1');
  f.set('line_items[0][price_data][currency]', 'usd');
  f.set('line_items[0][price_data][unit_amount]', String(c.amount_cents));
  f.set('line_items[0][price_data][product_data][name]', 'Gratuity · Makers Air Valet');
  f.set('client_reference_id', 'pax-' + c.passenger_id);
  for (const [k, v] of Object.entries(md)) { f.set(`metadata[${k}]`, v); f.set(`payment_intent_data[metadata][${k}]`, v); }
  f.set('payment_intent_data[description]', 'Makers Air Valet gratuity' + (c.ticket ? ' ' + c.ticket : ''));
  f.set('success_url', returnUrl + '?gratuity=thanks');
  f.set('cancel_url', returnUrl + '?gratuity=cancel');
  // No expires_at (Stripe default, 24 h): a time-based field would make a retried
  // request differ from the first one and Stripe would refuse the idempotency key.
  return f;
}

// One key per tap (ck from the page): a retried request returns the same session.
export function idempotencyKey(c: Claim, ck: string): string {
  return `avtip-${c.link_id}-${c.amount_cents}-${ck}`;
}

export async function createSession(c: Claim, ck: string, get: (k: string) => string | undefined,
  fetcher: typeof fetch = fetch): Promise<{ url: string; id: string } | null> {
  const key = get('AIRVALET_STRIPE_CHECKOUT_KEY') || '';
  if (!/^(rk|sk)_(live|test)_[A-Za-z0-9]{10,}$/.test(key)) return null;
  const test = /^(rk|sk)_test_/.test(key);
  const base = (test && get('AIRVALET_STRIPE_API_BASE')) || 'https://api.stripe.com';
  const returnUrl = get('AIRVALET_PASS_RETURN_URL') || 'https://airvalet.farberos.com/a';
  const res = await fetcher(base + '/v1/checkout/sessions', {
    method: 'POST',
    headers: { Authorization: 'Bearer ' + key, 'Content-Type': 'application/x-www-form-urlencoded', 'Idempotency-Key': idempotencyKey(c, ck) },
    body: sessionForm(c, returnUrl).toString(),
  });
  if (!res.ok) { await res.body?.cancel(); return null; }
  const j = await res.json().catch(() => null) as { url?: unknown; id?: unknown } | null;
  const url = j && typeof j.url === 'string' ? j.url : '';
  // Only Stripe's own hosted checkout (or the local mock with a test key).
  if (!/^https:\/\/checkout\.stripe\.com\//.test(url)) return null;
  return { url, id: String(j!.id || '') };
}
