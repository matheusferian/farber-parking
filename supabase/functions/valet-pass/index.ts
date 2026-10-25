// valet-pass — public API of the Makers Air Valet passenger portal:
// https://airvalet.farberos.com/a#<token>  (owner R1, 2026-10-25).
//
// The token lives in the URL fragment, so it never reaches any server log or
// Referer. pass.html POSTs it here as JSON. This is the ONLY place the token
// is validated (SHA-256 lookup in SQL). Unknown, malformed, revoked, expired
// links — and every link while the portal is OFF — get { state: 'expired' }.
//
//   POST { t }                                   → { state, pass }    (view)
//   POST { t, action: 'request', kind, reason?, date?, time?, carrier?, note?, ck }
//                                                → { state, result }  (passenger request)
//   POST { t, action: 'messages' }               → { state, messages } (valet chat thread)
//   POST { t, action: 'send', body, ck }         → { state, result }  (chat message, no SMS)
//
// Requests are stored PENDING; nothing operational changes until staff
// approve in AirValet. A new request notifies staff (iPad push / Super Admin
// SMS copy, both optional) in the background. Never returns the ticket,
// phone, key location or internal ids.
//
// Deploy with --no-verify-jwt (passengers have no login). Never logs the
// token, the body or the client address. Throttling is server-side in SQL,
// keyed by a salted hash of the client address (never the raw IP).

import { createClient } from 'npm:@supabase/supabase-js@2';
import { readSmsConfig } from '../_shared/sms/config.ts';
import { makeRedactor } from '../_shared/sms/sanitize.ts';
import { notifyEvent } from '../_shared/notify/notify.ts';
import { makeNotifyDeps } from '../_shared/notify/runtime.ts';
import { isGsm7 } from '../_shared/sms/templates.ts';

declare const EdgeRuntime: { waitUntil(p: Promise<unknown>): void } | undefined;

const DEFAULT_ORIGINS = ['https://airvalet.farberos.com'];
const TOKEN_RE = /^[A-Za-z0-9]{17}$/;
const CK_RE = /^[A-Za-z0-9_-]{16,64}$/;
const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;
const TIME_RE = /^([01]\d|2[0-3]):[0-5]\d$/;
const MAX_BODY = 2048;

const enc = new TextEncoder();
async function clientKey(req: Request): Promise<string | null> {
  const ip = (req.headers.get('x-forwarded-for') || '').split(',')[0].trim() || req.headers.get('x-real-ip') || '';
  if (!ip) return null;
  const salt = Deno.env.get('AIRVALET_PASS_RATE_SALT') || Deno.env.get('SUPABASE_URL') || 'airvalet';
  const d = new Uint8Array(await crypto.subtle.digest('SHA-256', enc.encode(salt + '|' + ip)));
  return Array.from(d.slice(0, 12), (b) => b.toString(16).padStart(2, '0')).join('');
}

// Free text from the passenger: one line, GSM-7 only (no emoji), capped.
export function cleanText(v: unknown, max: number): string | null {
  if (typeof v !== 'string') return null;
  const s = Array.from(v.replace(/\s+/g, ' ').trim())
    .map((ch) => (isGsm7(ch) ? ch : ch.normalize('NFD').replace(/[̀-ͯ]/g, '')))
    .filter((ch) => ch.length === 1 && isGsm7(ch) && ch !== '\n' && ch !== '\r').join('').slice(0, max).trim();
  return s || null;
}

// Chat text: GSM-7 only (no emoji), line breaks kept (max 4 in a row), capped.
export function cleanChat(v: unknown): string {
  if (typeof v !== 'string') return '';
  return Array.from(v.replace(/\r\n?/g, '\n').replace(/\n{3,}/g, '\n\n').trim())
    .map((ch) => (isGsm7(ch) ? ch : ch.normalize('NFD').replace(/[\u0300-\u036f]/g, '')))
    .filter((ch) => ch.length === 1 && isGsm7(ch) && ch !== '\r').join('').slice(0, 600).trim();
}

