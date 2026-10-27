// LOCAL ONLY end-to-end test of the Valet Pass gratuity money paths (Stage 1,
// 2026-10-27), all flag-gated and OFF by default:
//   A. the printed-QR Payment Link (must keep working, no ticket, counted once);
//   B. the same link with ?client_reference_id=pax-<id> (flag gratuity_reference);
//   C. dynamic Checkout Sessions created by valet-pass (flag gratuity_checkout_enabled)
//      against tests/portal/stripe_checkout_mock.py — amount bounds, server-set
//      ticket/metadata (guest fields ignored), idempotency, rate limit;
// then the REAL stripe-webhook file (own process, fake whsec, localhost-only
// network) records each tip once, even with retries and a second event for the
// same session, and the Closing Report RPC counts each exactly once.
// Needs: local functions serve (valet-pass with AIRVALET_STRIPE_CHECKOUT_KEY=rk_test_localmock…,
// AIRVALET_STRIPE_API_BASE=http://host.docker.internal:8798) and the mock on 8798.
//   deno run -A tests/portal/e2e_stripe_reference_local.ts
import Stripe from 'npm:stripe@17';

const DB = 'supabase_db_airvalet-portal-local';
const SUPA = 'http://127.0.0.1:56331';
const PASS_API = SUPA + '/functions/v1/valet-pass';
const MOCK = 'http://127.0.0.1:8798';
const SRK = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImV4cCI6MTk4MzgxMjk5Nn0.EGIM96RAZx35lJzdJsyH-qQwv8Hdp7fsn3W0YpN81IU'; // local demo key
const SECRET = 'whsec_localfake_' + 'r'.repeat(24);
const QR = 'plink_localGratuityQR';          // the current link, also printed as QR codes
const URL_ = 'http://127.0.0.1:8000/';
const stripe = new Stripe('sk_signature_only');
const RUN = Date.now();
const PAX = 960301;
const XFF = `10.${RUN % 250}.${(RUN >> 8) % 250}.7`;

let pass = 0, fail = 0;
const check = (c: unknown, l: string, x?: unknown) => { if (c) { pass++; console.log('ok  ' + l); } else { fail++; console.log('FAIL ' + l + (x === undefined ? '' : ' → ' + JSON.stringify(x))); } };
async function sql(q: string) {
  const o = await new Deno.Command('docker', { args: ['exec', '-i', DB, 'psql', '-U', 'postgres', '-d', 'postgres', '-v', 'ON_ERROR_STOP=1', '-At', '-c', q], stdout: 'piped', stderr: 'piped' }).output();
  if (!o.success) throw new Error(new TextDecoder().decode(o.stderr));
  return new TextDecoder().decode(o.stdout).trim();
}
async function hook(type: string, obj: unknown, id: string) {
  const payload = JSON.stringify({ id, object: 'event', type, data: { object: obj } });
  const header = await stripe.webhooks.generateTestHeaderStringAsync({ payload, secret: SECRET });
  const r = await fetch(URL_, { method: 'POST', headers: { 'stripe-signature': header }, body: payload });
  const t = await r.text(); let j: any; try { j = JSON.parse(t); } catch { j = t; }
  return { status: r.status, body: j };
}
async function pv(body: Record<string, unknown>) {
  const r = await fetch(PASS_API, { method: 'POST', headers: { 'Content-Type': 'application/json', 'x-forwarded-for': XFF }, body: JSON.stringify(body) });
  return { status: r.status, body: await r.json().catch(() => null) };
}
const ev = (n: string) => `evt_localref_${RUN}_${n}`;
const rid = () => Math.random().toString(36).slice(2);
// What Stripe puts in the session for a Payment Link opened with (or without) ?client_reference_id=…
function linkSession(link: string, o: Record<string, unknown> = {}) {
  return { id: 'cs_localref_' + RUN + '_' + rid(), object: 'checkout.session', payment_status: 'paid', payment_link: QR, amount_total: 2000,
    client_reference_id: new URL(link).searchParams.get('client_reference_id'), payment_intent: `pi_localref_${RUN}_${rid()}`, metadata: {}, ...o };
}
const tipsToday = async () => Number(await sql(`select public.get_stripe_tips_for_date_cents((now() at time zone 'America/New_York')::date)`));
const rows = (w: string) => sql(`select count(*) from public.payments where ${w}`);

