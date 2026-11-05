// event-valet — Edge Function for the temporary Event Valet module.
//
// Routes (POST, path suffix):
//   /send     staff JWT  {ticket_id, kind: CHECKIN|REQUESTED|TIP, resend?}
//   /guest    public     {token, action: view|request}  (token = guest link)
//   /inbound  Twilio     incoming SMS ("READY")  — X-Twilio-Signature
//   /status   Twilio     delivery status callback — X-Twilio-Signature
//   /staff/*  S710 + staff links (x-ev-key + x-ev-session) — docs/WATERMAKERS_S710_CONTRACT.md §4
//   /admin/report  ADMIN JWT — event report + card tips from Revenue (partner summary)
// handle.routedInbound(params): READY replies arriving on the shared AirValet
// number (twilio-inbound, behind EVENT_VALET_SMS_ROUTING=on) — null = not ours.
//
// Deploy with --no-verify-jwt (Twilio and the guest page have no JWT);
// /send verifies the caller itself through event_valet_is_staff().
// SMS never leaves unless the event row has sms_enabled = true; while
// sms_test_only = true only sms_test_phones receive texts. Secrets are
// never logged or returned.

import { sendPush } from './webpush.ts';
import { brandFor, CarOption, composeSms, composeStaffAlert, displayVehicle, Kind, maskLink, maskPhone, normalizePhone, parseInbound, timingSafeEqualStr, twilioSend, TwilioCfg, validSignature } from './lib.ts';

export type Env = (k: string) => string | undefined;
type Json = Record<string, any>;

const EMPTY_TWIML = '<?xml version="1.0" encoding="UTF-8"?><Response></Response>';

