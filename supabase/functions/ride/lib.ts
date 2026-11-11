// Jet Runway Café rides — pure helpers (texts, gates, Stripe form). See index.ts.

export type RideKind = 'START' | 'ONWAY' | 'DONE';

// Plain GSM-7 (straight quotes, no emoji, no em dash) so each text stays one segment.
export function rideText(kind: RideKind, tipUrl?: string | null): string {
  switch (kind) {
    case 'START':
      // Owner 2026-11-11: reply READY or call our number (155 chars, one segment).
      return "Makers Air Valet: enjoy Jet Runway Cafe! When you're ready for your ride back to Makers Air, reply READY or call (954) 352-1010. Reply STOP to opt out";
    case 'ONWAY':
      return "Makers Air Valet: we're on our way! Please wait outside Jet Runway Cafe, about 5 min.";
    case 'DONE':
      return 'Thanks for riding with Makers Air Valet! A tip for your driver is always appreciated' + (tipUrl ? `: ${tipUrl}` : '.');
  }
}

// RIDES_SMS gate (owner 2026-11-11: test on the owner's number first):
//   off  → nothing is sent;  test → only numbers in RIDES_SMS_TEST;  live → any number.
export function smsAllowed(mode: string, testList: string[], to: string): { ok: boolean; why?: string } {
  const m = (mode || 'off').trim().toLowerCase();
  if (m === 'live') return { ok: true };
  if (m === 'test') return testList.includes(to) ? { ok: true } : { ok: false, why: 'TEST_ONLY' };
  return { ok: false, why: 'OFF' };
}

export const TIP_PRESETS = [500, 1000, 2000];
export function tipCents(v: unknown): number | null {
  return typeof v === 'number' && Number.isInteger(v) && v >= 100 && v <= 50000 ? v : null;
}

// Stripe Checkout for a ride tip (Matt Solutions restricted key, same as the Valet Pass gratuity).
// Metadata source/type make stripe-webhook record it as an AirValet TIP (ticket "JET RUNWAY", no passenger).
export function rideSessionForm(rideId: string, cents: number, returnUrl: string): URLSearchParams {
  const f = new URLSearchParams();
  const md: Record<string, string> = { source: 'AIRVALET', type: 'TIP', channel: 'RIDE', ticket: 'JET RUNWAY', ride_id: rideId };
  f.set('mode', 'payment');
  f.set('line_items[0][quantity]', '1');
  f.set('line_items[0][price_data][currency]', 'usd');
  f.set('line_items[0][price_data][unit_amount]', String(cents));
  f.set('line_items[0][price_data][product_data][name]', 'Driver tip · Makers Air Valet');
  f.set('client_reference_id', 'ride-' + rideId);
  for (const [k, v] of Object.entries(md)) { f.set(`metadata[${k}]`, v); f.set(`payment_intent_data[metadata][${k}]`, v); }
  f.set('payment_intent_data[description]', 'Makers Air Valet driver tip · Jet Runway');
  f.set('success_url', returnUrl + '?gratuity=thanks');
  f.set('cancel_url', returnUrl + '?gratuity=cancel');
  return f;
}
