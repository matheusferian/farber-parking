// SMS provider boundary. The ONLY place that talks to Twilio's REST API.
// Everything else in AirValet goes through sendAirValetSms() (service.ts).
//
// Outcomes are classified for retry safety:
//   accepted  — Twilio created the message (has SID).
//   rejected  — Twilio answered with a 4xx: definitely NOT sent, never retry.
//   throttled — HTTP 429: definitely not sent, safe to retry after a pause.
//   unknown   — timeout / network drop / 5xx: Twilio MAY have sent it.
//               Never retried automatically (the Messages API has no
//               idempotency key) — the status callback settles it.

import { sanitizeProviderText } from './sanitize.ts';

export type SendRequest = {
  to: string;
  body: string;
  statusCallbackUrl?: string;
};

export type SendOutcome =
  | { kind: 'accepted'; sid: string; status: string; messagingServiceSid: string | null }
  | { kind: 'rejected'; errorCode: string; errorMessage: string }
  | { kind: 'throttled'; errorCode: string; errorMessage: string }
  | { kind: 'unknown'; errorCode: string; errorMessage: string };

export interface SmsProvider {
  readonly name: 'twilio' | 'mock';
  send(req: SendRequest): Promise<SendOutcome>;
}

export type TwilioConfig = {
  accountSid: string;
  apiKeySid: string;
  apiKeySecret: string;
  messagingServiceSid: string;
  timeoutMs: number;
};

export class TwilioProvider implements SmsProvider {
  readonly name = 'twilio' as const;
  constructor(private cfg: TwilioConfig, private fetchImpl: typeof fetch = fetch) {}

  async send(req: SendRequest): Promise<SendOutcome> {
    const form = new URLSearchParams({
      To: req.to,
      Body: req.body,
      MessagingServiceSid: this.cfg.messagingServiceSid,
      // Operational texts are useless late: carriers drop them after 1 hour
      // instead of delivering a stale "your car is ready".
      ValidityPeriod: '3600',
    });
    if (req.statusCallbackUrl) form.set('StatusCallback', req.statusCallbackUrl);

    const ctl = new AbortController();
    const timer = setTimeout(() => ctl.abort(), this.cfg.timeoutMs);
    let res: Response;
    try {
      res = await this.fetchImpl(
        `https://api.twilio.com/2010-04-01/Accounts/${encodeURIComponent(this.cfg.accountSid)}/Messages.json`,
        {
          method: 'POST',
          headers: {
            Authorization: 'Basic ' + btoa(`${this.cfg.apiKeySid}:${this.cfg.apiKeySecret}`),
            'Content-Type': 'application/x-www-form-urlencoded',
          },
          body: form,
          signal: ctl.signal,
        },
      );
    } catch (e) {
      const timedOut = (e as Error)?.name === 'AbortError';
      return { kind: 'unknown', errorCode: timedOut ? 'TIMEOUT' : 'NETWORK', errorMessage: timedOut ? `no response within ${this.cfg.timeoutMs} ms` : 'network error' };
    } finally {
      clearTimeout(timer);
    }

    let json: Record<string, unknown> = {};
    try { json = await res.json(); } catch { /* non-JSON body */ }

    if (res.status === 201 || res.status === 200) {
      const sid = typeof json.sid === 'string' ? json.sid : '';
      if (!sid) return { kind: 'unknown', errorCode: 'NO_SID', errorMessage: 'success without SID' };
      return {
        kind: 'accepted',
        sid,
        status: typeof json.status === 'string' ? json.status : 'accepted',
        messagingServiceSid: typeof json.messaging_service_sid === 'string' ? json.messaging_service_sid : null,
      };
    }
    const code = json.code != null ? String(json.code) : `HTTP_${res.status}`;
    const message = sanitizeProviderText(typeof json.message === 'string' ? json.message : `HTTP ${res.status}`);
    if (res.status === 429) return { kind: 'throttled', errorCode: code, errorMessage: message };
    if (res.status >= 400 && res.status < 500) return { kind: 'rejected', errorCode: code, errorMessage: message };
    return { kind: 'unknown', errorCode: code, errorMessage: message };
  }
}

// Deterministic provider for tests and for AIRVALET_SMS_MODE=mock. Never
// touches the network. `script` lets tests queue specific outcomes.
export class MockProvider implements SmsProvider {
  readonly name = 'mock' as const;
  readonly calls: SendRequest[] = [];
  private n = 0;
  constructor(private script: Array<SendOutcome | ((req: SendRequest) => Promise<SendOutcome>)> = []) {}

  async send(req: SendRequest): Promise<SendOutcome> {
    this.calls.push(req);
    const next = this.script.shift();
    if (typeof next === 'function') return await next(req);
    if (next) return next;
    this.n += 1;
    // Unique across Edge Function invocations (a per-instance counter would
    // repeat SMMOCK…0001 on every request and collide on provider_message_sid).
    const rand = crypto.randomUUID().replace(/-/g, '').slice(0, 24);
    return { kind: 'accepted', sid: `SMMOCK${rand}${String(this.n % 10000).padStart(4, '0')}`, status: 'queued', messagingServiceSid: 'MGMOCK' };
  }
}