Deno.serve(async (req) => {
  const origins = (Deno.env.get('AIRVALET_PASS_ORIGINS') || '').split(',').map((s) => s.trim()).filter(Boolean);
  const allowed = origins.length ? origins : DEFAULT_ORIGINS;
  const origin = req.headers.get('origin');
  const headers: Record<string, string> = {
    'Content-Type': 'application/json',
    'Cache-Control': 'no-store',
    'Referrer-Policy': 'no-referrer',
    'X-Content-Type-Options': 'nosniff',
    'X-Robots-Tag': 'noindex, nofollow',
    'Access-Control-Allow-Origin': origin && allowed.includes(origin) ? origin : allowed[0],
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    'Access-Control-Allow-Headers': 'content-type',
    Vary: 'Origin',
  };
  const reply = (status: number, body: unknown) => new Response(JSON.stringify(body), { status, headers });
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers });
  if (req.method !== 'POST') return reply(405, { state: 'error' });

  let body: Record<string, unknown> = {};
  try {
    const raw = await req.text();
    if (raw.length > MAX_BODY) return reply(413, { state: 'error' });
    const parsed = JSON.parse(raw);
    body = parsed && typeof parsed === 'object' ? parsed : {};
  } catch {
    body = {};
  }
  // Malformed tokens still go through SQL so they are throttled and answered
  // exactly like an unknown token (no shortcut, no oracle).
  const token = typeof body.t === 'string' && TOKEN_RE.test(body.t) ? body.t : '';
  const get = (k: string) => Deno.env.get(k);
  const admin = createClient(get('SUPABASE_URL')!, get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });
  const client = await clientKey(req);

  if (body.action === 'request') {
    const kind = body.kind === 'RETURN_CHANGE' || body.kind === 'CAR_WASH' ? body.kind : '';
    const date = typeof body.date === 'string' && DATE_RE.test(body.date) ? body.date : null;
    const time = typeof body.time === 'string' && TIME_RE.test(body.time) ? body.time : null;
    const ck = typeof body.ck === 'string' && CK_RE.test(body.ck) ? body.ck : '';
    const { data, error } = await admin.rpc('airvalet_portal_request', {
      p_token: token, p_client: client, p_kind: kind,
      p_reason: typeof body.reason === 'string' ? body.reason : null,
      p_date: date, p_time: time,
      p_carrier: cleanText(body.carrier, 40), p_note: cleanText(body.note, 280), p_client_key: ck,
    });
    if (error || !data) return reply(503, { state: 'error' });
    if (data.state === 'limited') return reply(429, { state: 'limited' });
    if (data.state !== 'ok') return reply(200, { state: 'expired' });
    if (data.result === 'OK' && !data.duplicate && data.request_id) {
      const cfg = readSmsConfig(get);
      const redact = makeRedactor([get('SUPABASE_SERVICE_ROLE_KEY'), get('AIRVALET_VAPID_PRIVATE_JWK'), cfg.twilio?.apiKeySecret]);
      const log = (event: string, d: Record<string, unknown>) => console.log(redact(JSON.stringify({ event, ...d })));
      const job = notifyEvent(makeNotifyDeps(admin, cfg, get, log), 'PASS_REQUEST', String(data.request_id));
      if (typeof EdgeRuntime !== 'undefined') EdgeRuntime.waitUntil(job); else job.catch(() => {});
    }
    return reply(200, { state: 'ok', result: data.result });
  }

  if (body.action === 'messages') {
    const { data, error } = await admin.rpc('airvalet_portal_messages', { p_token: token, p_client: client });
    if (error || !data) return reply(503, { state: 'error' });
    if (data.state === 'limited') return reply(429, { state: 'limited' });
    if (data.state !== 'ok') return reply(200, { state: 'expired' });
    return reply(200, { state: 'ok', messages: data.messages });
  }

  if (body.action === 'send') {
    const ck = typeof body.ck === 'string' && CK_RE.test(body.ck) ? body.ck : '';
    const text = cleanChat(body.body);
    const { data, error } = await admin.rpc('airvalet_portal_send_message', { p_token: token, p_client: client, p_body: text, p_client_key: ck });
    if (error || !data) return reply(503, { state: 'error' });
    if (data.state === 'limited') return reply(429, { state: 'limited' });
    if (data.state !== 'ok') return reply(200, { state: 'expired' });
    if (data.result === 'OK' && !data.duplicate && data.message_id) {
      const cfg = readSmsConfig(get);
      const redact = makeRedactor([get('SUPABASE_SERVICE_ROLE_KEY'), get('AIRVALET_VAPID_PRIVATE_JWK'), cfg.twilio?.apiKeySecret]);
      const log = (event: string, d: Record<string, unknown>) => console.log(redact(JSON.stringify({ event, ...d })));
      const job = notifyEvent(makeNotifyDeps(admin, cfg, get, log), 'GUEST_MESSAGE', String(data.message_id));
      if (typeof EdgeRuntime !== 'undefined') EdgeRuntime.waitUntil(job); else job.catch(() => {});
    }
    return reply(200, { state: 'ok', result: data.result });
  }

  const { data, error } = await admin.rpc('airvalet_portal_view', { p_token: token, p_client: client });
  if (error || !data) return reply(503, { state: 'error' });
  if (data.state === 'limited') return reply(429, { state: 'limited' });
  if (data.state !== 'ok') return reply(200, { state: 'expired' });
  return reply(200, { state: 'ok', pass: data.pass });
});