try { const l = Deno.listen({ hostname: '127.0.0.1', port: 8000 }); l.close(); } catch { console.log('SKIP: port 8000 busy'); Deno.exit(2); }
try { await (await fetch(MOCK + '/__reset', { method: 'POST' })).body?.cancel(); } catch { console.log('SKIP: Stripe mock not running on 8798'); Deno.exit(2); }
const saved = await sql(`select gratuity_reference || '|' || gratuity_checkout_enabled from public.airvalet_portal_settings`);
const cleanup = `delete from public.payments where stripe_event_id like 'evt_localref_%'; delete from public.airvalet_pass_links where passenger_id = ${PAX};
  delete from public.airvalet_sms_enrollments where passenger_id = ${PAX}; delete from public.passengers where id = ${PAX};
  delete from public.airvalet_pass_rate where bucket like 'k:%' or bucket like 'g:%';`;
await sql(cleanup);
await sql(`insert into public.passengers (id, ts, checkin_date, name, phone, ticket, status, ret, return_operator) values (${PAX}, 'x', now(), 'REF PAX', '3055556301', 'S1R-01', 'DELIVERED', '12/31/2030', 'MAKERS');
  insert into public.airvalet_sms_enrollments (passenger_id, phone_e164, device_id, consent_id)
  values (${PAX}, public.airvalet_sms_normalize_phone('3055556301'), (select id from public.airvalet_sms_devices where status = 'approved' order by decided_at limit 1), gen_random_uuid());`);
const TOKEN = await sql(`select public.airvalet_pass_mint(${PAX})`);
const view = async () => (await pv({ t: TOKEN })).body?.pass;

const fn = new URL('../../supabase/functions/stripe-webhook/index.ts', import.meta.url).pathname;
const child = new Deno.Command('deno', {
  args: ['run', '--allow-env', '--allow-read', '--allow-net=127.0.0.1,0.0.0.0,localhost', fn],
  env: { SUPABASE_URL: SUPA, SUPABASE_SERVICE_ROLE_KEY: SRK, STRIPE_WEBHOOK_SECRET: SECRET, AIRVALET_GRATUITY_PAYMENT_LINK_IDS: QR, STRIPE_SECRET_KEY: '' },
  stdout: 'piped', stderr: 'piped',
}).spawn();
let up = false;
for (let i = 0; i < 60 && !up; i++) { try { const r = await fetch(URL_); await r.body?.cancel(); up = r.status === 405; } catch { await new Promise((r) => setTimeout(r, 250)); } }
check(up, 'local stripe-webhook process up (GET → 405)');

