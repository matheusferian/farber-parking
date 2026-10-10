// Twilio → AirValet webhooks (status callback + inbound SMS), as pure
// handlers so they can be tested without a server. Both:
//   * reject anything without a valid X-Twilio-Signature (403);
//   * are idempotent (Twilio retries webhooks);
//   * never echo request data or secrets back.

import { isValidTwilioSignature } from './twilio-signature.ts';
import { normalizePhoneE164 } from './phone.ts';
import { sanitizeProviderText } from './sanitize.ts';

export type WebhookStore = {
  applyStatus(sid: string, status: string, errorCode: string | null, errorMessage: string | null, messageId: string | null): Promise<string>;
  recordInbound(sid: string, fromE164: string, body: string, messagingServiceSid: string | null, keyword: Keyword | null):
    Promise<{ message_id: string; inserted: boolean; passenger_id: number | null; match_method: string }>;
};

export type WebhookDeps = {
  authToken: string | undefined;
  publicUrl: string;                  // exact URL configured in Twilio for this webhook
  store: WebhookStore;
  expectedMessagingServiceSid: string | undefined; // REQUIRED: other services' traffic is ignored
  log?: (event: string, data: Record<string, unknown>) => void;
};

export type Keyword = 'STOP' | 'START' | 'HELP';

// Twilio's default opt-out / help keywords. Opt-IN is deliberately narrower:
// only the exact words START / UNSTOP re-subscribe. Twilio's default opt-in
// list also contains YES, so Twilio may label a conversational "Yes" (answer
// to "can you confirm your return date?") as OptOutType=START — that label is
// IGNORED here: a "yes" is just a message, never consent.
// STOP stays generous (Twilio's OptOutType=STOP or any STOP word) — erring
// toward opting out is always safe.
const STOP_WORDS = ['STOP', 'STOPALL', 'UNSUBSCRIBE', 'CANCEL', 'END', 'QUIT', 'REVOKE', 'OPTOUT'];
const START_WORDS = ['START', 'UNSTOP'];
const HELP_WORDS = ['HELP', 'INFO'];

export function classifyKeyword(body: string, optOutType: string | null): Keyword | null {
  const t = (optOutType || '').toUpperCase();
  const w = body.trim().toUpperCase().replace(/[^A-Z]/g, '');
  if (t === 'STOP' || STOP_WORDS.includes(w)) return 'STOP';
  if (START_WORDS.includes(w)) return 'START';
  if (t === 'HELP' || HELP_WORDS.includes(w)) return 'HELP';
  return null;
}

const STATUS_VALUES = new Set(['accepted', 'queued', 'sending', 'sent', 'delivered', 'undelivered', 'failed']);
const SID_RE = /^(SM|MM)[0-9a-zA-Z]{32}$/;
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

async function readSigned(deps: WebhookDeps, req: Request): Promise<URLSearchParams | Response> {
  if (req.method !== 'POST') return new Response('method not allowed', { status: 405 });
  const type = req.headers.get('content-type') || '';
  if (!type.includes('application/x-www-form-urlencoded')) return new Response('unsupported media type', { status: 415 });
  const raw = await req.text();
  if (raw.length > 20_000) return new Response('payload too large', { status: 413 });
  const params = new URLSearchParams(raw);
  const url = deps.publicUrl + new URL(req.url).search;
  const ok = await isValidTwilioSignature(deps.authToken, url, params.entries(), req.headers.get('x-twilio-signature'));
  if (!ok) {
    deps.log?.('twilio.signature_invalid', {});
    return new Response('forbidden', { status: 403 });
  }
  const svc = params.get('MessagingServiceSid');
  if (!deps.expectedMessagingServiceSid || svc !== deps.expectedMessagingServiceSid) {
    deps.log?.('twilio.foreign_service', {});
    return new Response('ignored', { status: 200 });
  }
  return params;
}

export async function handleStatusCallback(deps: WebhookDeps, req: Request): Promise<Response> {
  const params = await readSigned(deps, req);
  if (params instanceof Response) return params;
  const sid = params.get('MessageSid') || '';
  const status = (params.get('MessageStatus') || '').toLowerCase();
  if (!SID_RE.test(sid) || !STATUS_VALUES.has(status)) return new Response('ignored', { status: 200 });
  const errorCode = params.get('ErrorCode') || null;
  const errorMessage = params.get('ErrorMessage') ? sanitizeProviderText(params.get('ErrorMessage')!) : null;
  // ?mid=<our message id> is part of the StatusCallback URL we gave Twilio
  // (and therefore of the signed URL): lets an unconfirmed send adopt its SID.
  const mid = new URL(req.url).searchParams.get('mid');
  const messageId = mid && UUID_RE.test(mid) ? mid : null;
  try {
    const result = await deps.store.applyStatus(sid, status, errorCode, errorMessage, messageId);
    deps.log?.('twilio.status', { sid, status, result });
    return new Response(null, { status: 204 });
  } catch {
    // 5xx → Twilio retries the callback later; the DB step is idempotent.
    deps.log?.('twilio.status_error', { sid, status });
    return new Response('temporary error', { status: 503 });
  }
}

const EMPTY_TWIML = '<?xml version="1.0" encoding="UTF-8"?><Response></Response>';

export async function handleInbound(deps: WebhookDeps, req: Request): Promise<Response> {
  const params = await readSigned(deps, req);
  if (params instanceof Response) return params;
  const twiml = () => new Response(EMPTY_TWIML, { status: 200, headers: { 'Content-Type': 'text/xml' } });
  const sid = params.get('MessageSid') || '';
  const from = normalizePhoneE164(params.get('From') || '');
  if (!SID_RE.test(sid) || !from.valid) return twiml();
  const body = (params.get('Body') || '').slice(0, 1600);
  const keyword = classifyKeyword(body, params.get('OptOutType'));
  try {
    const r = await deps.store.recordInbound(sid, from.e164, body, params.get('MessagingServiceSid'), keyword);
    deps.log?.('twilio.inbound', { sid, inserted: r.inserted, matched: r.match_method, keyword });
    // Empty TwiML: no auto-reply from AirValet. STOP/HELP replies come from
    // Twilio Advanced Opt-Out on the Messaging Service.
    return twiml();
  } catch {
    deps.log?.('twilio.inbound_error', { sid });
    return new Response('temporary error', { status: 503 });
  }
}
