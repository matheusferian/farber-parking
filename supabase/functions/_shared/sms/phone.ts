// E.164 normalization — same rules as normalizePhoneE164() in utils.js and
// public.airvalet_sms_normalize_phone() in SQL, so the browser, the Edge
// Functions and the database produce the same E.164 string. Sending adds one
// stricter check on top (NANP area code / exchange, below).
//   10 digits                → +1XXXXXXXXXX (US/NANP)
//   11 digits starting with 1 → +1XXXXXXXXXX
//   leading '+' with 8–15 digits → kept as is
// Anything else is invalid. A country code is never guessed.

export type PhoneResult =
  | { valid: true; e164: string }
  | { valid: false; reason: string };

export function normalizePhoneE164(raw: unknown): PhoneResult {
  const trimmed = raw == null ? '' : String(raw).trim();
  if (!trimmed) return { valid: false, reason: 'empty' };
  const digits = trimmed.replace(/\D/g, '');
  if (trimmed.startsWith('+')) {
    if (digits.length < 8 || digits.length > 15 || digits.startsWith('0')) {
      return { valid: false, reason: 'international_length' };
    }
    return { valid: true, e164: '+' + digits };
  }
  if (digits.length === 10) return checkNanp('+1' + digits);
  if (digits.length === 11 && digits.startsWith('1')) return checkNanp('+' + digits);
  return { valid: false, reason: 'not_us_10_digit_and_no_plus' };
}

// NANP: area code and exchange can't start with 0 or 1. Twilio would reject
// these anyway (error 21211); catching them here saves a billed API call.
function checkNanp(e164: string): PhoneResult {
  const area = e164.charAt(2);
  const exchange = e164.charAt(5);
  if (area === '0' || area === '1') return { valid: false, reason: 'nanp_area_code' };
  if (exchange === '0' || exchange === '1') return { valid: false, reason: 'nanp_exchange' };
  return { valid: true, e164 };
}

// For logs: never print a full phone number.
export function maskPhone(e164: string): string {
  return e164.length > 4 ? e164.slice(0, 2) + '•••' + e164.slice(-4) : '•••';
}
