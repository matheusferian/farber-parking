// Event Valet (MAKERS AIR — HALLOWEEN VALET, 2026-10-24) — pure helpers.
// Self-contained on purpose: shares nothing with the (unreleased) AirValet
// SMS module, so the event can be turned off/removed without side effects.

const enc = new TextEncoder();

// ── Messages ────────────────────────────────────────────────────────────
export type Kind = 'CHECKIN' | 'REQUESTED' | 'TIP' | 'AMBIGUOUS' | 'NO_MATCH';
export type CarOption = { code: string; vehicle: string };

// Ticket code = last 4 digits of the guest's phone ("0101", or "0101-B" for a
// second car with the same last 4).
export function composeSms(kind: Kind, code: string | null, link: string | null, options: CarOption[] = []): string {
  const no = code ?? '';
  const pick = options.map((o) => `READY ${o.code} — ${o.vehicle}`);
  switch (kind) {
    case 'CHECKIN':
      return [
        '🎃 Welcome to Makers Air Halloween!',
        'Your vehicle has been checked in.',
        `🎟️ VALET TICKET: #${no}`,
        'When you’re ready to leave, simply reply READY to this message.',
        'Please keep your ticket number handy for pickup.',
        ...(link ? [`Your digital ticket: ${link}`] : []),
        'Enjoy the celebration!',
        '— Makers Air Valet',
        'Reply STOP to opt out.',
      ].join('\n');
    case 'REQUESTED':
      return [
        '🚗 Your vehicle has been requested!',
        `🎟️ Ticket #${no}`,
        'Our valet team is preparing your car.',
        'Please have your ticket number ready.',
        '— Makers Air Valet',
      ].join('\n');
    case 'TIP':
      return [
        '🚗 Thank you for celebrating Halloween with Makers Air!',
        'We hope you enjoyed our complimentary valet service.',
        'If you’d like to thank our valet team, you can leave an optional tip here:',
        link ?? '',
        'Have a wonderful night!',
        '— Makers Air Valet',
      ].join('\n');
    case 'AMBIGUOUS':
      return [
        '🎟️ We found more than one vehicle for this number.',
        'Please reply with the one you want:',
        ...(pick.length ? pick : ['READY followed by your ticket number']),
        '— Makers Air Valet',
      ].join('\n');
    case 'NO_MATCH':
      return [
        'We could not match that ticket number to this phone.',
        ...(pick.length ? ['Please reply with:', ...pick] : ['Please reply READY, or see a valet.']),
        '— Makers Air Valet',
      ].join('\n');
  }
}

