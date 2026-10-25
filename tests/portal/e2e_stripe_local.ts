// LOCAL ONLY end-to-end test of supabase/functions/stripe-webhook/index.ts:
// runs the REAL function file as its own process (NOT the shared functions
// server) on port 8000 with a FAKE whsec and network limited to localhost
// (it cannot reach Stripe), signs events offline with the Stripe SDK, and
// checks the rows in the local DB.
//   deno run -A tests/portal/e2e_stripe_local.ts
import Stripe from 'npm:stripe@17';

const DB = 'supabase_db_airvalet-portal-local';
const SUPA = 'http://127.0.0.1:56331';
const SRK = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImV4cCI6MTk4MzgxMjk5Nn0.EGIM96RAZx35lJzdJsyH-qQwv8Hdp7fsn3W0YpN81IU'; // local demo key
const SECRET = 'whsec_localfake_' + 'q'.repeat(24);
const GRAT = 'plink_localGratuity1';
const URL_ = 'http://127.0.0.1:8000/';
const stripe = new Stripe('sk_signature_only');
const RUN = Date.now();

let pass = 0, fail = 0;
const check = (c: unknown, l: string, x?: unknown) => { if (c) { pass++; console.log('ok  ' + l); } else { fail++; console.log('FAIL ' + l + (x === undefined ? '' : ' → ' + JSON.stringify(x))); } };
async function sql(q: string) {
  const o = await new Deno.Command('docker', { args: ['exec', '-i', DB, 'psql', '-U', 'postgres', '-d', 'postgres', '-v', 'ON_ERROR_STOP=1', '-At', '-c', q], stdout: 'piped', stderr: 'piped' }).output();
  if (!o.success) throw new Error(new TextDecoder().decode(o.stderr));
  return new TextDecoder().decode(o.stdout).trim();
}
async function post(type: string, obj: unknown, id: string, opts: { secret?: string; timestamp?: number; noSig?: boolean } = {}) {
  const payload = JSON.stringify({ id, object: 'event', type, data: { object: obj } });
  const header = await stripe.webhooks.generateTestHeaderStringAsync({ payload, secret: opts.secret ?? SECRET, ...(opts.timestamp ? { timestamp: opts.timestamp } : {}) });
  const r = await fetch(URL_, { method: 'POST', headers: opts.noSig ? {} : { 'stripe-signature': header }, body: payload });
  const t = await r.text(); let j: any; try { j = JSON.parse(t); } catch { j = t; }
  return { status: r.status, body: j };
}
const ev = (n: string) => `evt_localdeep_${RUN}_${n}`;
const sess = (o: Record<string, unknown>) => ({ id: 'cs_localdeep_' + RUN + '_' + Math.random().toString(36).slice(2), object: 'checkout.session', payment_status: 'paid', payment_link: GRAT, amount_total: 1500, client_reference_id: 'pax-934001', payment_intent: `pi_localdeep_${RUN}_1`, metadata: {}, ...o });

// port must be free (never reuse something else's listener)
try { const l = Deno.listen({ hostname: '127.0.0.1', port: 8000 }); l.close(); } catch { console.log('SKIP: port 8000 busy'); Deno.exit(2); }
await sql(`delete from public.payments where stripe_event_id like 'evt_localdeep_%'; delete from public.passengers where id = 934001;
  insert into public.passengers (id, ts, checkin_date, name, phone, ticket, status) values (934001, 'deep', now(), 'TIP PAX', '3055550690', 'X-TIP-1', 'DELIVERED');`);

const fn = new URL('../../supabase/functions/stripe-webhook/index.ts', import.meta.url).pathname;
const child = new Deno.Command('deno', {
  args: ['run', '--allow-env', '--allow-read', '--allow-net=127.0.0.1,0.0.0.0,localhost', fn],
  env: { SUPABASE_URL: SUPA, SUPABASE_SERVICE_ROLE_KEY: SRK, STRIPE_WEBHOOK_SECRET: SECRET, AIRVALET_GRATUITY_PAYMENT_LINK_IDS: GRAT, STRIPE_SECRET_KEY: '' },
  stdout: 'piped', stderr: 'piped',
}).spawn();
let up = false;
for (let i = 0; i < 60 && !up; i++) { try { const r = await fetch(URL_); await r.body?.cancel(); up = r.status === 405; } catch { await new Promise((r) => setTimeout(r, 250)); } }
check(up, 'local stripe-webhook process up (GET → 405)');

