// event-valet — Edge Function for the temporary Event Valet module.
//
// Routes (POST, path suffix):
//   /send     staff JWT  {ticket_id, kind: CHECKIN|REQUESTED|TIP, resend?}
//   /guest    public     {token, action: view|request}  (token = guest link)
//   /inbound  Twilio     incoming SMS ("READY")  — X-Twilio-Signature
//   /status   Twilio     delivery status callback — X-Twilio-Signature
//
// Deploy with --no-verify-jwt (Twilio and the guest page have no JWT);
// /send verifies the caller itself through event_valet_is_staff().
// SMS never leaves unless the event row has sms_enabled = true; while
// sms_test_only = true only sms_test_phones receive texts. Secrets are
// never logged or returned.

import { composeSms, Kind, maskLink, maskPhone, normalizePhone, parseInbound, twilioSend, TwilioCfg, validSignature } from './lib.ts';

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
  const ORIGINS = (env('EVENT_VALET_ALLOWED_ORIGINS') ?? 'https://airvalet.farberos.com').split(',').map((s) => s.trim()).filter(Boolean);
  const AUTH_TOKEN = env('TWILIO_AUTH_TOKEN');
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
  const secrets = [SERVICE, AUTH_TOKEN, env('TWILIO_API_KEY_SECRET')].filter(Boolean) as string[];
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
  async function sendFor(t: Json, ev: Json, kind: Kind, opts: { resend?: boolean; dedupe?: string } = {}): Promise<Json> {
    const base = { event_id: ev.id, ticket_id: t.id, direction: 'OUT', kind, phone_e164: t.phone_e164 };
    const skip = async (status: string) => {
      await insertMessage({ ...base, status, body: null });
      log('sms_skipped', { kind, status, ticket_no: t.ticket_no });
      return { status };
    };
    if (!ev.sms_enabled) return await skip('SKIPPED_SMS_OFF');
    if (ev.sms_test_only && !(ev.sms_test_phones ?? []).includes(t.phone_e164)) return await skip('SKIPPED_TEST_MODE');
    if (kind === 'TIP' && !ev.tip_enabled) return await skip('SKIPPED_TIP_OFF');
    if (MODE === 'live' && (!twilio || !PUBLIC_URL)) return await skip('NOT_CONFIGURED');

    // REQUESTED is keyed on the request time, so a car re-requested after an
    // undo gets a new confirmation; repeats of the same request never do.
    const dedupe = opts.dedupe ?? (opts.resend
      ? `${kind}:${t.id}:resend:${Math.floor(Date.now() / 30000)}`  // ≤ 1 resend / 30 s
      : kind === 'REQUESTED' ? `${kind}:${t.id}:${t.requested_at}` : `${kind}:${t.id}`);
    const row = await insertMessage({ ...base, status: 'SENDING', dedupe_key: dedupe });
    if (!row) return { status: 'DUPLICATE' };

    let link: string | null = null;
    if (kind === 'TIP' || (kind === 'CHECKIN' && ev.include_ticket_link)) {
      const tok = await rpc('event_valet_mint_guest_token', { p_ticket: t.id });
      link = `${SITE}/events/${ev.id}/t#${tok}`;
    }
    const body = composeSms(kind, t.ticket_no, link);
    const stored = maskLink(body, link);
    if (MODE === 'mock') {
      const sid = 'SMMOCK' + crypto.randomUUID().replace(/-/g, '').slice(0, 26);
      await patchMessage(row.id, { status: 'MOCK_SENT', twilio_sid: sid, body: stored });
      log('sms_mock', { kind, ticket_no: t.ticket_no, to: maskPhone(t.phone_e164) });
      return { status: 'MOCK_SENT', sid, mock_body: body };
    }
    const res = await twilioSend(twilio!, t.phone_e164, body, `${PUBLIC_URL}/status?mid=${row.id}`, fetchImpl);
    if (res.ok) {
      await patchMessage(row.id, { status: res.status.toUpperCase(), twilio_sid: res.sid, body: stored });
      log('sms_sent', { kind, ticket_no: t.ticket_no, to: maskPhone(t.phone_e164) });
      return { status: res.status.toUpperCase() };
    }
    const status = res.maybeSent ? 'UNCONFIRMED' : 'FAILED';
    await patchMessage(row.id, { status, error_code: res.code, error_message: res.message, body: stored });
    log('sms_failed', { kind, ticket_no: t.ticket_no, code: res.code });
    return { status, error_code: res.code };
  }

  // ── CORS ──
  function cors(req: Request): Record<string, string> {
    const o = req.headers.get('origin') ?? '';
    const ok = ORIGINS.includes(o) || /^http:\/\/(localhost|127\.0\.0\.1)(:\d+)?$/.test(o);
    return ok ? {
      'Access-Control-Allow-Origin': o, Vary: 'Origin',
      'Access-Control-Allow-Methods': 'POST, OPTIONS',
      'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-client-info',
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
    if (!['CHECKIN', 'REQUESTED', 'TIP'].includes(kind) || typeof b.ticket_id !== 'string') return json(req, 400, { error: 'BAD_REQUEST' });
    const x = await loadTicket(b.ticket_id);
    if (!x) return json(req, 404, { error: 'TICKET_NOT_FOUND' });
    if (kind === 'TIP' && x.t.status !== 'DELIVERED') return json(req, 409, { error: 'NOT_DELIVERED' });
    const out = await sendFor(x.t, x.ev, kind, { resend: b.resend === true });
    return json(req, 200, MODE === 'mock' ? out : { status: out.status, error_code: out.error_code });
  }

  async function routeGuest(req: Request) {
    const b = await req.json().catch(() => ({}));
    const action = b.action === 'request' ? 'request' : 'view';
    const r = await rpc('event_valet_guest', { p_token: String(b.token ?? ''), p_action: action });
    if (r?.state !== 'ok') return json(req, 200, { state: 'invalid' });
    if (r.changed) {
      const x = await loadTicket(r.ticket_id);
      if (x) await sendFor(x.t, x.ev, 'REQUESTED').catch((e) => log('sms_error', { msg: String(e).slice(0, 120) }));
    }
    const { ticket_id: _drop, ...pub } = r;
    return json(req, 200, pub);
  }

  async function verifyTwilio(req: Request, path: string): Promise<URLSearchParams | null> {
    const raw = await req.text();
    const params = new URLSearchParams(raw);
    const q = new URL(req.url).search;
    const ok = await validSignature(AUTH_TOKEN, `${PUBLIC_URL}${path}${q}`, params.entries(), req.headers.get('x-twilio-signature'));
    if (!ok) { log('bad_signature', { path }); return null; }
    if (ACCOUNT && params.get('AccountSid') !== ACCOUNT) return null;
    if (MG && params.get('MessagingServiceSid') && params.get('MessagingServiceSid') !== MG) return null;
    return params;
  }

  async function routeInbound(req: Request) {
    if (!AUTH_TOKEN || !PUBLIC_URL) return new Response('not configured', { status: 503 });
    const p = await verifyTwilio(req, '/inbound');
    if (!p) return new Response('forbidden', { status: 403 });
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

    const r = await rpc('event_valet_inbound_ready', { p_phone: phone, p_ticket_no: parsed.ticketNo });
    const t = r.ticket;
    await insertMessage({ event_id: t?.event_id ?? rows[0].event_id, ticket_id: t?.id ?? null, direction: 'IN', kind: 'READY',
      phone_e164: phone, body: String(p.get('Body') ?? '').slice(0, 500), twilio_sid: sid, status: r.result, dedupe_key: `IN:${sid}` });
    log('inbound_ready', { result: r.result, from: maskPhone(phone) });

    if (r.result === 'REQUESTED') {
      const x = await loadTicket(t.id);
      if (x) await sendFor(x.t, x.ev, 'REQUESTED');
    } else if (r.result === 'AMBIGUOUS' || r.result === 'NO_MATCH') {
      const x = await loadTicket((rows.find((y) => y.status !== 'DELIVERED') ?? rows[0]).id);
      // one clarification per inbound message (Twilio retries reuse the SID)
      if (x) await sendFor(x.t, x.ev, r.result, { dedupe: `${r.result}:${sid}` });
    }
    return twiml();
  }

  async function routeStatus(req: Request) {
    if (!AUTH_TOKEN || !PUBLIC_URL) return new Response('not configured', { status: 503 });
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

  return async function handle(req: Request): Promise<Response> {
    if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: cors(req) });
    if (req.method !== 'POST') return new Response('method not allowed', { status: 405 });
    const path = new URL(req.url).pathname.replace(/\/+$/, '');
    try {
      if (path.endsWith('/send')) return await routeSend(req);
      if (path.endsWith('/guest')) return await routeGuest(req);
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
}
