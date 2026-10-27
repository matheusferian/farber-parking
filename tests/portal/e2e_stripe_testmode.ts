// REAL Stripe TEST-MODE check of the Valet Pass gratuity (Stage 1, 2026-10-27).
// Started by tests/portal/e2e_stripe_testmode.sh, which provides: local functions
// serve (valet-pass with the owner's rk_test_ key, no API override), the real
// stripe-webhook file on :8000 with the `stripe listen` signing secret, and
// `stripe listen --forward-to http://127.0.0.1:8000/` (MATT SOLUTIONS, test mode).
// Never prints a key or a signing secret. Refuses anything but rk_test_.
// Env: STRIPE_TEST_ENV (key file), STRIPE_PROFILE (CLI project name), SKIP_PAY=1 to skip the
// browser payment step (the owner pays one $20 test session with card 4242 4242 4242 4242).

const DB = 'supabase_db_airvalet-portal-local';
const PASS_API = 'http://127.0.0.1:56331/functions/v1/valet-pass';
const PROFILE = Deno.env.get('STRIPE_PROFILE') || 'airvalet-matt';
const KEYFILE = Deno.env.get('STRIPE_TEST_ENV') || (Deno.env.get('HOME') + '/Dev/airvalet-local-secrets/stripe-test.env');
const PAX = 960501;
const RUN = Date.now();
const XFF = `10.${RUN % 250}.${(RUN >> 8) % 250}.9`;

const KEY = (/^AIRVALET_STRIPE_CHECKOUT_KEY=(\S+)$/m.exec(await Deno.readTextFile(KEYFILE)) || [])[1] || '';
if (!/^rk_test_/.test(KEY)) { console.log('STOP: the key file does not hold a restricted TEST key (rk_test_).'); Deno.exit(2); }

let pass = 0, fail = 0; const notes: string[] = [];
const check = (c: unknown, l: string, x?: unknown) => { if (c) { pass++; console.log('ok  ' + l); } else { fail++; console.log('FAIL ' + l + (x === undefined ? '' : ' → ' + JSON.stringify(x))); } };
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
async function sql(q: string) {
  const o = await new Deno.Command('docker', { args: ['exec', '-i', DB, 'psql', '-U', 'postgres', '-d', 'postgres', '-v', 'ON_ERROR_STOP=1', '-At', '-c', q], stdout: 'piped', stderr: 'piped' }).output();
  if (!o.success) throw new Error(new TextDecoder().decode(o.stderr));
  return new TextDecoder().decode(o.stdout).trim();
}
async function stripeApi(method: string, path: string, body?: Record<string, string>) {
  const r = await fetch('https://api.stripe.com' + path, { method, headers: { Authorization: 'Bearer ' + KEY, 'Content-Type': 'application/x-www-form-urlencoded' }, body: body ? new URLSearchParams(body).toString() : undefined });
  const j = await r.json().catch(() => null);
  return { status: r.status, body: j };
}
async function cli(args: string[]) {
  const o = await new Deno.Command('stripe', { args: [...args, '--project-name', PROFILE], stdout: 'piped', stderr: 'piped' }).output();
  return { ok: o.success, out: new TextDecoder().decode(o.stdout) };
}
async function pv(body: Record<string, unknown>) {
  const r = await fetch(PASS_API, { method: 'POST', headers: { 'Content-Type': 'application/json', 'x-forwarded-for': XFF }, body: JSON.stringify(body) });
  return { status: r.status, body: await r.json().catch(() => null) };
}
const tipsToday = async () => Number(await sql(`select public.get_stripe_tips_for_date_cents((now() at time zone 'America/New_York')::date)`));
const sid = (url: string) => (/\/(cs_test_[A-Za-z0-9]+)/.exec(url) || [])[1] || '';
async function waitRow(where: string, ms: number) {
  for (let t = 0; t < ms; t += 2000) { if (await sql(`select count(*) from public.payments where ${where}`) !== '0') return true; await sleep(2000); }
  return false;
}

const saved = await sql(`select gratuity_checkout_enabled || '|' || gratuity_reference from public.airvalet_portal_settings`);
const cleanup = `delete from public.payments where passenger_id = ${PAX} or stripe_checkout_session_id like 'cs_test_%'; delete from public.airvalet_pass_links where passenger_id = ${PAX};
  delete from public.airvalet_sms_enrollments where passenger_id = ${PAX}; delete from public.passengers where id = ${PAX};
  delete from public.airvalet_pass_rate where bucket like 'k:%' or bucket like 'g:%';`;