try {
  const t1 = await post('checkout.session.completed', sess({}), ev('a'));
  check(t1.status === 200 && t1.body?.recorded === true, 'signed gratuity-link checkout → recorded', t1);
  check(await sql(`select passenger_id || '|' || amount_cents || '|' || status || '|' || type from public.payments where stripe_event_id = '${ev('a')}'`) === '934001|1500|succeeded|TIP', 'payments row: passenger, $15.00, succeeded, TIP');
  const t2 = await post('checkout.session.completed', sess({}), ev('a'));
  check(t2.status === 200 && t2.body?.recorded === false, 'Stripe retry (same event id) → 200, not recorded twice', t2);
  check(await sql(`select count(*) from public.payments where stripe_event_id = '${ev('a')}'`) === '1', '… one row');
  const t3 = await post('checkout.session.completed', sess({}), ev('b'), { secret: 'whsec_wrong_' + 'z'.repeat(24) });
  check(t3.status === 400, 'wrong signing secret → 400', t3);
  const t4 = await post('checkout.session.completed', sess({}), ev('c'), { noSig: true });
  check(t4.status === 400, 'missing signature → 400', t4);
  const t5 = await post('checkout.session.completed', sess({}), ev('d'), { timestamp: Math.floor(Date.now() / 1000) - 3600 });
  check(t5.status === 400, 'replayed event signed 1 h ago → 400 (tolerance)', t5);
  const t6 = await post('checkout.session.completed', sess({ payment_link: 'plink_carwash999' }), ev('e'));
  check(t6.body?.ignored === true, 'other Payment Link (car wash) → ignored', t6);
  const t7 = await post('checkout.session.completed', sess({ payment_status: 'unpaid' }), ev('f'));
  check(t7.body?.ignored === true, 'unpaid session → ignored', t7);
  const t8 = await post('checkout.session.completed', sess({ payment_link: null, metadata: { source: 'AIRVALET', type: 'TIP', passenger_id: '934001', ticket: 'X-TIP-1' }, client_reference_id: null, payment_intent: `pi_localdeep_${RUN}_2` }), ev('g'));
  check(t8.body?.recorded === true && await sql(`select ticket from public.payments where stripe_event_id='${ev('g')}'`) === 'X-TIP-1', 'AirValet checkout (metadata) → recorded with ticket', t8);
  const t9 = await post('checkout.session.completed', sess({ client_reference_id: 'pax-999999999' }), ev('h'));
  check(t9.status === 500, 'unknown passenger id (FK) → 500 so Stripe retries (documented)', t9);
  const r1 = await post('charge.refunded', { object: 'charge', payment_intent: `pi_localdeep_${RUN}_1`, amount: 1500, amount_refunded: 500, refunded: false }, ev('r1'));
  check(r1.body?.updated === 1 && await sql(`select amount_cents || '|' || status from public.payments where stripe_event_id='${ev('a')}'`) === '1000|succeeded', 'partial refund → tip lowered to $10.00', r1);
  const r2 = await post('charge.refunded', { object: 'charge', payment_intent: `pi_localdeep_${RUN}_1`, amount: 1500, amount_refunded: 1500, refunded: true }, ev('r2'));
  check(r2.body?.updated === 1 && await sql(`select status from public.payments where stripe_event_id='${ev('a')}'`) === 'refunded', 'full refund → tip refunded', r2);
  const r3 = await post('charge.refunded', { object: 'charge', payment_intent: 'pi_not_a_tip', amount: 900, amount_refunded: 900, refunded: true }, ev('r3'));
  check(r3.body?.updated === 0, 'refund of a non-tip payment touches nothing', r3);
  const o1 = await post('payment_intent.succeeded', { object: 'payment_intent' }, ev('o1'));
  check(o1.body?.skipped === 'payment_intent.succeeded', 'other event types skipped', o1);
} finally {
  child.kill('SIGTERM');
  await child.status;
  await sql(`delete from public.payments where stripe_event_id like 'evt_localdeep_%'; delete from public.passengers where id = 934001;`);
}
console.log(`\n${pass} passed, ${fail} failed`);
Deno.exit(fail ? 1 : 0);
