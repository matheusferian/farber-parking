// Copied verbatim from event-valet/webpush.ts (2026-10-25) so the main app
// never imports from the Event Valet module. Keep the two in sync by hand.

// Web Push (RFC 8030) with aes128gcm payload encryption (RFC 8291 / RFC 8188)
// and VAPID (RFC 8292), WebCrypto only. Used for operator alerts on the
// Home-Screen installed event page (iOS 16.4+, Chrome, …).

const enc = new TextEncoder();
type Bytes = Uint8Array<ArrayBuffer>;

export const b64u = (u: Uint8Array) => btoa(String.fromCharCode(...u)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
export const unb64u = (s: string): Bytes => Uint8Array.from(atob(s.replace(/-/g, '+').replace(/_/g, '/') + '==='.slice((s.length + 3) % 4)), (c) => c.charCodeAt(0));
const concat = (...parts: Uint8Array[]): Bytes => {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let o = 0;
  for (const p of parts) { out.set(p, o); o += p.length; }
  return out;
};

async function hkdf(salt: Bytes, ikm: Bytes, info: Bytes, len: number): Promise<Bytes> {
  const key = await crypto.subtle.importKey('raw', ikm, 'HKDF', false, ['deriveBits']);
  return new Uint8Array(await crypto.subtle.deriveBits({ name: 'HKDF', hash: 'SHA-256', salt, info }, key, len * 8));
}

export type PushSub = { endpoint: string; p256dh: string; auth: string };

// RFC 8291 §3.4: one record, padding delimiter 0x02.
export async function encryptPayload(sub: PushSub, plaintext: Bytes, saltIn?: Bytes, asKeys?: CryptoKeyPair): Promise<Bytes> {
  const uaPublic = unb64u(sub.p256dh);
  const authSecret = unb64u(sub.auth);
  const as = asKeys ?? await crypto.subtle.generateKey({ name: 'ECDH', namedCurve: 'P-256' }, true, ['deriveBits']) as CryptoKeyPair;
  const asPublic = new Uint8Array(await crypto.subtle.exportKey('raw', as.publicKey));
  const uaKey = await crypto.subtle.importKey('raw', uaPublic, { name: 'ECDH', namedCurve: 'P-256' }, false, []);
  const shared = new Uint8Array(await crypto.subtle.deriveBits({ name: 'ECDH', public: uaKey }, as.privateKey, 256));
  const ikm = await hkdf(authSecret, shared, concat(enc.encode('WebPush: info\0'), uaPublic, asPublic), 32);
  const salt = saltIn ?? crypto.getRandomValues(new Uint8Array(16));
  const cek = await hkdf(salt, ikm, enc.encode('Content-Encoding: aes128gcm\0'), 16);
  const nonce = await hkdf(salt, ikm, enc.encode('Content-Encoding: nonce\0'), 12);
  const key = await crypto.subtle.importKey('raw', cek, 'AES-GCM', false, ['encrypt']);
  const ct = new Uint8Array(await crypto.subtle.encrypt({ name: 'AES-GCM', iv: nonce }, key, concat(plaintext, new Uint8Array([2]))));
  const rs = new Uint8Array([0, 0, 0x10, 0]); // 4096
  return concat(salt, rs, new Uint8Array([asPublic.length]), asPublic, ct);
}

// VAPID JWT (ES256). WebCrypto ECDSA already returns raw r||s (JOSE format).
export async function vapidAuth(endpoint: string, privateJwk: JsonWebKey, publicKeyB64u: string, subject: string): Promise<string> {
  const aud = new URL(endpoint).origin;
  const header = b64u(enc.encode(JSON.stringify({ typ: 'JWT', alg: 'ES256' })));
  const payload = b64u(enc.encode(JSON.stringify({ aud, exp: Math.floor(Date.now() / 1000) + 12 * 3600, sub: subject })));
  const key = await crypto.subtle.importKey('jwk', privateJwk, { name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign']);
  const sig = new Uint8Array(await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, key, enc.encode(`${header}.${payload}`)));
  return `vapid t=${header}.${payload}.${b64u(sig)}, k=${publicKeyB64u}`;
}

export type PushResult = { ok: boolean; status: number; gone: boolean };

export async function sendPush(sub: PushSub, data: unknown, vapid: { privateJwk: JsonWebKey; publicKey: string; subject: string },
  fetchImpl: typeof fetch = fetch): Promise<PushResult> {
  if (!/^https:\/\//.test(sub.endpoint)) return { ok: false, status: 0, gone: true };
  const body = await encryptPayload(sub, enc.encode(JSON.stringify(data)));
  try {
    const r = await fetchImpl(sub.endpoint, {
      method: 'POST',
      headers: {
        Authorization: await vapidAuth(sub.endpoint, vapid.privateJwk, vapid.publicKey, vapid.subject),
        'Content-Encoding': 'aes128gcm',
        'Content-Type': 'application/octet-stream',
        TTL: '600',
        Urgency: 'high',
      },
      body,
      signal: AbortSignal.timeout(8000),
    });
    await r.body?.cancel();
    return { ok: r.status >= 200 && r.status < 300, status: r.status, gone: r.status === 404 || r.status === 410 };
  } catch {
    return { ok: false, status: 0, gone: false };
  }
}
