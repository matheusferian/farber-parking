// Stripe Tips — receives Stripe webhook events from the MATT SOLUTIONS Stripe
// account (AirValet never uses Farber Stripe credentials).
//
// MUST be deployed with --no-verify-jwt (Stripe cannot send a Supabase JWT).
// Trust comes from Stripe's signature (STRIPE_WEBHOOK_SECRET). Without that
// secret every event is refused (503) — nothing is recorded unsigned.
//
// Counts as an AirValet tip (owner 2026-10-25): a paid checkout.session.completed
//   * created by create-tip-checkout (metadata source=AIRVALET, type=TIP), or
//   * paid through the AirValet gratuity Payment Link — the one buy.stripe.com
//     link the valet pass and texts use. Its plink id(s) are set in
//     AIRVALET_GRATUITY_PAYMENT_LINK_IDS so the account's other links (car wash)
//     never count as tips.
// Optional passenger tie: metadata.passenger_id, or client_reference_id "pax-<id>".
// Idempotency: stripe_event_id is unique; a Stripe retry is a no-op.
// Refunds (charge.refunded, owner 2026-10-25): a full refund marks the tip
// 'refunded' (out of the reports); a partial one lowers amount_cents.

import { createClient } from 'npm:@supabase/supabase-js@2';
import Stripe from 'npm:stripe@17';

type Session = {
  id: string;
  payment_status?: string | null;
  payment_link?: string | null;
  amount_total?: number | null;
  client_reference_id?: string | null;
  payment_intent?: unknown;
  metadata?: Record<string, string> | null;
};
export type TipRow = {
  passenger_id: number | null; ticket: string | null; amount_cents: number; type: 'TIP'; method: 'STRIPE';
  status: 'succeeded'; stripe_checkout_session_id: string; stripe_payment_intent_id: string | null; stripe_event_id: string;
};

export function gratuityLinkIds(raw: string | undefined): string[] {
  return String(raw || '').split(',').map((s) => s.trim()).filter((s) => /^plink_[A-Za-z0-9]+$/.test(s));
}

// The one decision: is this paid session an AirValet tip? null = not recorded.
export function tipFromSession(session: Session, eventId: string, links: string[]): TipRow | null {
  if (session.payment_status !== 'paid') return null;
  const md = session.metadata || {};
  const fromCheckout = md.source === 'AIRVALET' && md.type === 'TIP';
  const fromLink = !!session.payment_link && links.includes(session.payment_link);
  if (!fromCheckout && !fromLink) return null;
  const amount = Number(session.amount_total ?? 0);
  if (!Number.isFinite(amount) || amount <= 0) return null;
  let passengerId: number | null = null;
  if (md.passenger_id && /^\d{1,12}$/.test(md.passenger_id)) passengerId = Number(md.passenger_id);
  else {
    const m = /^pax-(\d{1,12})$/.exec(String(session.client_reference_id || ''));
    if (m) passengerId = Number(m[1]);
  }
  return {
    passenger_id: passengerId,
    ticket: md.ticket || null,
    amount_cents: Math.round(amount),
    type: 'TIP',
    method: 'STRIPE',
    status: 'succeeded',
    stripe_checkout_session_id: session.id,
    stripe_payment_intent_id: typeof session.payment_intent === 'string' ? session.payment_intent : null,
    stripe_event_id: eventId,
  };
}

// charge.refunded → what to store on the tip with that payment intent.
export function refundUpdate(charge: { payment_intent?: unknown; amount?: number | null; amount_refunded?: number | null; refunded?: boolean | null }):
  { paymentIntent: string; status: 'refunded' | 'succeeded'; amount_cents: number } | null {
  const pi = typeof charge.payment_intent === 'string' ? charge.payment_intent : null;
  const amount = Number(charge.amount ?? 0), refunded = Number(charge.amount_refunded ?? 0);
  if (!pi || !(amount > 0) || !(refunded > 0)) return null;
  if (charge.refunded || refunded >= amount) return { paymentIntent: pi, status: 'refunded', amount_cents: amount };
  return { paymentIntent: pi, status: 'succeeded', amount_cents: amount - refunded };
}