export function makeHandler(env: Env, fetchImpl: typeof fetch = fetch) {
  const SB = env('SUPABASE_URL')!;
  const SERVICE = env('SUPABASE_SERVICE_ROLE_KEY')!;
  const ANON = env('SUPABASE_ANON_KEY') ?? '';
  const MODE = env('EVENT_VALET_SMS_MODE') === 'mock' ? 'mock' : 'live';
  const PUBLIC_URL = (env('EVENT_VALET_PUBLIC_URL') ?? '').replace(/\/$/, '');
  const SITE = (env('EVENT_VALET_SITE_URL') ?? 'https://airvalet.farberos.com').replace(/\/$/, '');
  const REVENUE = (env('REVENUE_PUBLIC_BASE_URL') ?? '').replace(/\/$/, '');
  const PARTNER_KEY = env('EVENT_PAY_PARTNER_KEY') ?? '';
  const ORIGINS = (env('EVENT_VALET_ALLOWED_ORIGINS') ?? 'https://airvalet.farberos.com').split(',').map((s) => s.trim()).filter(Boolean);
  const AUTH_TOKEN = env('TWILIO_AUTH_TOKEN');
  // Webhook auth: X-Twilio-Signature (needs the Auth Token) OR, when the Auth
  // Token is not configured, a random key in the webhook URL (?k=…).
  const INBOUND_KEY = env('EVENT_VALET_INBOUND_KEY') ?? '';
  const ACCOUNT = env('TWILIO_ACCOUNT_SID') ?? '';
  const MG = env('TWILIO_MESSAGING_SERVICE_SID');
  const twilio: TwilioCfg | null = ACCOUNT && (AUTH_TOKEN || (env('TWILIO_API_KEY_SID') && env('TWILIO_API_KEY_SECRET')))
    ? {
      accountSid: ACCOUNT,
      authUser: env('TWILIO_API_KEY_SID') || ACCOUNT,
      authPass: env('TWILIO_API_KEY_SECRET') || AUTH_TOKEN!,
      messagingServiceSid: MG,
      from: env('TWILIO_PHONE_NUMBER'),
    }
    : null;
  const secrets = [SERVICE, AUTH_TOKEN, env('TWILIO_API_KEY_SECRET'), INBOUND_KEY, env('EVENT_VALET_VAPID_PRIVATE_JWK'), PARTNER_KEY].filter(Boolean) as string[];
  let VAPID: { privateJwk: JsonWebKey; publicKey: string; subject: string } | null = null;
  try {
    const jwk = env('EVENT_VALET_VAPID_PRIVATE_JWK'), pub = env('EVENT_VALET_VAPID_PUBLIC');
    if (jwk && pub) VAPID = { privateJwk: JSON.parse(jwk), publicKey: pub, subject: env('EVENT_VALET_VAPID_SUBJECT') ?? 'mailto:info@farberparking.com' };
  } catch { VAPID = null; }
  const webhookReady = !!PUBLIC_URL && !!ACCOUNT && (!!AUTH_TOKEN || INBOUND_KEY.length >= 32);
  const kq = INBOUND_KEY ? `&k=${encodeURIComponent(INBOUND_KEY)}` : '';
  const log = (event: string, data: Json = {}) => {
    let s = JSON.stringify({ fn: 'event-valet', event, ...data });
    for (const x of secrets) s = s.split(x).join('[redacted]');
    console.log(s);
  };

  // ── PostgREST (service role) ──
  async function db(path: string, init: RequestInit = {}, bearer = SERVICE): Promise<Response> {
    return await fetchImpl(`${SB}/rest/v1/${path}`, {
      ...init,
      headers: { apikey: bearer === SERVICE ? SERVICE : ANON, Authorization: `Bearer ${bearer}`, 'Content-Type': 'application/json', ...(init.headers ?? {}) },
    });
  }
  async function rpc(name: string, args: Json, bearer = SERVICE): Promise<any> {
    const r = await db(`rpc/${name}`, { method: 'POST', body: JSON.stringify(args) }, bearer);
    const txt = await r.text();
    if (!r.ok) throw new Error(`rpc ${name} ${r.status}: ${txt.slice(0, 200)}`);
    return txt ? JSON.parse(txt) : null;
  }
  async function loadTicket(id: string): Promise<{ t: Json; ev: Json } | null> {
    const r = await db(`event_valet_tickets?id=eq.${encodeURIComponent(id)}&select=*,ev:event_valet_events(*)`);
    const rows = r.ok ? await r.json() : [];
    if (!rows.length) return null;
    const { ev, ...t } = rows[0];
    return { t, ev };
  }
  async function insertMessage(row: Json): Promise<Json | null> {
    const r = await db('event_valet_messages?on_conflict=dedupe_key', {
      method: 'POST',
      headers: { Prefer: 'resolution=ignore-duplicates,return=representation' },
      body: JSON.stringify(row),
    });
    if (!r.ok) throw new Error(`insert message ${r.status}: ${(await r.text()).slice(0, 200)}`);
    const rows = await r.json();
    return rows[0] ?? null;
  }
  async function patchMessage(id: number, patch: Json) {
    await db(`event_valet_messages?id=eq.${id}`, { method: 'PATCH', body: JSON.stringify({ ...patch, updated_at: new Date().toISOString() }) });
  }

  // ── Send one SMS for a ticket (idempotent per ticket+kind) ──
  async function sendFor(t: Json, ev: Json, kind: Kind, opts: { resend?: boolean; dedupe?: string; options?: CarOption[] } = {}): Promise<Json> {
    const base = { event_id: ev.id, ticket_id: t.id, direction: 'OUT', kind, phone_e164: t.phone_e164 };
    const skip = async (status: string) => {
      await insertMessage({ ...base, status, body: null });
      log('sms_skipped', { kind, status, ticket: t.ticket_code });
      return { status };
    };
    if (!ev.sms_enabled) return await skip('SKIPPED_SMS_OFF');
    if (ev.sms_test_only && !(ev.sms_test_phones ?? []).includes(t.phone_e164)) return await skip('SKIPPED_TEST_MODE');
    if (kind === 'TIP' && !ev.tip_enabled) return await skip('SKIPPED_TIP_OFF');
    if (kind === 'THANKS' && !ev.thanks_enabled) return await skip('SKIPPED_THANKS_OFF');
    if (MODE === 'live' && (!twilio || !PUBLIC_URL)) return await skip('NOT_CONFIGURED');

    // REQUESTED is keyed on the request time, so a car re-requested after an
    // undo gets a new confirmation; repeats of the same request never do.
    const dedupe = opts.dedupe ?? (opts.resend
      ? `${kind}:${t.id}:resend:${Math.floor(Date.now() / 30000)}`  // ≤ 1 resend / 30 s
      : kind === 'REQUESTED' ? `${kind}:${t.id}:${t.requested_at}`
      : kind === 'READY' ? `${kind}:${t.id}:${t.ready_at}`
      : kind === 'ONWAY' ? `${kind}:${t.id}:${t.retrieving_at}` : `${kind}:${t.id}`);
    const row = await insertMessage({ ...base, status: 'SENDING', dedupe_key: dedupe });
    if (!row) return { status: 'DUPLICATE' };

    let link: string | null = null;
    // Tip SMS: a direct Stripe Payment Link when configured (per event: Matt Solutions
    // for Makers Air Halloween, Farber for Watermakers) —
    // short, and the guest goes straight to the optional tip.
    const tipSms = String(ev.tip_links?.sms ?? '');
    if (kind === 'TIP' && /^https:\/\/buy\.stripe\.com\/[A-Za-z0-9]+$/.test(tipSms)) {
      link = tipSms;
    } else if (kind === 'TIP' || kind === 'THANKS' || (kind === 'CHECKIN' && ev.include_ticket_link)) {
      const tok = await rpc('event_valet_mint_guest_token', { p_ticket: t.id });
      const short = brandFor(ev.id).short;
      // Short form drops the scheme (owner 2026-11-05); phones still turn the domain into a link.
      link = short ? `${SITE.replace(/^https?:\/\//, '')}${short}#${tok}` : `${SITE}/events/${ev.id}/t#${tok}`;
    }
    const body = composeSms(kind, t.ticket_code, link, opts.options ?? [], ev.id);
    const stored = maskLink(body, link);
    if (MODE === 'mock') {
      const sid = 'SMMOCK' + crypto.randomUUID().replace(/-/g, '').slice(0, 26);
      await patchMessage(row.id, { status: 'MOCK_SENT', twilio_sid: sid, body: stored });
      log('sms_mock', { kind, ticket: t.ticket_code, to: maskPhone(t.phone_e164) });
      return { status: 'MOCK_SENT', sid, mock_body: body };
    }
    const res = await twilioSend(twilio!, t.phone_e164, body, `${PUBLIC_URL}/status?mid=${row.id}${kq}`, fetchImpl);
    if (res.ok) {
      await patchMessage(row.id, { status: res.status.toUpperCase(), twilio_sid: res.sid, body: stored });
      log('sms_sent', { kind, ticket: t.ticket_code, to: maskPhone(t.phone_e164) });
      return { status: res.status.toUpperCase() };
    }
    const status = res.maybeSent ? 'UNCONFIRMED' : 'FAILED';
    await patchMessage(row.id, { status, error_code: res.code, error_message: res.message, body: stored });
    log('sms_failed', { kind, ticket: t.ticket_code, code: res.code });
    return { status, error_code: res.code };
  }

  // ── Operator alert: a guest asked for the car (SMS READY / guest link) ──
  async function alertStaff(t: Json, ev: Json, via: string) {
    await pushStaff(t, ev).catch((e) => log('push_error', { msg: String(e).slice(0, 120) }));
    const phones: string[] = (ev.staff_alert_phones ?? []).filter((p: string) => /^\+[1-9]\d{7,14}$/.test(p));
    if (!ev.sms_enabled || !phones.length) return;
    const body = composeStaffAlert(t as any, via, ev.id);
    for (const phone of phones) {
      const row = await insertMessage({ event_id: ev.id, ticket_id: t.id, direction: 'OUT', kind: 'STAFF_ALERT', phone_e164: phone,
        status: 'SENDING', body, dedupe_key: `ALERT:${t.id}:${t.requested_at}:${phone}` });
      if (!row) continue;
      if (MODE === 'mock') { await patchMessage(row.id, { status: 'MOCK_SENT', twilio_sid: 'SMMOCK' + crypto.randomUUID().replace(/-/g, '').slice(0, 26) }); continue; }
      if (!twilio) { await patchMessage(row.id, { status: 'NOT_CONFIGURED' }); continue; }
      const r = await twilioSend(twilio, phone, body, `${PUBLIC_URL}/status?mid=${row.id}${kq}`, fetchImpl);
      await patchMessage(row.id, r.ok ? { status: r.status.toUpperCase(), twilio_sid: r.sid } : { status: r.maybeSent ? 'UNCONFIRMED' : 'FAILED', error_code: r.code, error_message: r.message });
      log('staff_alert', { ticket: t.ticket_code, ok: r.ok });
    }
  }

  // Web Push to every operator device that enabled alerts (installed app).
  async function pushStaff(t: Json, ev: Json): Promise<{ devices: number; ok: number }> {
    if (!VAPID) return { devices: 0, ok: 0 };
    const r = await db(`event_valet_push_subs?event_id=eq.${encodeURIComponent(ev.id)}&failures=lt.5&select=id,endpoint,p256dh,auth,failures`);
    const subs: Json[] = r.ok ? await r.json() : [];
    const slot = t.slot_no ? String(t.slot_no).padStart(2, '0') : '--';
    const data = {
      title: `🚗 Car requested · #${t.ticket_code}`,
      body: `${t.vehicle} · Key ${slot} · ${t.parking_location || 'No location yet'}`,
      tag: `req-${t.id}`,
      url: `/events/${ev.id}/`,
    };
    let ok = 0;
    await Promise.all(subs.map(async (s) => {
      const res = await sendPush({ endpoint: s.endpoint, p256dh: s.p256dh, auth: s.auth }, data, VAPID!, fetchImpl);
      if (res.ok) ok++;
      const patch = res.ok ? { last_ok_at: new Date().toISOString(), failures: 0 } : { failures: res.gone ? 99 : (s.failures ?? 0) + 1 };
      await db(`event_valet_push_subs?id=eq.${s.id}`, { method: 'PATCH', body: JSON.stringify(patch) });
      log('push', { ok: res.ok, status: res.status, host: new URL(s.endpoint).host });
    }));
    return { devices: subs.length, ok };
  }

  // ── CORS ──
  function cors(req: Request): Record<string, string> {
    const o = req.headers.get('origin') ?? '';
    const ok = ORIGINS.includes(o) || /^http:\/\/(localhost|127\.0\.0\.1)(:\d+)?$/.test(o);
    return ok ? {
      'Access-Control-Allow-Origin': o, Vary: 'Origin',
      'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
      'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-client-info, x-ev-key, x-ev-session',
    } : {};
  }
  const json = (req: Request, status: number, body: Json) =>
    new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store', ...cors(req) } });
  const twiml = () => new Response(EMPTY_TWIML, { status: 200, headers: { 'Content-Type': 'text/xml' } });

  // ── Routes ──
  async function routeSend(req: Request) {
    const jwt = (req.headers.get('authorization') ?? '').replace(/^Bearer\s+/i, '');
    if (!jwt) return json(req, 401, { error: 'NOT_AUTHORIZED' });
    let staff = false;
    try { staff = (await rpc('event_valet_is_staff', {}, jwt)) === true; } catch { staff = false; }
    if (!staff) return json(req, 403, { error: 'NOT_AUTHORIZED' });
    const b = await req.json().catch(() => ({}));
    const kind = String(b.kind ?? '') as Kind;
    if (!['CHECKIN', 'REQUESTED', 'READY', 'TIP'].includes(kind) || typeof b.ticket_id !== 'string') return json(req, 400, { error: 'BAD_REQUEST' });
    const x = await loadTicket(b.ticket_id);
    if (!x) return json(req, 404, { error: 'TICKET_NOT_FOUND' });
    // never before the fact: READY only for a car that is ready, thank-you only after delivery
    if (kind === 'TIP' && x.t.status !== 'DELIVERED') return json(req, 409, { error: 'NOT_DELIVERED' });
    if (kind === 'READY' && x.t.status !== 'READY') return json(req, 409, { error: 'NOT_READY' });
    const out = await sendFor(x.t, x.ev, kind, { resend: b.resend === true });
    return json(req, 200, MODE === 'mock' ? out : { status: out.status, error_code: out.error_code });
  }

  // Staff "SEND TEST ALERT" button: one push to every enabled device.
  async function routePushTest(req: Request) {
    const jwt = (req.headers.get('authorization') ?? '').replace(/^Bearer\s+/i, '');
    let staff = false;
    try { staff = !!jwt && (await rpc('event_valet_is_staff', {}, jwt)) === true; } catch { staff = false; }
    if (!staff) return json(req, 403, { error: 'NOT_AUTHORIZED' });
    if (!VAPID) return json(req, 200, { devices: 0, ok: 0, error: 'PUSH_NOT_CONFIGURED' });
    const b = await req.json().catch(() => ({}));
    const evId = typeof b.event_id === 'string' ? b.event_id : '';
    const r = await pushStaff({ id: 'test', ticket_code: 'TEST', vehicle: 'TEST ALERT', slot_no: null, parking_location: 'HANGAR 19' }, { id: evId });
    return json(req, 200, r);
  }

  async function routeGuest(req: Request) {
    const b = await req.json().catch(() => ({}));
    const action = b.action === 'request' ? 'request' : 'view';
    const r = await rpc('event_valet_guest', { p_token: String(b.token ?? ''), p_action: action });
    if (r?.state !== 'ok') return json(req, 200, { state: r?.state === 'expired' ? 'expired' : 'invalid' });
    if (r.changed) {
      const x = await loadTicket(r.ticket_id);
      if (x) {
        await sendFor(x.t, x.ev, 'REQUESTED').catch((e) => log('sms_error', { msg: String(e).slice(0, 120) }));
        await alertStaff(x.t, x.ev, 'guest link').catch((e) => log('alert_error', { msg: String(e).slice(0, 120) }));
      }
    }
    const { ticket_id: _drop, ...pub } = r;
    // Events whose card tips run through Revenue (Watermakers): thank-you page data and
    // the Farber Parking Stripe tip page. Never the hook. Other events: unchanged reply.
    const ex = await loadTicket(r.ticket_id).catch(() => null);
    if (ex?.ev?.revenue_slug) {
      pub.event_id = ex.ev.id;
      pub.vehicle_text = displayVehicle(ex.t.vehicle);
      pub.thank_you = r.status === 'DELIVERED';
      pub.tip_links = null;
      pub.tip_url = ex.ev.tip_enabled && REVENUE && r.status === 'DELIVERED'
        ? `${REVENUE}/e/${encodeURIComponent(ex.ev.revenue_slug)}/tip?ref=${encodeURIComponent(r.ticket_id)}` : null;
    }
    return json(req, 200, pub);
  }

  async function verifyTwilio(req: Request, path: string): Promise<URLSearchParams | null> {
    const raw = await req.text();
    const params = new URLSearchParams(raw);
    const q = new URL(req.url).search;
    const k = new URL(req.url).searchParams.get('k') ?? '';
    const ok = (AUTH_TOKEN && await validSignature(AUTH_TOKEN, `${PUBLIC_URL}${path}${q}`, params.entries(), req.headers.get('x-twilio-signature')))
      || (!AUTH_TOKEN && INBOUND_KEY.length >= 32 && timingSafeEqualStr(k, INBOUND_KEY));
    if (!ok) { log('bad_webhook_auth', { path }); return null; }
    if (params.get('AccountSid') !== ACCOUNT) return null;
    if (MG && params.get('MessagingServiceSid') && params.get('MessagingServiceSid') !== MG) return null;
    return params;
  }

  async function routeInbound(req: Request) {
    if (!webhookReady) return new Response('not configured', { status: 503 });
    const p = await verifyTwilio(req, '/inbound');
    if (!p) return new Response('forbidden', { status: 403 });
    return await processInbound(p);
  }

  async function processInbound(p: URLSearchParams) {
    const sid = p.get('MessageSid') ?? p.get('SmsSid') ?? '';
    const phone = normalizePhone(p.get('From'));
    const parsed = parseInbound(p.get('Body') ?? '');
    if (!phone || !sid || parsed.type === 'keyword') return twiml();

    // Unknown numbers are never stored and never answered (normal AirValet
    // passengers / other senders are not this module's business).
    const known = await db(`event_valet_tickets?phone_e164=eq.${encodeURIComponent(phone)}&select=id,event_id,ticket_no,status,ev:event_valet_events!inner(is_open)&ev.is_open=eq.true&order=ticket_no.desc`);
    const rows: Json[] = known.ok ? await known.json() : [];
    if (!rows.length) return twiml();

    if (parsed.type === 'other') {
      const active = rows.find((r) => r.status !== 'DELIVERED') ?? rows[0];
      await insertMessage({ event_id: active.event_id, ticket_id: active.id, direction: 'IN', kind: 'INBOUND', phone_e164: phone,
        body: String(p.get('Body') ?? '').slice(0, 500), twilio_sid: sid, status: 'RECEIVED', dedupe_key: `IN:${sid}` });
      return twiml();
    }

    let ref = parsed.ticketRef;
    // "1" / "2" = position in the "Which vehicle…?" list, not a ticket number
    if (ref && /^\d{1,2}$/.test(ref)) {
      const first = await rpc('event_valet_inbound_ready', { p_phone: phone, p_ref: null });
      const opts: CarOption[] = first.options ?? [];
      if (first.result !== 'AMBIGUOUS') ref = null;            // single car (already handled) or none
      else ref = opts[parseInt(ref, 10) - 1]?.code ?? '__none__';
      if (first.result !== 'AMBIGUOUS' && first.result !== 'NONE' && first.result !== 'DELIVERED') {
        // the first call already requested the only active car
        return await afterInbound(first, phone, sid, p, rows);
      }
    }
    const r = await rpc('event_valet_inbound_ready', { p_phone: phone, p_ref: ref });
    return await afterInbound(r, phone, sid, p, rows);
  }

  async function afterInbound(r: Json, phone: string, sid: string, p: URLSearchParams, rows: Json[]) {
    const t = r.ticket;
    await insertMessage({ event_id: t?.event_id ?? rows[0].event_id, ticket_id: t?.id ?? null, direction: 'IN', kind: 'READY',
      phone_e164: phone, body: String(p.get('Body') ?? '').slice(0, 500), twilio_sid: sid, status: r.result, dedupe_key: `IN:${sid}` });
    log('inbound_ready', { result: r.result, from: maskPhone(phone) });

    if (r.result === 'REQUESTED') {
      const x = await loadTicket(t.id);
      if (x) {
        await sendFor(x.t, x.ev, 'REQUESTED');
        await alertStaff(x.t, x.ev, 'guest replied by text').catch((e) => log('alert_error', { msg: String(e).slice(0, 120) }));
      }
    } else if (r.result === 'AMBIGUOUS' || r.result === 'NO_MATCH') {
      const x = await loadTicket((rows.find((y) => y.status !== 'DELIVERED') ?? rows[0]).id);
      // one clarification per inbound message (Twilio retries reuse the SID)
      if (x) await sendFor(x.t, x.ev, r.result, { dedupe: `${r.result}:${sid}`, options: r.options ?? [] });
    }
    return twiml();
  }

  // ── READY on the shared AirValet number (called by twilio-inbound after ITS signature check) ──
  async function routedInbound(p: URLSearchParams): Promise<Response | null> {
    const phone = normalizePhone(p.get('From'));
    const sid = p.get('MessageSid') ?? p.get('SmsSid') ?? '';
    if (!phone || !sid) return null;
    if (parseInbound(p.get('Body') ?? '').type !== 'ready') return null;   // chat / keywords stay with AirValet
    const rc = await rpc('event_valet_route_check', { p_phone: phone });
    if (rc?.route === 'EVENT') { log('routed_inbound', { from: maskPhone(phone) }); return await processInbound(p); }
    if (rc?.route !== 'CROSS') return null;
    // Same phone also has an active Makers Air trip: never guess which car.
    const q = await db(`event_valet_tickets?phone_e164=eq.${encodeURIComponent(phone)}&status=neq.DELIVERED&event_id=eq.${encodeURIComponent(rc.eventId)}&select=id&limit=1`);
    const rows: Json[] = q.ok ? await q.json() : [];
    const x = rows[0] ? await loadTicket(rows[0].id) : null;
    if (!x) return null;
    await insertMessage({ event_id: x.ev.id, ticket_id: x.t.id, direction: 'IN', kind: 'READY', phone_e164: phone,
      body: String(p.get('Body') ?? '').slice(0, 500), twilio_sid: sid, status: 'CROSS', dedupe_key: `IN:${sid}` });
    await sendFor(x.t, x.ev, 'CROSS', { dedupe: `CROSS:${sid}` });
    log('routed_inbound_cross', { from: maskPhone(phone) });
    return twiml();
  }

  // ── S710 / staff links (contract §4) ──
  const STAFF_OPS: Record<string, 'GET' | 'POST'> = {
    session: 'POST', state: 'GET', search: 'GET', hold: 'POST', checkin: 'POST',
    'move-hook': 'POST', status: 'POST', edit: 'POST', 'cash-tip': 'POST',
  };
  const ERR_STATUS: Record<string, number> = {
    AUTH: 401, REVOKED: 401, OUTSIDE_WINDOW: 403, EVENT_CLOSED: 403, RATE_LIMIT: 429,
    HOOK_TAKEN: 409, TAKEN_BY: 409, DUPLICATE_CASH: 409, BAD_INPUT: 400, NOT_FOUND: 404,
  };
  const pad2 = (n: unknown) => String(n ?? '').padStart(2, '0');
  function staffMessage(code: string, d: Json): string {
    switch (code) {
      case 'AUTH': return 'This device or link is not set up. Ask your supervisor.';
      case 'REVOKED': return 'This device or link was turned off. Ask your supervisor.';
      case 'OUTSIDE_WINDOW': return 'Staff access is not open right now. Ask your supervisor.';
      case 'EVENT_CLOSED': return 'The event is closed.';
      case 'RATE_LIMIT': return 'Too many taps. Wait a few seconds and try again.';
      case 'HOOK_TAKEN': return d.why === 'full' ? 'ALL HOOKS ARE IN USE — ASK YOUR SUPERVISOR'
        : `HOOK ${pad2(d.hook)} ALREADY USED — ${d.suggestedHook ? `MOVE KEY TO HOOK ${pad2(d.suggestedHook)}` : 'CHOOSE ANOTHER'}`;
      case 'TAKEN_BY': return `${String(d.by ?? 'SOMEONE').toUpperCase()} IS ALREADY GETTING THIS CAR`;
      case 'DUPLICATE_CASH': return 'THIS CASH TIP WAS ALREADY RECORDED';
      case 'NOT_FOUND': return 'CAR NOT FOUND';
      case 'BAD_INPUT':
        if (d.why === 'not_your_pool') return 'THAT HOOK BELONGS TO THE S710 — CHOOSE ANOTHER';
        if (d.why === 'already_delivered') return 'THIS CAR WAS ALREADY DELIVERED';
        if (d.why === 'too_many_cars') return 'TOO MANY CARS FOR THIS PHONE NUMBER';
        return ({ phone: 'CHECK THE PHONE NUMBER', vehicle: 'ADD THE CAR MAKE OR THE PLATE', location: 'CHOOSE FRONT, SIDE OR BACK',
          keyStoredAt: 'CONFIRM THE KEY IS ON THE HOOK', amountCents: 'TIP MUST BE $1 TO $500', name: 'TYPE YOUR NAME (2 LETTERS OR MORE)',
          hook: 'CHOOSE A HOOK NUMBER', clientKey: 'PLEASE TRY AGAIN' } as Record<string, string>)[d.field] ?? 'SOMETHING IS MISSING — CHECK AND TRY AGAIN';
      default: return 'SOMETHING WENT WRONG — TRY AGAIN';
    }
  }
  const smsLabel = (st: string) => ['MOCK_SENT', 'ACCEPTED', 'QUEUED', 'SENDING', 'SENT', 'DELIVERED', 'DUPLICATE'].includes(st) ? 'SENT'
    : st.startsWith('SKIPPED') || st === 'NOT_CONFIGURED' ? 'OFF' : 'FAILED';

  async function routeStaff(req: Request, op: string) {
    if (STAFF_OPS[op] !== req.method) return json(req, 405, { error: 'BAD_INPUT', message: 'SOMETHING WENT WRONG — TRY AGAIN' });
    const token = req.headers.get('x-ev-key') ?? '';
    const session = req.headers.get('x-ev-session');
    let body: Json = {};
    if (req.method === 'POST') body = await req.json().catch(() => ({}));
    else {
      const u = new URL(req.url).searchParams;
      if (u.get('q') != null) body.q = u.get('q');
      if (u.get('pending') != null) body.pending = u.get('pending');
      if (u.get('since') != null) body.since = u.get('since');
    }
    if (typeof body !== 'object' || body === null || Array.isArray(body)) body = {};
    const r = await db('rpc/event_valet_staff', { method: 'POST', body: JSON.stringify({
      p_token: token, p_session: session && /^[0-9a-f-]{36}$/i.test(session) ? session : null, p_op: op, p_body: body }) });
    const txt = await r.text();
    if (!r.ok) {
      let e: Json = {}; try { e = JSON.parse(txt); } catch { /* not json */ }
      const code = String(e.message ?? '');
      if (!(code in ERR_STATUS)) { log('staff_error', { op, status: r.status, msg: txt.slice(0, 160) }); return json(req, 500, { error: 'SERVER_ERROR', message: staffMessage('', {}) }); }
      let d: Json = {}; try { d = e.details ? JSON.parse(e.details) : {}; } catch { d = {}; }
      if (code === 'AUTH' || code === 'REVOKED') log('staff_denied', { op, code });
      return json(req, ERR_STATUS[code], { error: code, message: staffMessage(code, d), ...d });
    }
    const out: Json = txt ? JSON.parse(txt) : {};
    const notify = out.notify as string | undefined;
    delete out.notify;
    if (notify && !out.replayed && out.ticketId) {
      const x = await loadTicket(out.ticketId);
      if (x) {
        const kind = (notify === 'CHECKIN' ? 'CHECKIN' : notify) as Kind;
        const s = await sendFor(x.t, x.ev, kind).catch((err) => { log('sms_error', { msg: String(err).slice(0, 120) }); return { status: 'FAILED' }; });
        out.sms = { [notify === 'CHECKIN' ? 'welcome' : notify.toLowerCase()]: smsLabel(String(s.status)) };
      }
    }
    return json(req, 200, out);
  }

  // ── Admin report: event_valet_admin_report (role checked in SQL with the caller's JWT) + Revenue card tips ──
  async function routeAdminReport(req: Request) {
    const jwt = (req.headers.get('authorization') ?? '').replace(/^Bearer\s+/i, '');
    if (!jwt) return json(req, 401, { error: 'NOT_AUTHORIZED' });
    const b = await req.json().catch(() => ({}));
    const r = await db('rpc/event_valet_admin_report', { method: 'POST', body: JSON.stringify({ p_event: String(b.event_id ?? '') }) }, jwt);
    if (!r.ok) return json(req, r.status === 400 || r.status === 403 ? 403 : r.status, { error: 'NOT_AUTHORIZED' });
    const rep: Json = await r.json();
    rep.cards = { available: false, error: 'NOT_CONFIGURED' };
    const slug = rep.event?.revenueSlug;
    if (slug && REVENUE && PARTNER_KEY) {
      try {
        const pr = await fetchImpl(`${REVENUE}/api/event-pay/${encodeURIComponent(slug)}/partner/summary`, {
          headers: { 'x-event-partner-key': PARTNER_KEY, accept: 'application/json' }, signal: AbortSignal.timeout(4000) });
        rep.cards = pr.ok ? { available: true, ...(await pr.json()) } : { available: false, error: `REVENUE_${pr.status}` };
      } catch {
        rep.cards = { available: false, error: 'REVENUE_UNAVAILABLE' };
      }
    }
    return json(req, 200, rep);
  }

  async function routeStatus(req: Request) {
    if (!webhookReady) return new Response('not configured', { status: 503 });
    const p = await verifyTwilio(req, '/status');
    if (!p) return new Response('forbidden', { status: 403 });
    const mid = new URL(req.url).searchParams.get('mid');
    const sid = p.get('MessageSid') ?? '';
    const st = (p.get('MessageStatus') ?? '').toUpperCase().replace(/[^A-Z_]/g, '').slice(0, 20);
    if (mid && /^\d+$/.test(mid) && sid && st) {
      await db(`event_valet_messages?id=eq.${mid}&twilio_sid=eq.${encodeURIComponent(sid)}`, {
        method: 'PATCH',
        body: JSON.stringify({ status: st, error_code: p.get('ErrorCode') || null, updated_at: new Date().toISOString() }),
      });
    }
    return new Response(null, { status: 204 });
  }

  const handle = async function handle(req: Request): Promise<Response> {
    if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: cors(req) });
    const path = new URL(req.url).pathname.replace(/\/+$/, '');
    const staff = path.match(/\/staff\/([a-z-]+)$/);
    if (req.method !== 'POST' && !(staff && req.method === 'GET')) return new Response('method not allowed', { status: 405 });
    try {
      if (staff) return await routeStaff(req, staff[1]);
      if (path.endsWith('/admin/report')) return await routeAdminReport(req);
      if (path.endsWith('/send')) return await routeSend(req);
      if (path.endsWith('/guest')) return await routeGuest(req);
      if (path.endsWith('/push-test')) return await routePushTest(req);
      if (path.endsWith('/inbound')) return await routeInbound(req);
      if (path.endsWith('/status')) return await routeStatus(req);
      return new Response('not found', { status: 404 });
    } catch (e) {
      log('error', { path: path.split('/').pop(), msg: String((e as Error)?.message ?? e).slice(0, 200) });
      // Twilio must not retry-storm: inbound errors still answer 200 with empty TwiML.
      if (path.endsWith('/inbound')) return twiml();
      return json(req, 500, { error: 'SERVER_ERROR' });
    }
  };
  return Object.assign(handle, { routedInbound });
}
