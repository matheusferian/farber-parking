// Event Valet (MAKERS AIR — HALLOWEEN VALET 2026-10-24; FARBER PARKING —
// WATERMAKERS VALET 2026-11-11) — pure helpers.
// Self-contained on purpose: shares nothing with the (unreleased) AirValet
// SMS module, so the event can be turned off/removed without side effects.

const enc = new TextEncoder();

// ── Messages ────────────────────────────────────────────────────────────
export type Kind = 'CHECKIN' | 'REQUESTED' | 'READY' | 'TIP' | 'AMBIGUOUS' | 'NO_MATCH' | 'ONWAY' | 'THANKS' | 'CROSS';

// Per-event wording. The default is the Halloween text, unchanged (owner-approved
// 2026-10-23); other events only swap the greeting, closing and signature.
type Brand = { staff: string; sign: string; welcome: string; enjoy: string; thanks: string; thanks2?: string; note: string; place: string;
  // Optional (Watermakers, owner 2026-11-05): short pass-link path and a one-segment welcome text.
  short?: string; checkin?: (no: string, link: string | null) => string;
  // Optional (Watermakers, owner 2026-11-11): plain one-segment texts for the rest of the flow.
  requested?: (no: string) => string; onway?: (no: string) => string; ready?: (no: string) => string;
  thanksNote?: (link: string) => string };
const HALLOWEEN: Brand = {
  staff: '— Halloween Valet', sign: '— Makers Air Valet',
  welcome: '🎃 Welcome to the Makers Air Halloween Celebration!', enjoy: 'Enjoy the celebration!',
  thanks: '🎃 Thank you for celebrating with Makers Air!',
  note: 'Thank you for celebrating with Makers Air!', place: 'Halloween',
};
const BRANDS: Record<string, Brand> = {
  'watermakers-veterans-2026': {
    staff: '— Watermakers Valet', sign: '— Farber Parking Valet',
    welcome: '🇺🇸 Welcome to Member Connect at Watermakers!', enjoy: 'Enjoy the evening!',
    thanks: '🇺🇸 Thank you for joining us at Watermakers!', thanks2: 'Thank you to all our veterans for your service.',
    note: 'Thank you for joining us at Watermakers!', place: 'Watermakers',
    short: '/w',
    // Plain GSM-7 (no emoji, straight quotes) so it stays one SMS segment (<=160 chars).
    // Owner 2026-11-10: open with "Welcome to Watermakers!" only, no "Farber Parking Valet:" (one segment, ~145 chars).
    // Owner 2026-11-11: premium wording, every text plain GSM-7 and one segment (<=160 chars).
    // The link is never followed by punctuation (a trailing "." could be taken into the #token).
    checkin: (no, link) => `Welcome to Watermakers! Your car is in good hands (#${no}). Ready to leave? ` +
      (link ? `Tap ${link} or reply READY` : 'Reply READY') + `. Reply STOP to opt out`,
    requested: (no) => `Watermakers Valet: request received (#${no}). Your car is being brought around now. We'll text you the moment it's ready.`,
    onway: (no) => `Watermakers Valet: your car (#${no}) is on its way to the valet stand.`,
    ready: (no) => `Watermakers Valet: your car (#${no}) is waiting for you at the valet stand. Thank you for joining us tonight.`,
    thanksNote: (link) => `Thank you for joining us at Watermakers. We hope we exceeded your expectations. A note from your valet: ${link}`,
  },
};
export const brandFor = (eventId?: string | null): Brand => (eventId && BRANDS[eventId]) || HALLOWEEN;

// Operator alert (to staff phones, never to guests).
export function composeStaffAlert(t: { ticket_code: string; slot_no: number | null; vehicle: string; parking_location?: string | null }, via: string, eventId?: string | null): string {
  return [
    '🚗 Car requested' + (via ? ` · ${via}` : ''),
    `#${t.ticket_code} · Key ${t.slot_no ? String(t.slot_no).padStart(2, '0') : '--'} · ${t.parking_location || 'No location yet'}`,
    displayVehicle(t.vehicle),
    brandFor(eventId).staff,
  ].join('\n');
}
export type CarOption = { code: string; vehicle: string };