export type Deps = {
  webhookSecret: string | undefined;
  links: string[];
  stripe: Stripe;
  save: (row: TipRow) => Promise<{ error: { message: string; code?: string } | null }>;
  refund: (paymentIntent: string, status: string, amountCents: number) => Promise<{ updated: number; error: { message: string } | null }>;
  log: (event: string, data: Record<string, unknown>) => void;
};

export async function handle(req: Request, deps: Deps): Promise<Response> {
  const json = (status: number, body: unknown) => new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });
  if (req.method !== 'POST') return json(405, { error: 'POST only' });
  if (!deps.webhookSecret) { deps.log('stripe_webhook_not_configured', {}); return json(503, { error: 'not configured' }); }
  const sig = req.headers.get('stripe-signature');
  const rawBody = await req.text();
  if (!sig) return json(400, { error: 'missing signature' });
  let event: Stripe.Event;
  try {
    event = await deps.stripe.webhooks.constructEventAsync(rawBody, sig, deps.webhookSecret);
  } catch {
    return json(400, { error: 'signature verification failed' });
  }
  if (event.type === 'charge.refunded') {
    const u = refundUpdate(event.data.object as unknown as Parameters<typeof refundUpdate>[0]);
    if (!u) return json(200, { received: true, ignored: true });
    const r = await deps.refund(u.paymentIntent, u.status, u.amount_cents);
    if (r.error) { deps.log('stripe_refund_update_failed', { event: event.id, error: r.error.message }); return json(500, { received: false }); }
    deps.log('stripe_refund_applied', { event: event.id, updated: r.updated, status: u.status });
    return json(200, { received: true, updated: r.updated });
  }
  if (event.type !== 'checkout.session.completed') return json(200, { received: true, skipped: event.type });
  const row = tipFromSession(event.data.object as unknown as Session, event.id, deps.links);
  if (!row) return json(200, { received: true, ignored: true });
  let { error } = await deps.save(row);
  // client_reference_id comes from the payer's URL: an unknown passenger must
  // not block the tip forever (FK violation → keep the tip, without the link).
  if (error && error.code === '23503' && row.passenger_id !== null) {
    deps.log('stripe_tip_unknown_passenger', { event: event.id, passenger_id: row.passenger_id });
    ({ error } = await deps.save({ ...row, passenger_id: null }));
  }
  if (error && error.code !== '23505') {
    deps.log('stripe_tip_insert_failed', { event: event.id, error: error.message });
    return json(500, { received: false }); // Stripe retries later
  }
  deps.log('stripe_tip_recorded', { event: event.id, amount_cents: row.amount_cents });
  return json(200, { received: true, recorded: !error });
}

if (import.meta.main) {
  const get = (k: string) => Deno.env.get(k);
  // The secret key is only needed by the SDK constructor; signature checks are offline.
  const stripe = new Stripe(get('STRIPE_SECRET_KEY') || 'sk_signature_only');
  const admin = createClient(get('SUPABASE_URL')!, get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });
  Deno.serve((req) => handle(req, {
    webhookSecret: get('STRIPE_WEBHOOK_SECRET'),
    links: gratuityLinkIds(get('AIRVALET_GRATUITY_PAYMENT_LINK_IDS')),
    stripe,
    save: async (row) => {
      const { error } = await admin.from('payments').insert(row);
      return { error: error ? { message: error.message, code: (error as { code?: string }).code } : null };
    },
    // Only AirValet tips are touched (car wash payments are never stored here).
    // Refunds only ever lower a tip: an older partial-refund event arriving
    // after the full refund never brings it back (Stripe does not order events).
    refund: async (pi, status, amountCents) => {
      let q = admin.from('payments').update({ status, amount_cents: amountCents })
        .eq('stripe_payment_intent_id', pi).eq('type', 'TIP');
      if (status === 'succeeded') q = q.neq('status', 'refunded').gt('amount_cents', amountCents);
      const { data, error } = await q.select('id');
      return { updated: Array.isArray(data) ? data.length : 0, error: error ? { message: error.message } : null };
    },
    log: (event, data) => console.log(JSON.stringify({ event, ...data })),
  }));
}