try {
  const t0 = await tipsToday();
  // ── A. flags OFF (production today): the printed-QR link keeps working ──
  await sql(`update public.airvalet_portal_settings set gratuity_reference = false, gratuity_checkout_enabled = false`);
  let v = await view();
  check(v && !String(v.gratuity_url).includes('client_reference_id') && v.gratuity_checkout === null, 'flags off: current link, no reference, no checkout amounts');
  let a = await pv({ t: TOKEN, action: 'gratuity_checkout', amount_cents: 2000, ck: 'ck_off_' + RUN });
  check(a.body?.result === 'UNAVAILABLE', 'flags off: gratuity_checkout → UNAVAILABLE (nothing created)', a);
  check((await (await fetch(MOCK + '/__log')).json()).length === 0, 'flags off: no Checkout Session requested');
  const qr = linkSession('https://buy.stripe.com/localqr', { amount_total: 2500 });
  let t = await hook('checkout.session.completed', qr, ev('qr'));
  check(t.body?.recorded === true && await sql(`select coalesce(passenger_id::text, 'null') || '|' || amount_cents from public.payments where stripe_event_id = '${ev('qr')}'`) === 'null|2500',
    'printed QR payment ($25, no ticket) → recorded, not tied to a car', t);
  await hook('checkout.session.completed', qr, ev('qr'));                       // Stripe retry
  await hook('checkout.session.async_payment_succeeded', qr, ev('qr_async'));    // a second event, same session
  check(await rows(`stripe_checkout_session_id = '${qr.id}'`) === '1', 'printed QR: retry + second event for the same session → still one row');
  check(await tipsToday() - t0 === 2500, 'Closing Report RPC: the QR tip counted exactly once');

  // ── B. reference flag: same link, tied to the car ──
  await sql(`update public.airvalet_portal_settings set gratuity_reference = true`);
  v = await view();
  check(String(v.gratuity_url).endsWith(`?client_reference_id=pax-${PAX}`), 'reference on: link carries pax-<id>', v.gratuity_url);
  t = await hook('checkout.session.completed', linkSession(v.gratuity_url, { amount_total: 3700 }), ev('ref'));
  check(t.body?.recorded === true && await sql(`select passenger_id || '|' || amount_cents from public.payments where stripe_event_id = '${ev('ref')}'`) === `${PAX}|3700`, 'link + reference ($37): tied to the car');
  t = await hook('checkout.session.completed', linkSession(v.gratuity_url.replace(`pax-${PAX}`, 'pax-999999998')), ev('fk'));
  check(t.status === 200 && await sql(`select coalesce(passenger_id::text, 'null') from public.payments where stripe_event_id = '${ev('fk')}'`) === 'null', 'tampered link reference (unknown car) → tip kept without the car');

  // ── C. dynamic Checkout Sessions ──
  await sql(`update public.airvalet_portal_settings set gratuity_checkout_enabled = true, gratuity_reference = false`);
  v = await view();
  check(JSON.stringify(v.gratuity_checkout?.amounts) === '[5,10,20,40,50]' && v.gratuity_checkout?.min === 1 && v.gratuity_checkout?.max === 500, 'checkout on: $5 $10 $20 $40 $50 + Other ($1–$500)', v.gratuity_checkout);
  check(String(v.gratuity_url).startsWith('https://buy.stripe.com/') && !String(v.gratuity_url).includes('?'), 'checkout on: the current link (QR) is still returned unchanged as the fallback');
  for (const [amt, label] of [[99, 'below $1'], [50001, 'over $500'], [-500, 'negative'], [0, 'zero'], [12.5, 'not whole cents'], ['2000', 'a string']] as [unknown, string][]) {
    a = await pv({ t: TOKEN, action: 'gratuity_checkout', amount_cents: amt, ck: 'ck_bad_' + rid() + RUN });
    check(a.body?.result === 'INVALID', `amount ${label} → INVALID`, a.body);
  }
  check((await (await fetch(MOCK + '/__log')).json()).length === 0, 'invalid amounts never reach Stripe');
  const ck = 'ck_tap_' + RUN + '_aaaa';
  a = await pv({ t: TOKEN, action: 'gratuity_checkout', amount_cents: 2000, ck, client_reference_id: 'pax-1', passenger_id: 1, ticket: 'HACK', metadata: { passenger_id: '1' } });
  check(a.body?.result === 'OK' && String(a.body?.url).startsWith('https://checkout.stripe.com/'), '$20 tap → Checkout URL', a.body);
  let log = await (await fetch(MOCK + '/__log')).json();
  const f = log[0]?.form || {};
  check(f['line_items[0][price_data][unit_amount]'] === '2000' && f['line_items[0][price_data][currency]'] === 'usd' && f.mode === 'payment', 'session: $20.00 USD, one line, payment mode');
  check(f.client_reference_id === `pax-${PAX}` && f['metadata[passenger_id]'] === String(PAX) && f['metadata[ticket]'] === 'S1R-01' && f['metadata[source]'] === 'AIRVALET' && f['metadata[type]'] === 'TIP',
    'session: ticket / passenger / source set by the server; the guest\'s fields are ignored', f);
  check(f['payment_intent_data[metadata][passenger_id]'] === String(PAX), 'session: the payment intent carries the same metadata');
  check(f.success_url === 'http://127.0.0.1:8795/a?gratuity=thanks' && f.cancel_url === 'http://127.0.0.1:8795/a?gratuity=cancel' && !JSON.stringify(f).includes(TOKEN), 'session: return URLs back to the pass, no token sent to Stripe');
  check(!('payment_method_types[0]' in f), 'session: payment methods from the Stripe dashboard (Apple Pay / Google Pay when enabled)');
  check(log[0]?.key === `avtip-${await sql(`select id from public.airvalet_pass_links where passenger_id = ${PAX} and revoked_at is null`)}-2000-${ck}`, 'session: idempotency key per tap');
  const again = await pv({ t: TOKEN, action: 'gratuity_checkout', amount_cents: 2000, ck });
  log = await (await fetch(MOCK + '/__log')).json();
  check(again.body?.url === a.body?.url && log.length === 1, 'same tap retried → the same session (idempotent)');
  const other = await pv({ t: TOKEN, action: 'gratuity_checkout', amount_cents: 1250, ck: 'ck_other_' + RUN + '_bb' });
  log = await (await fetch(MOCK + '/__log')).json();
  check(other.body?.result === 'OK' && log[1]?.form['line_items[0][price_data][unit_amount]'] === '1250', 'Other $12.50 → session for 1250 cents');
  check(await sql(`select gratuity_clicks from public.airvalet_pass_links where passenger_id = ${PAX} and revoked_at is null`) === '3', 'each created session counts one gratuity click');
  let lim = '';
  for (let i = 0; i < 6; i++) lim = (await pv({ t: TOKEN, action: 'gratuity_checkout', amount_cents: 500, ck: 'ck_rate_' + i + '_' + RUN })).body?.result;
  check(lim === 'LIMITED', 'more than 6 sessions per link per 10 minutes → LIMITED', lim);
  check(!((await pv({ t: 'AAAAAAAAAAAAAAAAA', action: 'gratuity_checkout', amount_cents: 2000, ck: 'ck_bad_tok_' + RUN })).body?.url), 'unknown token → no session');

  // Stripe completes the $20 session → recorded with the car, once.
  const m = log[0].resp;
  const done = { ...m, payment_status: 'paid', payment_link: null, payment_intent: `pi_localref_${RUN}_dyn`, amount_total: 2000 };
  t = await hook('checkout.session.completed', done, ev('dyn'));
  check(t.body?.recorded === true && await sql(`select passenger_id || '|' || ticket || '|' || amount_cents || '|' || status from public.payments where stripe_event_id = '${ev('dyn')}'`) === `${PAX}|S1R-01|2000|succeeded`,
    'dynamic $20 paid → tied to the car and ticket', t);
  await hook('checkout.session.completed', done, ev('dyn'));
  await hook('checkout.session.async_payment_succeeded', done, ev('dyn_async'));
  check(await rows(`stripe_checkout_session_id = '${m.id}'`) === '1', 'dynamic: retry + async event for the same session → one row');
  const unpaid = await hook('checkout.session.completed', { ...log[1].resp, payment_status: 'unpaid', payment_link: null }, ev('unpaid'));
  check(unpaid.body?.ignored === true, 'session not paid (yet) → not recorded');
  const o1 = await hook('payment_intent.succeeded', { object: 'payment_intent', id: 'pi_x' }, ev('pi'));
  check(o1.body?.skipped === 'payment_intent.succeeded', 'payment_intent.* ignored (the session events are the source of truth)');
  check(await tipsToday() - t0 === 2500 + 3700 + 2000 + 2000, 'Closing Report RPC: QR + referenced link + dynamic tips, each once');
  t = await hook('charge.refunded', { object: 'charge', payment_intent: `pi_localref_${RUN}_dyn`, amount: 2000, amount_refunded: 2000, refunded: true }, ev('refund'));
  check(t.body?.updated === 1 && await tipsToday() - t0 === 2500 + 3700 + 2000, 'full refund → out of the Closing Report');
} finally {
  child.kill('SIGTERM'); await child.status;
  const [r0, c0] = saved.split('|');
  await sql(`update public.airvalet_portal_settings set gratuity_reference = ${r0}, gratuity_checkout_enabled = ${c0}`);
  await sql(cleanup);
  try { await (await fetch(MOCK + '/__reset', { method: 'POST' })).body?.cancel(); } catch { /* mock gone */ }
}
console.log(`\n${pass} passed, ${fail} failed`);
Deno.exit(fail ? 1 : 0);
