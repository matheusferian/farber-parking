// ride — Jet Runway Café rides (owner 2026-11-11). Deploy with --no-verify-jwt: staff actions are
// authorized by the caller's own JWT inside SQL (role check), tip actions are public by 1-day token.
//
// Staff (Authorization: Bearer <staff JWT>):
//   POST { action:'create', phone, ck, staff_name? }   → { result, id, status, sms }
//   POST { action:'onway', id, staff_name? }          → { result, status, sms }
//   POST { action:'done',  id, staff_name? }          → { result, status, sms }   (tip link texted)
//   POST { action:'cancel', id }                       → { result, status }
// Tip page (public, r.html):
//   POST { action:'tip_info', t }                      → { state: ok|expired|invalid }
//   POST { action:'tip_checkout', t, amount_cents, ck }→ { state, url? }
//
// SMS through the AirValet Twilio Messaging Service. Gate RIDES_SMS = off|test|live
// (RIDES_SMS_TEST = comma list of E.164 numbers for test). Opted-out numbers are never texted.
// Stripe: AIRVALET_STRIPE_CHECKOUT_KEY (Matt Solutions restricted key, same as the Valet Pass).

import { createClient } from 'npm:@supabase/supabase-js@2';
import { readSmsConfig } from '../_shared/sms/config.ts';
import { normalizePhoneE164 } from '../_shared/sms/phone.ts';
import { TwilioProvider } from '../_shared/sms/provider.ts';
import { rideSessionForm, rideText, smsAllowed, tipCents, type RideKind } from './lib.ts';
import { rideInboxOutbound } from '../_shared/sms/ride-inbox.ts';

const ORIGIN = 'https://airvalet.farberos.com';
const TOK_RE = /^[A-Za-z0-9_-]{12,64}$/;
const CK_RE = /^[A-Za-z0-9_-]{8,64}$/;
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

