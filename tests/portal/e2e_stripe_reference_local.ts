// LOCAL ONLY end-to-end test of the flag-gated gratuity reference (Stage 1,
// 2026-10-27): the pass link built by airvalet_portal_view (flag
// gratuity_reference) → the client_reference_id Stripe would copy into the
// Checkout Session → the REAL stripe-webhook file (own process, fake whsec,
// localhost-only network) → payments row tied to the car. Also: per-amount
// links count only when their plink is in AIRVALET_GRATUITY_PAYMENT_LINK_IDS,
// status handling, dedupe. Nothing reaches Stripe.
//   deno run -A tests/portal/e2e_stripe_reference_local.ts
import Stripe from 'npm:stripe@17';

const DB = 'supabase_db_airvalet-portal-local';
const SUPA = 'http://127.0.0.1:56331';
const SRK = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImV4cCI6MTk4MzgxMjk5Nn0.EGIM96RAZx35lJzdJsyH-qQwv8Hdp7fsn3W0YpN81IU'; // local demo key
const SECRET = 'whsec_localfake_' + 'r'.repeat(24);
const GRAT = 'plink_localGratuityOther';     // the current link ("Other")
const P20 = 'plink_localGratuity20';         // a per-amount link that IS configured
const P40 = 'plink_localGratuity40unlisted'; // a per-amount link someone forgot to add to the env
const URL_ = 'http://127.0.0.1:8000/';
const stripe = new Stripe('sk_signature_only');
const RUN = Date.now();
const PAX = 960301;

let pass = 0, fail = 0;
const check = (c: unknown, l: string, x?: unknown) => { if (c) { pass++; console.log('ok  ' + l); } else { fail++; console.log('FAIL ' + l + (x === undefined ? '' : ' → ' + JSON.stringify(x))); } };
async function sql(q: string) {
  const o = await new Deno.Command('docker', { args: ['exec', '-i', DB, 'psql', '-U', 'postgres', '-d', 'postgres', '-v', 'ON_ERROR_STOP=1', '-At', '-c', q], stdout: 'piped', stderr: 'piped' }).output();
  if (!o.success) throw new Error(new TextDecoder().decode(o.stderr));
  return new TextDecoder().decode(o.stdout).trim();
}
async function post(type: string, obj: unknown, id: string) {
  const payload = JSON.stringify({ id, object: 'event', type, data: { object: obj } });
  const header = await stripe.webhooks.generateTestHeaderStringAsync({ payload, secret: SECRET });
  const r = await fetch(URL_, { method: 'POST', headers: { 'stripe-signature': header }, body: payload });
  const t = await r.text(); let j: any; try { j = JSON.parse(t); } catch { j = t; }
  return { status: r.status, body: j };
}
const ev = (n: string) => `evt_localref_${RUN}_${n}`;
// What Stripe puts in the session for a Payment Link opened with ?client_reference_id=…
function sessionFrom(link: string, plink: string, o: Record<string, unknown> = {}) {
  const ref = new URL(link).searchParams.get('client_reference_id');
  return { id: 'cs_localref_' + RUN + '_' + Math.random().toString(36).slice(2), object: 'checkout.session', payment_status: 'paid', payment_link: plink,
    amount_total: 2000, client_reference_id: ref, payment_intent: `pi_localref_${RUN}_${Math.random().toString(36).slice(2)}`, metadata: {}, ...o };
}
const view = async () => JSON.parse(await sql(`select (public.airvalet_portal_view(public.airvalet_pass_mint(${PAX}), 'stripe-ref-test') -> 'pass')::text`));

try { const l = Deno.listen({ hostname: '127.0.0.1', port: 8000 }); l.close(); } catch { console.log('SKIP: port 8000 busy'); Deno.exit(2); }
const saved = await sql(`select gratuity_reference || '|' || gratuity_links::text from public.airvalet_portal_settings`);
const [savedRef, savedLinks] = [saved.split('|')[0], saved.slice(saved.indexOf('|') + 1)];
const cleanup = `delete from public.payments where stripe_event_id like 'evt_localref_%'; delete from public.airvalet_pass_links where passenger_id = ${PAX};
  delete from public.airvalet_sms_enrollments where passenger_id = ${PAX}; delete from public.passengers where id = ${PAX};`;
await sql(cleanup);
await sql(`insert into public.passengers (id, ts, checkin_date, name, phone, ticket, status, ret, return_operator) values (${PAX}, 'x', now(), 'REF PAX', '3055556301', 'S1R-01', 'PENDING', '12/31/2030', 'MAKERS');
  insert into public.airvalet_sms_enrollments (passenger_id, phone_e164, device_id, consent_id)
  values (${PAX}, public.airvalet_sms_normalize_phone('3055556301'), (select id from public.airvalet_sms_devices where status = 'approved' order by decided_at limit 1), gen_random_uuid());`);

const fn = new URL('../../supabase/functions/stripe-webhook/index.ts', import.meta.url).pathname;
const child = new Deno.Command('deno', {
  args: ['run', '--allow-env', '--allow-read', '--allow-net=127.0.0.1,0.0.0.0,localhost', fn],
  env: { SUPABASE_URL: SUPA, SUPABASE_SERVICE_ROLE_KEY: SRK, STRIPE_WEBHOOK_SECRET: SECRET, AIRVALET_GRATUITY_PAYMENT_LINK_IDS: `${GRAT},${P20}`, STRIPE_SECRET_KEY: '' },
  stdout: 'piped', stderr: 'piped',
}).spawn();
let up = false;
for (let i = 0; i < 60 && !up; i++) { try { const r = await fetch(URL_); await r.body?.cancel(); up = r.status === 405; } catch { await new Promise((r) => setTimeout(r, 250)); } }
check(up, 'local stripe-webhook process up (GET → 405)');

