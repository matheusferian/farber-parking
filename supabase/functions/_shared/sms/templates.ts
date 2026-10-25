// AirValet SMS templates — server-side twins of the build*Sms() functions in
// index.html, adapted for Twilio/A2P.
//
// Owner decisions (2026-10-09):
//   * ONE sender identity for everyone: "Makers Air Valet" (Ascend passengers
//     included — same valet operation, operated by Farber Parking).
//   * Departure and return are independent; return_operator is editable all
//     trip (defaults to the departure at check-in, never rewritten after).
//   * Pickup place comes from the CURRENT return_operator, never from the
//     departure: MAKERS → Hangar 19 · ASCEND → Customs · OTHER/unset → no
//     pickup instruction at all (template refuses; staff handle it manually).
//   * Key handoff follows the RETURN operation (audit 2026-10-09), never the
//     departure ticket:
//       ASCEND return (Customs is the rule) → Ascend team hands the key over;
//       MAKERS return + approved Customs EXCEPTION (existing delivery_at_customs)
//         → passenger contacts the valet team on arrival for the key;
//       MAKERS return → Hangar 19 (no key text); OTHER → no instruction.
//     SMS never states where a key is left (the old "driver's-side tire"
//     text is gone; any physical key location stays internal to AirValet).
//   * The Makers Customs exception is never offered: no template mentions it
//     unless staff approved it; while a request is pending, VEHICLE_READY is
//     refused (no definitive instruction).
//   * No automatic "vehicle ready": VEHICLE_READY is manual (staff button).
//     Its idempotency key includes the place, so after a return change staff
//     can send the corrected instruction once (never automatically).
//
// Every template is PENDING_APPROVAL: renderMessage() refuses until the owner
// approves the exact wording and the entry is flipped to APPROVED. REPLY
// (staff typing in the inbox) is the only free-text type.
// The approved A2P program is purely operational: no gratuity / tip link,
// no marketing (owner 2026-10-10). Free text (REPLY) is capped at 3 segments
// and may only link to our own domains.
// All bodies are GSM-7 only (tests enforce it) to keep segments low.

export type Operator = 'MAKERS' | 'ASCEND';
export type ReturnOperator = Operator | 'OTHER';
export type MessageType =
  | 'CHECK_IN' | 'RETURN_CONFIRMATION' | 'VEHICLE_READY' | 'VEHICLE_DELIVERED'
  | 'RETURN_UPDATED' | 'AFTER_HOURS_CONFIRMED'
  | 'REPLY' | 'CUSTOM_OPERATIONAL';
export type Role = 'ADMIN' | 'MANAGER' | 'IPAD_OPS' | 'IPHONE_OPS' | 'TV_ONLY';

// What a template may read — always loaded server-side from passengers.
export type PassengerCtx = {
  name: string | null;
  ticket: string | null;
  ret: string | null;
  ret_time?: string | null;                       // optional HH:MM (P1); never invented
  car: string | null;
  status: string | null;
  return_operator: ReturnOperator | null;
  delivery_at_customs: boolean | null;            // MAKERS: approved Customs exception
  customs_exception_requested_at: string | null;  // MAKERS: request under review
  delivery_type: string | null;
  customs_welcome_sent: boolean | null;
  tip_received: boolean | null;
};
export type RenderEnv = { passUrl?: string | null };

export type Template = {
  type: MessageType;
  status: 'PENDING_APPROVAL' | 'APPROVED';
  version: string | null;
  freeText: boolean;
  allowedRoles: Role[];
  needsPassLink?: boolean;
  // Default idempotency event; null = caller must send a fresh compose id.
  defaultEventRef: ((now: Date, p: PassengerCtx) => string) | null;
  // Returns an error code when the business rule forbids this message.
  guard?: (p: PassengerCtx) => string | null;
  render?: (p: PassengerCtx, env: RenderEnv) => { variant: string; body: string };
};

