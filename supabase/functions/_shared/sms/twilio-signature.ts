// Twilio webhook signature (X-Twilio-Signature) validation.
// Algorithm (twilio.com/docs/usage/security#validating-requests):
//   data = full URL Twilio requested + each POST param, sorted by name,
//          as name+value concatenated (repeated names: values sorted too)
//   signature = base64(HMAC-SHA1(auth_token, data))
//
// The URL must be the PUBLIC URL Twilio called. Inside Supabase the Edge
// Function sees an internal URL, so callers pass the configured public URL
// (AIRVALET_SMS_PUBLIC_FUNCTIONS_URL + function path + original query).
//
// Note: Twilio signs with the account's primary Auth Token, even when we
// SEND with an API Key — that's why the Auth Token is still needed server-side.

const enc = new TextEncoder();

export function twilioSignatureData(url: string, params: Iterable<[string, string]>): string {
  const sorted = [...params].sort(([ak, av], [bk, bv]) => (ak < bk ? -1 : ak > bk ? 1 : av < bv ? -1 : av > bv ? 1 : 0));
  return url + sorted.map(([k, v]) => k + v).join('');
}

export async function computeTwilioSignature(authToken: string, url: string, params: Iterable<[string, string]>): Promise<string> {
  const key = await crypto.subtle.importKey('raw', enc.encode(authToken), { name: 'HMAC', hash: 'SHA-1' }, false, ['sign']);
  const mac = await crypto.subtle.sign('HMAC', key, enc.encode(twilioSignatureData(url, params)));
  return btoa(String.fromCharCode(...new Uint8Array(mac)));
}

function timingSafeEqual(a: string, b: string): boolean {
  const x = enc.encode(a);
  const y = enc.encode(b);
  let diff = x.length ^ y.length;
  for (let i = 0; i < Math.max(x.length, y.length); i++) diff |= (x[i] ?? 0) ^ (y[i] ?? 0);
  return diff === 0;
}

export async function isValidTwilioSignature(
  authToken: string | undefined,
  url: string,
  params: Iterable<[string, string]>,
  signature: string | null,
): Promise<boolean> {
  if (!authToken || !signature) return false; // fail closed when unconfigured
  const expected = await computeTwilioSignature(authToken, url, params);
  return timingSafeEqual(expected, signature);
}