Deno.serve(async (req) => {
  const get = (k: string) => Deno.env.get(k);
  const origin = req.headers.get('origin');
  const headers: Record<string, string> = {
    'Content-Type': 'application/json', 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff',
    'Access-Control-Allow-Origin': origin && /^https:\/\/(airvalet\.farberos\.com|matheusferian\.github\.io)$/.test(origin) ? origin : ORIGIN,
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-client-info',
    Vary: 'Origin',
  };
  const reply = (status: number, body: unknown) => new Response(JSON.stringify(body), { status, headers });
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers });
  if (req.method !== 'POST') return reply(405, { result: 'ERROR' });

  let b: Record<string, unknown> = {};
  try { const raw = await req.text(); if (raw.length > 2048) return reply(413, { result: 'ERROR' }); b = JSON.parse(raw) || {}; } catch { b = {}; }
  const admin = createClient(get('SUPABASE_URL')!, get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });
  const log = (event: string, data: Record<string, unknown>) => console.log(JSON.stringify({ event, ...data }));

  // ── public: tip page ──
  if (b.action === 'tip_info' || b.action === 'tip_checkout') {
    const t = typeof b.t === 'string' && TOK_RE.test(b.t) ? b.t : '';
    const { data: claim } = await admin.rpc('airvalet_ride_tip_claim', { p_token: t || 'x' });
    const state = claim?.state === 'ok' ? 'ok' : claim?.state === 'expired' ? 'expired' : 'invalid';
    if (b.action === 'tip_info' || state !== 'ok') return reply(200, { state });
    const cents = tipCents(b.amount_cents);
    const ck = typeof b.ck === 'string' && CK_RE.test(b.ck) ? b.ck : '';
    if (!cents || !ck) return reply(200, { state, result: 'INVALID' });
    const key = get('AIRVALET_STRIPE_CHECKOUT_KEY') || '';
    if (!/^(rk|sk)_(live|test)_[A-Za-z0-9]{10,}$/.test(key)) return reply(200, { state, result: 'UNAVAILABLE' });
    const base = (/^(rk|sk)_test_/.test(key) && get('AIRVALET_STRIPE_API_BASE')) || 'https://api.stripe.com';
    const res = await fetch(base + '/v1/checkout/sessions', {
      method: 'POST',
      headers: { Authorization: 'Bearer ' + key, 'Content-Type': 'application/x-www-form-urlencoded', 'Idempotency-Key': `avride-${claim.ride_id}-${cents}-${ck}` },
      body: rideSessionForm(String(claim.ride_id), cents, (get('AIRVALET_RIDE_RETURN_URL') || ORIGIN + '/r')).toString(),
    }).catch(() => null);
    const j = res && res.ok ? await res.json().catch(() => null) : null;
    const url = j && typeof j.url === 'string' && /^https:\/\/checkout\.stripe\.com\//.test(j.url) ? j.url : '';
    if (!url) { log('ride.tip_checkout_failed', { ride: claim.ride_id }); return reply(200, { state, result: 'UNAVAILABLE' }); }
    return reply(200, { state, result: 'OK', url });
  }

  // ── staff ──
  const auth = req.headers.get('authorization') || '';
  if (!/^Bearer\s+\S+/.test(auth)) return reply(401, { result: 'AUTH' });
  const caller = createClient(get('SUPABASE_URL')!, get('SUPABASE_ANON_KEY')!, { global: { headers: { Authorization: auth } }, auth: { persistSession: false } });
  const name = typeof b.staff_name === 'string' ? b.staff_name.slice(0, 40) : null;

  const cfg = readSmsConfig(get);
  const testList = (get('RIDES_SMS_TEST') || '').split(',').map((s) => normalizePhoneE164(s)).filter((p) => p.valid).map((p) => (p as { e164: string }).e164);
  async function text(rideId: string, to: string, kind: RideKind, tipUrl?: string): Promise<string> {
    const body = rideText(kind, tipUrl);
    const gate = smsAllowed(get('RIDES_SMS') || 'off', testList, to);
    const record = (status: string, sid: string | null, err: string | null) =>
      admin.from('airvalet_ride_messages').insert({ ride_id: rideId, kind, body: tipUrl ? body.replace(/#.*/, '#********') : body, sid, status, error_code: err });
    if (!gate.ok) { await record('BLOCKED', null, gate.why || null); return 'BLOCKED_' + gate.why; }
    const { data: oo } = await admin.from('airvalet_sms_opt_outs').select('opted_out').eq('phone_e164', to).maybeSingle();
    if (oo?.opted_out) { await record('BLOCKED', null, 'OPTED_OUT'); return 'OPTED_OUT'; }
    if (!cfg.twilio) { await record('FAILED', null, 'NO_TWILIO'); return 'FAILED'; }
    const r = await new TwilioProvider({ ...cfg.twilio, timeoutMs: 10_000 }).send({ to, body });
    if (r.kind === 'accepted') {
      await record('SENT', r.sid, null);
      // Owner 2026-11-12: the same text in the Inbox conversation of the guest's car (no car → ride only).
      await rideInboxOutbound(admin, { rideId, kind, phone: to, body: tipUrl ? body.replace(/#.*/, '#********') : body, sid: r.sid, staffName: name }, log);
      return 'SENT';
    }
    await record(r.kind === 'unknown' ? 'UNKNOWN' : 'FAILED', null, r.errorCode);
    return r.kind === 'unknown' ? 'UNKNOWN' : 'FAILED';
  }

  try {
    if (b.action === 'create') {
      const ph = normalizePhoneE164(b.phone);
      if (!ph.valid) return reply(200, { result: 'BAD_PHONE' });
      const ck = typeof b.ck === 'string' && CK_RE.test(b.ck) ? b.ck : null;
      const { data, error } = await caller.rpc('airvalet_ride_create', { p_phone: (ph as { e164: string }).e164, p_client_key: ck, p_name: name });
      if (error) return reply(error.code === '42501' ? 403 : 500, { result: error.code === '42501' ? 'AUTH' : 'ERROR' });
      if (data?.result !== 'OK' || data.existing) return reply(200, data);
      const sms = await text(data.id, (ph as { e164: string }).e164, 'START');
      return reply(200, { ...data, sms });
    }
    if (b.action === 'onway' || b.action === 'done' || b.action === 'cancel') {
      const id = typeof b.id === 'string' && UUID_RE.test(b.id) ? b.id : '';
      if (!id) return reply(200, { result: 'NOT_FOUND' });
      const st = b.action === 'onway' ? 'ONWAY' : b.action === 'done' ? 'DONE' : 'CANCELLED';
      const { data, error } = await caller.rpc('airvalet_ride_set', { p_id: id, p_status: st, p_name: name });
      if (error) return reply(error.code === '42501' ? 403 : 500, { result: error.code === '42501' ? 'AUTH' : 'ERROR' });
      if (data?.result !== 'OK' || st === 'CANCELLED') return reply(200, data);
      const tipUrl = st === 'DONE' && data.tip_token ? `airvalet.farberos.com/r#${data.tip_token}` : undefined;
      const sms = await text(id, data.phone, st as RideKind, tipUrl);
      return reply(200, { result: 'OK', id, status: data.status, sms });
    }
    return reply(400, { result: 'BAD_ACTION' });
  } catch (e) {
    log('ride.error', { error: (e as Error)?.name || 'Error' });
    return reply(500, { result: 'ERROR' });
  }
});