const OPS: Role[] = ['ADMIN', 'MANAGER', 'IPAD_OPS', 'IPHONE_OPS'];
export const SENDER = 'Makers Air Valet';
export const FREE_TEXT_MAX = 480; // ≈ 3 GSM-7 segments
export const FREE_TEXT_MAX_SEGMENTS = 3; // also enforced in SQL (settings)
// Links in free text: only our own domains (carrier filtering + safety).
const LINK_RE = /\b(?:https?:\/\/[^\s]+|www\.[^\s]+|[a-z0-9-]+(?:\.[a-z0-9-]+)*\.(?:com|net|org|io|co|us|ly|me|app|info|biz|link|xyz|site|online)\b[^\s]*)/gi;
const OWN_DOMAIN_RE = /^(?:https?:\/\/)?(?:[a-z0-9-]+\.)*(?:farberos\.com|farberparking\.com)(?:[\/?#:]|$)/i;

export class TemplateError extends Error {
  constructor(public code: string, message: string) { super(message); }
}

export function departureOperator(ticket: string | null | undefined): Operator {
  return /^A-/i.test(String(ticket || '').trim()) ? 'ASCEND' : 'MAKERS';
}
export type ReturnLocation = 'HANGAR_19' | 'CUSTOMS';
export function returnLocation(op: ReturnOperator | null | undefined): ReturnLocation | null {
  return op === 'MAKERS' ? 'HANGAR_19' : op === 'ASCEND' ? 'CUSTOMS' : null;
}
// Effective pickup: default from the return, plus the approved Makers
// Customs exception (existing delivery_at_customs). Same as SQL
// airvalet_pickup_location().
export function pickupPlace(p: Pick<PassengerCtx, 'return_operator' | 'delivery_at_customs'>): ReturnLocation | null {
  if (p.return_operator === 'MAKERS') return p.delivery_at_customs ? 'CUSTOMS' : 'HANGAR_19';
  return returnLocation(p.return_operator);
}
export const VALET_PHONE = '(954) 352-1010'; // printed on the customer ticket today

// "JOHN SMITH" → "John". Control chars stripped so a name can't add lines.
// Letters outside GSM-7 are transliterated (José → José stays: é is GSM-7;
// João → Joao) so a name never turns the whole text into UCS-2.
export function firstName(name: string | null): string {
  // deno-lint-ignore no-control-regex
  const w = String(name || '').replace(/[\u0000-\u001f\u007f]+/g, ' ').trim().split(/\s+/)[0] || '';
  const t = w ? w.charAt(0).toUpperCase() + w.slice(1).toLowerCase() : '';
  return Array.from(t).map((ch) => (isGsm7(ch) ? ch : ch.normalize('NFD').replace(/[\u0300-\u036f]/g, ''))).join('')
    .replace(/[^A-Za-z\u00C0-\u00FF'-]/g, '').slice(0, 20);
}
function readyVariant(p: PassengerCtx): string {
  if (p.return_operator === 'ASCEND') return 'CUSTOMS_WELCOME';
  if (p.return_operator === 'MAKERS') return p.delivery_at_customs ? 'CUSTOMS_EXCEPTION' : 'HANGAR19_WELCOME_BACK';
  return 'none';
}

const notArchived = (p: PassengerCtx) => (p.status === 'DELIVERED' || p.status === 'ARCHIVED' ? 'NOT_IN_CUSTODY' : null);

export const TEMPLATES: Record<MessageType, Template> = {
  // Owner final text (2026-10-25, go-live): no passenger name — the phone may
  // belong to a companion. Fixed length: 160 GSM-7 chars with the real link
  // (https://airvalet.farberos.com/a# + 17-char token) = ONE segment.
  CHECK_IN: {
    type: 'CHECK_IN', status: 'APPROVED', version: 'checkin-2026-10-25-golive', freeText: false, allowedRoles: OPS,
    needsPassLink: true,
    defaultEventRef: () => 'checkin',
    guard: notArchived,
    render: (_p, env) => {
      if (!env.passUrl) throw new TemplateError('PASS_LINK_MISSING', 'passenger link not available');
      return { variant: 'CHECK_IN_PASS', body: welcomeBody(env.passUrl) };
    },
  },
  // Replaces RETURN_CONFIRMATION + TASK_CONFIRMATION. When the return flight
  // operator is unknown it also asks Makers Air or Ascend (1 segment).
  RETURN_CONFIRMATION: {
    type: 'RETURN_CONFIRMATION', status: 'PENDING_APPROVAL', version: null, freeText: false, allowedRoles: OPS,
    defaultEventRef: (now) => 'ask:' + now.toISOString().slice(0, 10),
    guard: notArchived,
    render: (p) => {
      const hi = firstName(p.name) ? `Hi ${firstName(p.name)}, ` : 'Hi, ';
      if (!p.return_operator) { // legacy rows only: check-in always sets a default
        return { variant: 'RETURN_CONFIRMATION_OPERATOR', body: `${SENDER}: ${hi}please reply with your return date, arrival time and whether you're flying back with Makers Air or Ascend. Thank you!` };
      }
      return { variant: 'RETURN_CONFIRMATION', body: `${SENDER}: ${hi}can you confirm your return date and arrival time? Just reply to this message. Thank you!` };
    },
  },
  // HANGAR19_WELCOME_BACK / CUSTOMS_WELCOME_*: chosen by the RETURN flight.
  // Manual only (staff button) — never automatic.
  VEHICLE_READY: {
    type: 'VEHICLE_READY', status: 'APPROVED', version: 'ready-2026-10-25b', freeText: false, allowedRoles: OPS,
    defaultEventRef: (_now, p) => 'ready:' + readyVariant(p),
    guard: (p) => {
      // A car left at Customs is marked DELIVERED (delivery_type CUSTOMS) before
      // the guest lands: its Customs Welcome Back may still go out (owner 2026-10-25).
      if (p.status === 'ARCHIVED' || (p.status === 'DELIVERED' && p.delivery_type !== 'CUSTOMS')) return 'NOT_IN_CUSTODY';
      if (!p.return_operator) return 'RETURN_NOT_SET';
      if (p.return_operator === 'OTHER') return 'RETURN_OTHER_MANUAL';
      // A Customs request under review: no definitive pickup instruction.
      if (p.return_operator === 'MAKERS' && !p.delivery_at_customs && p.customs_exception_requested_at) return 'CUSTOMS_REQUEST_PENDING';
      return null;
    },
    render: (p) => {
      if (readyVariant(p) === 'CUSTOMS_EXCEPTION') {
        // Makers return, Customs approved case by case. Owner 2026-10-25 (final):
        // never states where the key is; the guest replies on arrival and the
        // valet team helps with the key. 154 GSM-7 chars = 1 segment.
        return { variant: 'CUSTOMS_EXCEPTION', body: 'Welcome back to Makers Air!\nYour vehicle is ready at Customs. Please reply to this message when you arrive so our valet team can assist you with your key.' };
      }
      if (pickupPlace(p) === 'HANGAR_19') {
        return {
          variant: 'HANGAR19_WELCOME_BACK',
          body: `${SENDER}: Welcome back! After Customs, stay with your pilots and return to Hangar 19. Your car is ready. Please don't exit through the Customs terminal.`,
        };
      }
      // Customs = Ascend return (any departure). Same in-person handoff for
      // Makers→Ascend and Ascend→Ascend; no key location in the SMS.
      return { variant: 'CUSTOMS_WELCOME', body: `${SENDER}: Welcome back! Your car is ready at Customs. An Ascend team member will hand you your key when you arrive.` };
    },
  },
  // Delivery confirmation (replaces TIP_YES / TIP_NO / CUSTOMS_GRATUITY):
  // one operational thank-you, never a gratuity link.
  VEHICLE_DELIVERED: {
    // Owner 2026-10-25: one text for everyone (tip or not), sent at delivery,
    // with the valet pass link (a thank-you note + Gratuity button). That
    // link ends 7 days after delivery. 156 GSM-7 chars with the link = 1 segment.
    type: 'VEHICLE_DELIVERED', status: 'APPROVED', version: 'delivered-2026-10-25', freeText: false, allowedRoles: OPS,
    needsPassLink: true,
    defaultEventRef: () => 'delivered',
    guard: (p) => (p.status !== 'DELIVERED' ? 'NOT_DELIVERED' : null),
    render: (_p, env) => {
      if (!env.passUrl) throw new TemplateError('PASS_LINK_MISSING', 'passenger link not available');
      return { variant: 'DELIVERED', body: `${SENDER}: Your car has been delivered. Thank you for choosing us! Your valet team left you a note: ${env.passUrl}` };
    },
  },
  // Sent by staff (with preview) after approving a passenger's return change.
  RETURN_UPDATED: {
    type: 'RETURN_UPDATED', status: 'PENDING_APPROVAL', version: null, freeText: false, allowedRoles: OPS,
    defaultEventRef: (_now, p) => 'ret:' + String(p.ret || '').replace(/[^0-9]/g, '') + ':' + String(p.ret_time || '').replace(/[^0-9]/g, ''),
    guard: (p) => notArchived(p) || (!p.ret ? 'RETURN_NOT_SET' : null),
    render: (p) => ({
      variant: 'RETURN_UPDATED',
      body: `${SENDER}: Your return is updated to ${formatReturn(p.ret!, p.ret_time ?? null)}. Reply here if anything changes.`,
    }),
  },
  // After-hours pickup confirmed by staff. Never contains the lockbox code.
  AFTER_HOURS_CONFIRMED: {
    type: 'AFTER_HOURS_CONFIRMED', status: 'PENDING_APPROVAL', version: null, freeText: false, allowedRoles: OPS,
    defaultEventRef: () => 'afterhours',
    guard: notArchived,
    render: () => ({
      variant: 'AFTER_HOURS_CONFIRMED',
      body: `${SENDER}: Your after-hours pickup is confirmed. On your return day, the pickup steps will appear on your valet pass link.`,
    }),
  },
  // Inbox: a staff member answers the passenger. Free text, double-tap safe
  // via the compose id. Today's GENERIC "Text" button + FREEFORM land here.
  REPLY: {
    type: 'REPLY', status: 'APPROVED', version: 'reply-1', freeText: true, allowedRoles: OPS,
    defaultEventRef: null,
  },
  // Rare operational notice typed by a manager (not a reply). Off until approved.
  CUSTOM_OPERATIONAL: {
    type: 'CUSTOM_OPERATIONAL', status: 'PENDING_APPROVAL', version: null, freeText: true, allowedRoles: ['ADMIN', 'MANAGER'],
    defaultEventRef: null,
  },
};

export function renderMessage(
  tpl: Template, p: PassengerCtx, env: RenderEnv, freeBody?: string,
): { body: string; version: string; variant: string } {
  if (tpl.status !== 'APPROVED' || !tpl.version) {
    throw new TemplateError('TEMPLATE_NOT_APPROVED', `${tpl.type} is not approved yet`);
  }
  if (tpl.freeText) {
    const body = String(freeBody ?? '').replace(/\r\n/g, '\n').trim();
    if (!body) throw new TemplateError('EMPTY_BODY', 'message is empty');
    if (body.length > FREE_TEXT_MAX) throw new TemplateError('BODY_TOO_LONG', `message over ${FREE_TEXT_MAX} chars`);
    if (countSegments(body) > FREE_TEXT_MAX_SEGMENTS) {
      throw new TemplateError('BODY_TOO_LONG', `message over ${FREE_TEXT_MAX_SEGMENTS} segments (emoji / accents use more)`);
    }
    for (const m of body.match(LINK_RE) ?? []) {
      if (!OWN_DOMAIN_RE.test(m)) throw new TemplateError('LINK_NOT_ALLOWED', 'links to other websites are not allowed in texts');
    }
    return { body, version: tpl.version, variant: tpl.type };
  }
  const blocked = tpl.guard?.(p);
  if (blocked) throw new TemplateError(blocked, `${tpl.type} not allowed for this passenger (${blocked})`);
  const out = tpl.render!(p, env);
  return { body: out.body, version: tpl.version, variant: out.variant };
}

// GSM-7 vs UCS-2 segment estimate (for the audit row / cost visibility).
const GSM7 = '@£$¥èéùìòÇ\nØø\rÅåΔ_ΦΓΛΩΠΨΣΘΞÆæßÉ !"#¤%&\'()*+,-./0123456789:;<=>?¡ABCDEFGHIJKLMNOPQRSTUVWXYZÄÖÑÜ§¿abcdefghijklmnopqrstuvwxyzäöñüà';
const GSM7_EXT = '^{}\\[~]|€';
export function countSegments(body: string): number {
  let septets = 0;
  for (const ch of body) {
    if (GSM7.includes(ch)) septets += 1;
    else if (GSM7_EXT.includes(ch)) septets += 2;
    else {
      const units = body.length; // UCS-2 code units
      return units <= 70 ? 1 : Math.ceil(units / 67);
    }
  }
  return septets <= 160 ? 1 : Math.ceil(septets / 153);
}

export function isGsm7(ch: string): boolean { return GSM7.includes(ch) || GSM7_EXT.includes(ch); }

// Twilio US price per segment (read from the account pricing API on
// 2026-10-25) + an ESTIMATE of the 10DLC carrier pass-through fee.
export const SMS_PRICE_PER_SEGMENT_USD = 0.0083;
export const SMS_CARRIER_FEE_EST_USD = 0.003;
export function estimateCostUsd(segments: number): number {
  return Math.round(segments * (SMS_PRICE_PER_SEGMENT_USD + SMS_CARRIER_FEE_EST_USD) * 10000) / 10000;
}

// Owner's go-live welcome (single line breaks keep it at 160 chars = 1 segment).
export function welcomeBody(link: string): string {
  return `Welcome to Makers Air Valet!\nYour vehicle has been checked in.\nYour digital valet pass:\n${link}\nReply STOP to opt out.`;
}

// "10/31/2026" + "18:00" → "Fri, Oct 31, 6:00 PM" (time only when set).
export function formatReturn(ret: string, time: string | null): string {
  const m = /^(\d{1,2})\/(\d{1,2})\/(\d{4})$/.exec(String(ret).trim());
  if (!m) return String(ret);
  const d = new Date(Date.UTC(+m[3], +m[1] - 1, +m[2], 12));
  const day = d.toLocaleDateString('en-US', { weekday: 'short', month: 'short', day: 'numeric', timeZone: 'UTC' });
  const t = /^(\d{2}):(\d{2})/.exec(String(time || ''));
  if (!t) return day;
  const h = +t[1];
  return `${day}, ${((h + 11) % 12) + 1}:${t[2]} ${h < 12 ? 'AM' : 'PM'}`;
}