// Stored copies never contain a live guest link.
export const maskLink = (body: string, link: string | null) =>
  link ? body.split(link).join(link.replace(/#.*/, '#' + '*'.repeat(8))) : body;

// ── Inbound parsing ────────────────────────────────────────────────────
// Twilio Advanced Opt-Out answers these itself; we never act on them.
const KEYWORDS = new Set(['STOP', 'STOPALL', 'UNSUBSCRIBE', 'CANCEL', 'END', 'QUIT', 'OPTOUT', 'REVOKE',
  'START', 'UNSTOP', 'YES', 'HELP', 'INFO']);

export type Parsed = { type: 'ready'; ticketRef: string | null } | { type: 'keyword' } | { type: 'other' };

export function parseInbound(raw: string): Parsed {
  const text = String(raw ?? '').toUpperCase().replace(/[^A-Z0-9# ]/g, ' ').replace(/\s+/g, ' ').trim();
  if (KEYWORDS.has(text)) return { type: 'keyword' };
  if (!/\bREADY\b/.test(text)) return { type: 'other' };
  // "READY 0101", "ready #0101-b", "0101 B ready" → "0101" / "0101B"
  const m = text.match(/(?:^|\s)#?(\d{1,4})(?:\s?([B-Z]))?(?=\s|$)/);
  return { type: 'ready', ticketRef: m ? m[1] + (m[2] ?? '') : null };
}

// ── Phone ───────────────────────────────────────────────────────────────
export function normalizePhone(raw: unknown): string | null {
  const s = raw == null ? '' : String(raw).trim();
  const d = s.replace(/\D/g, '');
  if (s.startsWith('+')) return d.length >= 8 && d.length <= 15 && d[0] !== '0' ? '+' + d : null;
  let e: string;
  if (d.length === 10) e = '+1' + d;
  else if (d.length === 11 && d[0] === '1') e = '+' + d;
  else return null;
  if ('01'.includes(e[2]) || '01'.includes(e[5])) return null;
  return e;
}
export const maskPhone = (e164: string) => (e164 && e164.length > 4 ? e164.slice(0, 2) + '•••' + e164.slice(-4) : '•••');

// ── Twilio signature (twilio.com/docs/usage/security) ─────────────────
export function signatureData(url: string, params: Iterable<[string, string]>): string {
  const sorted = [...params].sort(([ak, av], [bk, bv]) => (ak < bk ? -1 : ak > bk ? 1 : av < bv ? -1 : av > bv ? 1 : 0));
  return url + sorted.map(([k, v]) => k + v).join('');
}
export async function computeSignature(authToken: string, url: string, params: Iterable<[string, string]>) {
  const key = await crypto.subtle.importKey('raw', enc.encode(authToken), { name: 'HMAC', hash: 'SHA-1' }, false, ['sign']);
  const mac = await crypto.subtle.sign('HMAC', key, enc.encode(signatureData(url, params)));
  return btoa(String.fromCharCode(...new Uint8Array(mac)));
}
export function timingSafeEqualStr(x: string, y: string): boolean {
  const a = enc.encode(x), b = enc.encode(y);
  let diff = a.length ^ b.length;
  for (let i = 0; i < Math.max(a.length, b.length); i++) diff |= (a[i] ?? 0) ^ (b[i] ?? 0);
  return diff === 0;
}
export async function validSignature(authToken: string | undefined, url: string, params: Iterable<[string, string]>, sig: string | null) {
  if (!authToken || !sig) return false; // fail closed when unconfigured
  const a = enc.encode(await computeSignature(authToken, url, params));
  const b = enc.encode(sig);
  let diff = a.length ^ b.length;
  for (let i = 0; i < Math.max(a.length, b.length); i++) diff |= (a[i] ?? 0) ^ (b[i] ?? 0);
  return diff === 0;
}

// ── Twilio send ────────────────────────────────────────────────────────
export type TwilioCfg = {
  accountSid: string; authUser: string; authPass: string;
  messagingServiceSid?: string; from?: string; timeoutMs?: number;
};
export type SendResult =
  | { ok: true; sid: string; status: string }
  | { ok: false; code: string; message: string; maybeSent: boolean };

export async function twilioSend(cfg: TwilioCfg, to: string, body: string, statusCallback: string | null, fetchImpl: typeof fetch = fetch): Promise<SendResult> {
  const form = new URLSearchParams({ To: to, Body: body, ValidityPeriod: '3600' });
  if (cfg.messagingServiceSid) form.set('MessagingServiceSid', cfg.messagingServiceSid);
  else if (cfg.from) form.set('From', cfg.from);
  if (statusCallback) form.set('StatusCallback', statusCallback);
  let res: Response;
  try {
    res = await fetchImpl(`https://api.twilio.com/2010-04-01/Accounts/${encodeURIComponent(cfg.accountSid)}/Messages.json`, {
      method: 'POST',
      headers: { Authorization: 'Basic ' + btoa(`${cfg.authUser}:${cfg.authPass}`), 'Content-Type': 'application/x-www-form-urlencoded' },
      body: form,
      signal: AbortSignal.timeout(cfg.timeoutMs ?? 8000),
    });
  } catch (e) {
    return { ok: false, code: (e as Error)?.name === 'TimeoutError' ? 'TIMEOUT' : 'NETWORK', message: 'no response from Twilio', maybeSent: true };
  }
  let json: Record<string, unknown> = {};
  try { json = await res.json(); } catch { /* non-JSON */ }
  if ((res.status === 201 || res.status === 200) && typeof json.sid === 'string') {
    return { ok: true, sid: json.sid, status: typeof json.status === 'string' ? json.status : 'accepted' };
  }
  const code = json.code != null ? String(json.code) : `HTTP_${res.status}`;
  const message = String(typeof json.message === 'string' ? json.message : `HTTP ${res.status}`).slice(0, 200);
  return { ok: false, code, message, maybeSent: res.status >= 500 };
}
