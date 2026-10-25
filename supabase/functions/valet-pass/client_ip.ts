// Client address for the per-client throttle (audit 2026-10-25, Portal F-2).
//
// CF-Connecting-IP is written by Cloudflare with the real peer and cannot be
// set by the caller, so it wins when present. Without it we keep the previous
// behaviour (first X-Forwarded-For value): switching to "last hop" blindly is
// unsafe — on a stack where the last hop is a shared internal proxy, every
// passenger would share one throttle bucket and the portal would lock for all
// (seen on the local stack, where CF-Connecting-IP does not reach the function).
// Confirm the production headers before tightening this further.
const MAX_LEN = 64;

function clean(v: string | null | undefined): string {
  const s = (v || '').trim();
  return s.length > 0 && s.length <= MAX_LEN ? s : '';
}

export function clientAddress(headers: Headers): string | null {
  const cf = clean(headers.get('cf-connecting-ip'));
  if (cf) return cf;
  const first = clean((headers.get('x-forwarded-for') || '').split(',')[0]);
  if (first) return first;
  return clean(headers.get('x-real-ip')) || null;
}