// Vehicles are stored in capitals ("TESLA MODEL Y"); guests read "Tesla Model Y".
// Short words and words with digits stay as they are (BMW, GMC, X5, F-150, CR-V).
export function displayVehicle(v: string): string {
  return String(v ?? '').split(' ').map((w) => w.split('-').map((p) =>
    p.length <= 3 || /\d/.test(p) ? p : p.charAt(0) + p.slice(1).toLowerCase()).join('-')).join(' ');
}

// Ticket code = last 4 digits of the guest's phone ("0101"; a repeated last 4
// becomes "10101", "20101"…). Templates approved by the owner 2026-10-23;
// "Reply STOP" stays on the first message (A2P opt-out disclosure).
export function composeSms(kind: Kind, code: string | null, link: string | null, options: CarOption[] = [], eventId?: string | null): string {
  const no = code ?? '';
  const b = brandFor(eventId);
  const list = options.map((o, i) => `${i + 1}. ${displayVehicle(o.vehicle)} — #${o.code}`);
  switch (kind) {
    case 'CHECKIN':
      if (b.checkin) return b.checkin(no, link);
      return [
        b.welcome,
        'Your vehicle has been checked in with our valet team.',
        `Ticket #${no}`,
        'When you’re ready to leave, simply reply READY, and we’ll take care of the rest.',
        ...(link ? [`Your digital ticket: ${link}`] : []),
        b.enjoy,
        b.sign,
        'Reply STOP to opt out.',
      ].join('\n');
    case 'REQUESTED':
      if (b.requested) return b.requested(no);
      return [
        '🚗 We’ve received your request!',
        `Ticket #${no}`,
        'Our valet team is preparing your vehicle. We’ll let you know when it’s ready for pickup.',
        b.sign,
      ].join('\n');
    case 'READY':
      if (b.ready) return b.ready(no);
      return [
        '🚘 Your vehicle is ready!',
        `Ticket #${no}`,
        'Please head to the valet pickup area. Our team will be happy to assist you.',
        b.sign,
      ].join('\n');
    case 'TIP':
      return [
        b.thanks,
        ...(b.thanks2 ? [b.thanks2] : []),
        'It was our pleasure taking care of your vehicle.',
        'Enjoyed our valet service? You can leave our team an optional tip here:',
        link ?? '',
        'Have a safe trip home!',
        b.sign,
      ].join('\n');
    case 'AMBIGUOUS':
      return [
        '🚗 Which vehicle would you like to request?',
        '',
        ...list,
        '',
        'Reply with the ticket number of the vehicle you’d like us to bring.',
        b.sign,
      ].join('\n');
    // S710 staff API (Watermakers 2026-11-05): car claimed by a valet, one thank-you
    // note after delivery (contract text), and the "don't guess" answer when the
    // same phone also has an active Makers Air trip.
    case 'ONWAY':
      if (b.onway) return b.onway(no);
      return [
        '🚗 Your vehicle is on the way!',
        `Ticket #${no}`,
        'Our valet team is bringing your car to the pickup area.',
        b.sign,
      ].join('\n');
    case 'THANKS':
      if (b.thanksNote) return b.thanksNote(link ?? '');
      return `${b.note} Your valet has left you a note. View it here: ${link ?? ''} ${b.sign}`;
    case 'CROSS':
      return [
        'You have valet with us at more than one place today.',
        `To get your ${b.place} car, please tap the link in your ${b.place} text, or visit the valet stand.`,
        b.sign,
      ].join('\n');
    case 'NO_MATCH':
      return [
        'We couldn’t find that ticket number for this phone.',
        ...(list.length ? ['', ...list, '', 'Please reply with one of the ticket numbers above, or visit the valet stand.']
                        : ['Please reply READY, or visit the valet stand.']),
        b.sign,
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
  // A reply that is just a ticket number ("0101", "#10101") or a list position
  // ("1") answers the "Which vehicle…?" question: treat it as READY <number>.
  const bare = text.match(/^#?(\d{1,5})$/);
  if (bare) return { type: 'ready', ticketRef: bare[1] };
  if (!/\bREADY\b/.test(text)) return { type: 'other' };
  // "READY 0101", "ready #10101", "0101 ready" → "0101" / "10101"
  const m = text.match(/(?:^|\s)#?(\d{1,5})(?:\s?([B-Z]))?(?=\s|$)/);
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
