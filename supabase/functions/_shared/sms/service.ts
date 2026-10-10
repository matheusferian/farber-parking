// sendAirValetSms() — the single server-side entry point for every AirValet
// SMS. Callers (the send-sms Edge Function) never touch Twilio directly.
//
// Guarantees:
//   * never throws — always resolves to a SendResult, so an SMS problem can
//     never break the valet flow that triggered it;
//   * one Twilio call per idempotency key (atomic DB claim, see migration);
//   * no automatic retry when Twilio may already have sent the message;
//   * every attempt that reaches the claim step leaves an audit row.

import { normalizePhoneE164 } from './phone.ts';
import { countSegments, MessageType, PassengerCtx, RenderEnv, renderMessage, Role, Template, TemplateError, TEMPLATES } from './templates.ts';
import type { SendOutcome, SmsProvider } from './provider.ts';

export type SmsMode = 'disabled' | 'mock' | 'allowlist' | 'live';

export type Passenger = PassengerCtx & { id: number; phone: string | null };

export type ClaimArgs = {
  idempotencyKey: string; passengerId: number; ticket: string | null; phoneE164: string;
  messageType: MessageType; templateKey: string; templateVersion: string; body: string;
  segments: number; provider: 'twilio' | 'mock'; sentBy: string | null; sentByName: string | null;
  deviceKeyHash: string | null; // hex SHA-256 of the sending device's key; the DB checks it is APPROVED
};
export type ClaimRow = { message_id: string; claimed: boolean; status: string; provider_message_sid: string | null; error_code: string | null };
export type ResultArgs = {
  messageId: string; status: 'accepted' | 'queued' | 'sending' | 'sent' | 'failed' | 'send_unknown';
  sid: string | null; messagingServiceSid: string | null; errorCode: string | null; errorMessage: string | null; attempts: number;
};

export interface SmsStore {
  getPassenger(id: number): Promise<Passenger | null>;
  claim(a: ClaimArgs): Promise<ClaimRow>;
  markResult(a: ResultArgs): Promise<string>;
  markOptedOut(phoneE164: string, source: string): Promise<void>;
  // Mints a NEW passenger link (previous one revoked) and returns the
  // plaintext token once; null when the service is no longer open.
  mintPassLink(passengerId: number): Promise<string | null>;
  // Flags sends left without a provider answer as UNCONFIRMED (alerts).
  reconcile?(): Promise<number>;
}

export type SendInput = {
  passengerId: number;
  type: string;
  eventRef?: string;      // default per type; 'resend:<uuid>' for an explicit resend
  customBody?: string;    // free-text types (REPLY, CUSTOM_OPERATIONAL) only
  actor: { userId: string | null; role: Role | null; name?: string | null };
  deviceKeyHash?: string | null;
};

export type SendResult = {
  ok: boolean;
  status: string;
  messageId?: string;
  sid?: string | null;
  duplicate?: boolean;
  error?: { code: string; message: string };
};

export type SendDeps = {
  mode: SmsMode;
  store: SmsStore;
  provider: SmsProvider;
  allowlist: string[];             // E.164 numbers allowed in 'allowlist' mode
  statusCallbackUrl?: string;      // only for the real provider
  templates?: Record<string, Template>;
  renderEnv?: RenderEnv;           // extra template variables (server config)
  passBaseUrl?: string | null;     // e.g. https://farberos.com/a#
  now?: () => Date;
  sleep?: (ms: number) => Promise<void>;
  log?: (event: string, data: Record<string, unknown>) => void;
};

const EVENT_REF_RE = /^[A-Za-z0-9:_-]{1,80}$/;
// Templated texts use the server's own event reference, so the same message
// can never be sent twice by accident. An explicit resend (e.g. the phone was
// corrected) is a deliberate ADMIN/MANAGER action: 'resend:<uuid>'. The SQL
// claim still applies every duplicate / unconfirmed / rate guard to it.
const RESEND_REF_RE = /^resend:[A-Za-z0-9-]{8,64}$/;
const RESEND_ROLES = ['ADMIN', 'MANAGER'];
const CONFIRMED_STATUSES = ['accepted', 'queued', 'sending', 'sent', 'delivered'];
// The passenger-link token (17 base62 chars) is never stored in the SMS log:
// the claim keeps this same-length GSM-7 mask, the real token is minted only
// after a successful claim and goes to the provider only.
export const PASS_TOKEN_LEN = 17;
export const PASS_TOKEN_MASK = '*'.repeat(PASS_TOKEN_LEN);
const PASS_TOKEN_RE = /^[A-Za-z0-9]{17}$/;
const THROTTLE_BACKOFF_MS = [400, 1200];

