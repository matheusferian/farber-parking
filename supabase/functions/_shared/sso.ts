// Shared by sso-exchange and sso-revalidate (ONE LOGIN Phase 2C).
//  * AES-256-GCM sealing of the FarberOS access token at rest (key derived from the
//    FarberOS client secret, which only these two server-side functions hold).
//  * The revalidation decision, as a pure function (unit-tested).

const enc = new TextEncoder();
const dec = new TextDecoder();

function b64url(bytes: Uint8Array): string {
  let s = '';
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}
function unb64url(s: string): Uint8Array<ArrayBuffer> {
  const bin = atob(s.replace(/-/g, '+').replace(/_/g, '/') + '==='.slice((s.length + 3) % 4));
  const out = new Uint8Array(new ArrayBuffer(bin.length));
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

async function key(secret: string): Promise<CryptoKey> {
  const raw = await crypto.subtle.digest('SHA-256', enc.encode(`airvalet-sso-token:${secret}`));
  return crypto.subtle.importKey('raw', raw, 'AES-GCM', false, ['encrypt', 'decrypt']);
}

export async function sealToken(secret: string, token: string): Promise<string> {
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const ct = new Uint8Array(await crypto.subtle.encrypt({ name: 'AES-GCM', iv }, await key(secret), enc.encode(token)));
  return `${b64url(iv)}.${b64url(ct)}`;
}

export async function openToken(secret: string, sealed: string): Promise<string | null> {
  try {
    const [iv, ct] = sealed.split('.');
    const pt = await crypto.subtle.decrypt({ name: 'AES-GCM', iv: unb64url(iv) }, await key(secret), unb64url(ct));
    return dec.decode(pt);
  } catch {
    return null;
  }
}

/** Supabase access tokens carry the auth session id in the `session_id` claim. */
export function jwtSessionId(accessToken: string): string | null {
  try {
    const payload = JSON.parse(dec.decode(unb64url(accessToken.split('.')[1])));
    return typeof payload.session_id === 'string' ? payload.session_id : null;
  } catch {
    return null;
  }
}

export const REVALIDATE_EVERY_MS = 5 * 60 * 1000;
export const GRACE_MS = 15 * 60 * 1000;

export type UserinfoOutcome =
  | { kind: 'ok'; claims: { sub: string; application: string; permissions: string[]; external_identity: { system: string; id: string } | null } }
  | { kind: 'revoked' }
  | { kind: 'unreachable' };

export type Decision =
  | { action: 'keep'; role: 'ADMIN' | 'MANAGER' }
  | { action: 'terminate'; reason: string }
  | { action: 'wait' };

/** What to do with one human SSO session after asking FarberOS. */
export function decide(
  session: { user_id: string; farberos_principal_id: string; expires_at: string; last_validated_at: string },
  outcome: UserinfoOutcome,
  now: number,
): Decision {
  if (Date.parse(session.expires_at) <= now) return { action: 'terminate', reason: 'expired' };
  if (outcome.kind === 'revoked') return { action: 'terminate', reason: 'farberos_revoked' };
  if (outcome.kind === 'unreachable') {
    return now - Date.parse(session.last_validated_at) > GRACE_MS
      ? { action: 'terminate', reason: 'farberos_unreachable' }
      : { action: 'wait' };
  }
  const c = outcome.claims;
  if (c.application !== 'airvalet' || c.sub !== session.farberos_principal_id) return { action: 'terminate', reason: 'identity_changed' };
  if (!c.external_identity || c.external_identity.system !== 'airvalet.user_profiles' || c.external_identity.id !== session.user_id) {
    return { action: 'terminate', reason: 'identity_changed' };
  }
  if (!c.permissions.some((p) => p.startsWith('airvalet.'))) return { action: 'terminate', reason: 'no_airvalet_access' };
  return { action: 'keep', role: c.permissions.includes('airvalet.users.manage') ? 'ADMIN' : 'MANAGER' };
}