try {
  // Flag OFF (default): today's behaviour, the tip has no car.
  await sql(`update public.airvalet_portal_settings set gratuity_reference = false, gratuity_links = '{}'`);
  let v = await view();
  check(!String(v.gratuity_url).includes('client_reference_id') && v.gratuity_amounts === null, 'flag off: pass link has no reference, no amounts');
  let t = await post('checkout.session.completed', sessionFrom(v.gratuity_url, GRAT), ev('off'));
  check(t.body?.recorded === true && await sql(`select coalesce(passenger_id::text, 'null') from public.payments where stripe_event_id = '${ev('off')}'`) === 'null', 'flag off: tip recorded, not tied to a car (as today)', t);

  // Flag ON: the same link now carries pax-<id>; the webhook ties the tip to the car.
  await sql(`update public.airvalet_portal_settings set gratuity_reference = true, gratuity_links = '{"10":"https://buy.stripe.com/localref10aa","20":"https://buy.stripe.com/localref20aa","40":"https://buy.stripe.com/localref40aa"}'`);
  v = await view();
  check(String(v.gratuity_url).endsWith(`?client_reference_id=pax-${PAX}`), 'flag on: Other link carries pax-<id>', v.gratuity_url);
  check(Array.isArray(v.gratuity_amounts) && v.gratuity_amounts.length === 3 && v.gratuity_amounts.every((g: any) => g.url.endsWith(`pax-${PAX}`)), 'flag on: $10/$20/$40 links carry pax-<id>');
  t = await post('checkout.session.completed', sessionFrom(v.gratuity_url, GRAT, { amount_total: 3700 }), ev('other'));
  check(t.body?.recorded === true && await sql(`select passenger_id || '|' || amount_cents || '|' || status from public.payments where stripe_event_id = '${ev('other')}'`) === `${PAX}|3700|succeeded`, 'Other ($37): tied to the car, succeeded', t);
  const l20 = v.gratuity_amounts.find((g: any) => g.amount === 20).url;
  t = await post('checkout.session.completed', sessionFrom(l20, P20, { amount_total: 2000 }), ev('20'));
  check(t.body?.recorded === true && await sql(`select passenger_id || '|' || amount_cents from public.payments where stripe_event_id = '${ev('20')}'`) === `${PAX}|2000`, '$20 link (plink in the env): recorded and tied to the car', t);
  const l40 = v.gratuity_amounts.find((g: any) => g.amount === 40).url;
  t = await post('checkout.session.completed', sessionFrom(l40, P40, { amount_total: 4000 }), ev('40'));
  check(t.body?.ignored === true, '$40 link whose plink is NOT in AIRVALET_GRATUITY_PAYMENT_LINK_IDS → ignored (add every plink before turning chips on)', t);

  // Status handling and dedupe
  const s20 = sessionFrom(l20, P20, { amount_total: 2000 });
  t = await post('checkout.session.completed', { ...s20, payment_status: 'unpaid' }, ev('unpaid'));
  check(t.body?.ignored === true, 'unpaid session → ignored');
  t = await post('checkout.session.completed', s20, ev('dup'));
  const t2 = await post('checkout.session.completed', s20, ev('dup'));
  check(t.body?.recorded === true && t2.body?.recorded === false && await sql(`select count(*) from public.payments where stripe_event_id = '${ev('dup')}'`) === '1', 'Stripe retry of the same event → one row');
  t = await post('checkout.session.completed', sessionFrom(l20.replace(`pax-${PAX}`, 'pax-999999998'), P20), ev('fk'));
  check(t.status === 200 && await sql(`select coalesce(passenger_id::text, 'null') from public.payments where stripe_event_id = '${ev('fk')}'`) === 'null', 'tampered reference (unknown car) → tip kept without the car, no retry loop');
  t = await post('checkout.session.completed', sessionFrom(l20.replace(`pax-${PAX}`, 'pax-abc'), P20), ev('junk'));
  check(t.body?.recorded === true && await sql(`select coalesce(passenger_id::text, 'null') from public.payments where stripe_event_id = '${ev('junk')}'`) === 'null', 'malformed reference → tip kept without the car');
  const pi = await sql(`select stripe_payment_intent_id from public.payments where stripe_event_id = '${ev('other')}'`);
  t = await post('charge.refunded', { object: 'charge', payment_intent: pi, amount: 3700, amount_refunded: 3700, refunded: true }, ev('refund'));
  check(t.body?.updated === 1 && await sql(`select status from public.payments where stripe_event_id = '${ev('other')}'`) === 'refunded', 'full refund of the referenced tip → refunded (out of the reports)');
  check(await sql(`select public.get_stripe_tips_for_date_cents((now() at time zone 'America/New_York')::date) >= 2000`) === 't', 'Closing Report RPC still sums the referenced tips (method STRIPE, succeeded)');
  // Known gap (not changed: decision 5): a second, different event for the SAME session would be a second row.
  const dupSess = sessionFrom(l20, P20);
  await post('checkout.session.completed', dupSess, ev('sameA')); await post('checkout.session.completed', dupSess, ev('sameB'));
  console.log('note same Checkout Session under two different event ids → ' + await sql(`select count(*) from public.payments where stripe_checkout_session_id = '${dupSess.id}'`) + ' rows (dedupe is per event id only)');
} finally {
  child.kill('SIGTERM'); await child.status;
  await sql(`update public.airvalet_portal_settings set gratuity_reference = ${savedRef}, gratuity_links = '${savedLinks.replace(/'/g, "''")}'::jsonb`);
  await sql(cleanup);
}
console.log(`\n${pass} passed, ${fail} failed`);
Deno.exit(fail ? 1 : 0);