const fail = (status: string, code: string, message: string, extra: Partial<SendResult> = {}): SendResult =>
  ({ ok: false, status, error: { code, message }, ...extra });

export function buildIdempotencyKey(passengerId: number, type: MessageType, eventRef: string): string {
  return `pax:${passengerId}:${type}:${eventRef}`;
}

export async function sendAirValetSms(deps: SendDeps, input: SendInput): Promise<SendResult> {
  const log = deps.log ?? (() => {});
  const sleep = deps.sleep ?? ((ms: number) => new Promise((r) => setTimeout(r, ms)));
  const templates: Record<string, Template> = deps.templates ?? TEMPLATES;
  let claimedId: string | null = null;

  try {
    if (deps.mode === 'disabled') return fail('disabled', 'SMS_DISABLED', 'SMS sending is disabled');
    // Reconciliation piggybacks on traffic: anything stuck without an answer
    // becomes a visible UNCONFIRMED alert (and blocks a blind resend).
    try { await deps.store.reconcile?.(); } catch { /* never blocks a send */ }

    const baseTpl = Object.hasOwn(templates, input.type) ? templates[input.type] : undefined;
    if (!baseTpl) return fail('rejected', 'INVALID_TYPE', 'unknown message type');
    // Mock mode (local / staging tests, never reaches Twilio) may exercise
    // wording that is still PENDING_APPROVAL. allowlist/live keep refusing it.
    const tpl: Template = deps.mode === 'mock' && baseTpl.status !== 'APPROVED'
      ? { ...baseTpl, status: 'APPROVED', version: 'draft-mock' }
      : baseTpl;
    const type: MessageType = tpl.type;

    if (!input.actor.role || !tpl.allowedRoles.includes(input.actor.role)) {
      return fail('rejected', 'FORBIDDEN', 'role not allowed for this message type');
    }
    if (!Number.isSafeInteger(input.passengerId) || input.passengerId <= 0) {
      return fail('rejected', 'INVALID_PASSENGER', 'invalid passenger id');
    }

    const now = (deps.now ?? (() => new Date()))();
    if (input.eventRef !== undefined && !EVENT_REF_RE.test(input.eventRef)) return fail('rejected', 'INVALID_EVENT_REF', 'invalid event reference');
    if (!tpl.freeText && input.eventRef !== undefined
        && !(RESEND_REF_RE.test(input.eventRef) && RESEND_ROLES.includes(input.actor.role || ''))) {
      return fail('rejected', 'RESEND_NOT_ALLOWED', 'only a manager can resend this message');
    }
    if (input.eventRef === undefined && !tpl.defaultEventRef) return fail('rejected', 'INVALID_EVENT_REF', 'missing event reference');

    const passenger = await deps.store.getPassenger(input.passengerId);
    if (!passenger) return fail('rejected', 'PASSENGER_NOT_FOUND', 'passenger not found');
    const eventRef = input.eventRef ?? tpl.defaultEventRef!(now, passenger);

    const phone = normalizePhoneE164(passenger.phone);
    if (!phone.valid) return fail('rejected', 'INVALID_PHONE', `invalid phone (${phone.reason})`);

    if (deps.mode === 'allowlist' && !deps.allowlist.includes(phone.e164)) {
      return fail('blocked', 'NOT_ALLOWLISTED', 'test mode: number not on the allowlist');
    }

    const env: RenderEnv = { ...(deps.renderEnv ?? {}) };
    if (tpl.needsPassLink && tpl.status === 'APPROVED' && !tpl.guard?.(passenger)) {
      if (!deps.passBaseUrl) return fail('rejected', 'PASS_LINK_MISSING', 'passenger link base URL not configured');
      env.passUrl = deps.passBaseUrl + PASS_TOKEN_MASK; // real token minted after the claim
    }
    let rendered: { body: string; version: string; variant: string };
    try {
      rendered = renderMessage(tpl, passenger, env, input.customBody);
    } catch (e) {
      if (e instanceof TemplateError) return fail('rejected', e.code, e.message);
      throw e;
    }

    const claim = await deps.store.claim({
      idempotencyKey: buildIdempotencyKey(passenger.id, type, eventRef),
      passengerId: passenger.id,
      ticket: passenger.ticket,
      phoneE164: phone.e164,
      messageType: type,
      templateKey: rendered.variant,
      templateVersion: rendered.version,
      body: rendered.body,
      segments: countSegments(rendered.body),
      provider: deps.provider.name,
      sentBy: input.actor.userId,
      sentByName: input.actor.name ?? null,
      deviceKeyHash: input.deviceKeyHash ?? null,
    });

    if (!claim.claimed) {
      if (claim.status === 'blocked') {
        return fail('blocked', claim.error_code || 'BLOCKED', 'not sent (no opt-in, opt-out or rate limit)', { messageId: claim.message_id });
      }
      // Duplicate request: report the original attempt, do not send again.
      // ok only when the provider really took it; an attempt still pending
      // or unconfirmed is NOT a success (the UI must not say "Sent").
      log('sms.duplicate', { messageId: claim.message_id, status: claim.status });
      const confirmed = CONFIRMED_STATUSES.includes(claim.status);
      return {
        ok: confirmed,
        status: confirmed || claim.status === 'failed' || claim.status === 'undelivered' ? claim.status : 'send_unknown',
        messageId: claim.message_id,
        sid: claim.provider_message_sid,
        duplicate: true,
        ...(confirmed ? {} : claim.status === 'failed' || claim.status === 'undelivered'
          ? { error: { code: claim.error_code || 'FAILED', message: 'previous attempt failed' } }
          : { error: { code: 'UNCONFIRMED', message: 'previous attempt not confirmed yet; check before resending' } }),
      };
    }
    claimedId = claim.message_id;

    // Passenger link: mint only now (a duplicate / blocked request never
    // creates or rotates a link) and splice it into the provider body only.
    let providerBody = rendered.body;
    if (env.passUrl) {
      const token = await deps.store.mintPassLink(passenger.id);
      if (!token || !PASS_TOKEN_RE.test(token) || rendered.body.split(env.passUrl).length !== 2) {
        await deps.store.markResult({ messageId: claimedId, status: 'failed', sid: null, messagingServiceSid: null, errorCode: 'PASS_LINK_UNAVAILABLE', errorMessage: 'passenger link not available', attempts: 0 });
        return fail('failed', 'PASS_LINK_UNAVAILABLE', 'passenger link not available', { messageId: claimedId });
      }
      providerBody = rendered.body.replace(env.passUrl, deps.passBaseUrl + token);
    }

    let outcome: SendOutcome;
    let attempts = 0;
    for (;;) {
      attempts += 1;
      outcome = await deps.provider.send({
        to: phone.e164, body: providerBody,
        // ?mid= lets a status callback find this row even if our request
        // times out before Twilio's answer (send_unknown → reconciled).
        statusCallbackUrl: deps.statusCallbackUrl ? `${deps.statusCallbackUrl}?mid=${claimedId}` : undefined,
      });
      if (outcome.kind !== 'throttled' || attempts > THROTTLE_BACKOFF_MS.length) break;
      await sleep(THROTTLE_BACKOFF_MS[attempts - 1]);
    }

    if (outcome.kind === 'accepted') {
      const status = (['accepted', 'queued', 'sending', 'sent'] as const).find((s) => s === outcome.status) ?? 'accepted';
      const final = await deps.store.markResult({ messageId: claimedId, status, sid: outcome.sid, messagingServiceSid: outcome.messagingServiceSid, errorCode: null, errorMessage: null, attempts });
      log('sms.accepted', { messageId: claimedId, sid: outcome.sid, status: final });
      return { ok: true, status: final, messageId: claimedId, sid: outcome.sid };
    }

    if (outcome.kind === 'unknown') {
      await deps.store.markResult({ messageId: claimedId, status: 'send_unknown', sid: null, messagingServiceSid: null, errorCode: outcome.errorCode, errorMessage: outcome.errorMessage, attempts });
      log('sms.unknown', { messageId: claimedId, code: outcome.errorCode });
      return fail('send_unknown', outcome.errorCode, 'provider did not confirm; not retried automatically', { messageId: claimedId });
    }

    // rejected, or still throttled after the allowed retries → definitely not sent.
    await deps.store.markResult({ messageId: claimedId, status: 'failed', sid: null, messagingServiceSid: null, errorCode: outcome.errorCode, errorMessage: outcome.errorMessage, attempts });
    if (outcome.errorCode === '21610') await deps.store.markOptedOut(phone.e164, 'twilio_21610');
    log('sms.failed', { messageId: claimedId, code: outcome.errorCode });
    return fail('failed', outcome.errorCode, outcome.errorMessage, { messageId: claimedId });
  } catch (e) {
    // Last line of defence: never let an SMS problem escape to the caller.
    log('sms.error', { messageId: claimedId, error: (e as Error)?.name || 'Error' });
    if (claimedId) {
      try {
        await deps.store.markResult({ messageId: claimedId, status: 'send_unknown', sid: null, messagingServiceSid: null, errorCode: 'INTERNAL', errorMessage: 'internal error after claim', attempts: 0 });
      } catch { /* already logged */ }
    }
    return fail('error', 'INTERNAL', 'internal error', claimedId ? { messageId: claimedId } : {});
  }
}