await sql(cleanup);
await sql(`insert into public.passengers (id, ts, checkin_date, name, phone, ticket, status, ret, return_operator) values (${PAX}, 'x', now(), 'STRIPE TESTMODE', '3055556501', 'TM-1027', 'DELIVERED', '12/31/2030', 'MAKERS');
  insert into public.airvalet_sms_enrollments (passenger_id, phone_e164, device_id, consent_id)
  values (${PAX}, public.airvalet_sms_normalize_phone('3055556501'), (select id from public.airvalet_sms_devices where status = 'approved' order by decided_at limit 1), gen_random_uuid());
  update public.airvalet_portal_settings set gratuity_checkout_enabled = true, gratuity_reference = false;`);
const TOKEN = await sql(`select public.airvalet_pass_mint(${PAX})`);
const t0 = await tipsToday();

try {
  // 1. Least privilege: the key creates and reads Checkout Sessions, and nothing else.
  const a = await pv({ t: TOKEN, action: 'gratuity_checkout', amount_cents: 2000, ck: 'ck_tm_pay_' + RUN, passenger_id: 1, ticket: 'HACK', client_reference_id: 'pax-1', amount_total: 1 });
  const payId = sid(String(a.body?.url || ''));
  check(a.body?.result === 'OK' && payId, '1. key can CREATE a Checkout Session (Checkout Sessions: Write)', a.body?.result);
  const s = await stripeApi('GET', '/v1/checkout/sessions/' + payId);
  check(s.status === 200, '1. key can READ its own sessions (reconciliation by session)', s.status);
  for (const [m, p, label] of [['GET', '/v1/charges?limit=1', 'list charges'], ['GET', '/v1/payment_intents?limit=1', 'list payment intents'], ['GET', '/v1/customers?limit=1', 'list customers'],
      ['GET', '/v1/balance', 'read balance'], ['POST', '/v1/refunds', 'create refunds'], ['GET', '/v1/payouts?limit=1', 'list payouts'], ['GET', '/v1/payment_links?limit=1', 'read Payment Links']] as [string, string, string][]) {
    const r = await stripeApi(m, p, m === 'POST' ? { payment_intent: 'pi_does_not_exist' } : undefined);
    check(r.status === 401 || r.status === 403, `1. key can NOT ${label} (${r.status})`);
  }
  // 2. The session as Stripe stores it: amount, ticket, metadata set by the server; test mode.
  const ss = s.body || {};
  check(ss.livemode === false, '2. test mode (livemode false)');
  check(ss.amount_total === 2000 && ss.currency === 'usd', '2. $20.00 USD (the browser\'s amount_total=1 ignored)', [ss.amount_total, ss.currency]);
  check(ss.client_reference_id === `pax-${PAX}` && ss.metadata?.passenger_id === String(PAX) && ss.metadata?.ticket === 'TM-1027' && ss.metadata?.source === 'AIRVALET',
    '2. ticket / passenger from the server (browser\'s pax-1 / HACK ignored)', [ss.client_reference_id, ss.metadata]);
  check(String(ss.success_url || '').endsWith('?gratuity=thanks') && !String(ss.success_url).includes(TOKEN), '2. return URL without the pass token');
  check(Array.isArray(ss.payment_method_types), '2. payment methods offered: ' + JSON.stringify(ss.payment_method_types));
  notes.push('payment methods on the session: ' + JSON.stringify(ss.payment_method_types));
  const again = await pv({ t: TOKEN, action: 'gratuity_checkout', amount_cents: 2000, ck: 'ck_tm_pay_' + RUN });
  check(sid(String(again.body?.url || '')) === payId, '2. same tap retried → the same real session (idempotency key)');
  for (const bad of [99, 50001, -100, 0]) check((await pv({ t: TOKEN, action: 'gratuity_checkout', amount_cents: bad, ck: 'ck_tm_bad_' + bad + RUN })).body?.result === 'INVALID', `2. amount ${bad} → INVALID (never reaches Stripe)`);
  check(await sql(`select count(*) from public.payments where passenger_id = ${PAX}`) === '0' && await tipsToday() === t0, '2. nothing counted before Stripe confirms a payment');

  // 3. Cancelled / abandoned: expired session → nothing recorded.
  const c = await pv({ t: TOKEN, action: 'gratuity_checkout', amount_cents: 500, ck: 'ck_tm_cancel_' + RUN });
  const cancelId = sid(String(c.body?.url || ''));
  const ex = await stripeApi('POST', `/v1/checkout/sessions/${cancelId}/expire`);
  check(ex.status === 200 && ex.body?.status === 'expired', '3. cancelled session expired in Stripe', ex.status);
  await sleep(8000);
  check(await sql(`select count(*) from public.payments where stripe_checkout_session_id = '${cancelId}'`) === '0' && await tipsToday() === t0, '3. cancelled → no tip recorded, Closing Report unchanged');

  // 4. Approved payment (owner pays the $20 session in a browser with test card 4242 4242 4242 4242).
  if (Deno.env.get('SKIP_PAY') !== '1') {
    console.log('\n>>> Open this TEST checkout and pay with card 4242 4242 4242 4242, any future date, any CVC, ZIP 33301:\n>>> ' + a.body.url + '\n>>> Waiting up to 8 minutes…\n');
    const got = await waitRow(`stripe_checkout_session_id = '${payId}'`, 8 * 60 * 1000);
    check(got, '4. approved payment → signed webhook received and recorded');
    if (got) {
      const row = await sql(`select passenger_id || '|' || coalesce(ticket, '') || '|' || amount_cents || '|' || status || '|' || method || '|' || type || '|' || stripe_event_id || '|' || coalesce(stripe_payment_intent_id, '') from public.payments where stripe_checkout_session_id = '${payId}'`);
      const [pid, ticket, cents, status, method, type, evt, pi] = row.split('|');
      check(pid === String(PAX) && ticket === 'TM-1027' && cents === '2000' && status === 'succeeded' && method === 'STRIPE' && type === 'TIP', '4. tied to the ticket: ' + [pid, ticket, cents, status].join(' / '));
      check(await tipsToday() - t0 === 2000, '4. Closing Report (Stripe Tips) +$20.00, once');
      // 5. Duplicate: Stripe re-sends the same event → still one row.
      const rs = await cli(['events', 'resend', evt]);
      await sleep(8000);
      check(rs.ok && await sql(`select count(*) from public.payments where stripe_checkout_session_id = '${payId}'`) === '1', '5. event re-sent by Stripe → still one row');
      check(await tipsToday() - t0 === 2000, '5. Closing Report still +$20.00 (no double count)');
      // 6. Refund (CLI, test mode) → out of the report.
      const rf = await cli(['refunds', 'create', '--payment-intent', pi]);
      let refunded = false;
      for (let t = 0; t < 60000 && !refunded; t += 2000) { refunded = await sql(`select status from public.payments where stripe_checkout_session_id = '${payId}'`) === 'refunded'; if (!refunded) await sleep(2000); }
      check(rf.ok && refunded && await tipsToday() === t0, '6. test refund → tip marked refunded, Closing Report back');
    }
  } else notes.push('SKIP_PAY=1: approved payment / resend / refund not run');

  // 7. Fallback: flag off → no session, the current link (printed QR) is what the pass offers.
  await sql(`update public.airvalet_portal_settings set gratuity_checkout_enabled = false`);
  const f = await pv({ t: TOKEN, action: 'gratuity_checkout', amount_cents: 2000, ck: 'ck_tm_off_' + RUN });
  const v = (await pv({ t: TOKEN })).body?.pass || {};
  check(f.body?.result === 'UNAVAILABLE' && v.gratuity_checkout === null && /^https:\/\/buy\.stripe\.com\/8x214mc/.test(String(v.gratuity_url)), '7. flag off → UNAVAILABLE; the pass offers the current link (8x214mc…) unchanged');
} finally {
  const [c0, r0] = saved.split('|');
  await sql(`update public.airvalet_portal_settings set gratuity_checkout_enabled = ${c0}, gratuity_reference = ${r0}`);
  await sql(cleanup);
}
for (const n of notes) console.log('note ' + n);
console.log(`\n${pass} passed, ${fail} failed`);
Deno.exit(fail ? 1 : 0);
