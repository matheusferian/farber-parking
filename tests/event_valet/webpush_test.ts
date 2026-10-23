// RFC 8291 §5 test vector + VAPID signature check.
import { assert, assertEquals } from 'jsr:@std/assert@1';
import { b64u, encryptPayload, unb64u, vapidAuth } from '../../supabase/functions/event-valet/webpush.ts';

Deno.test('RFC 8291 example: byte-exact ciphertext', async () => {
  const asPub = unb64u('BP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A8');
  const jwk = { kty: 'EC', crv: 'P-256', d: 'yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw', x: b64u(asPub.slice(1, 33)), y: b64u(asPub.slice(33, 65)) };
  const priv = await crypto.subtle.importKey('jwk', jwk, { name: 'ECDH', namedCurve: 'P-256' }, true, ['deriveBits']);
  const pub = await crypto.subtle.importKey('raw', asPub, { name: 'ECDH', namedCurve: 'P-256' }, true, []);
  const out = await encryptPayload(
    { endpoint: 'https://x', p256dh: 'BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4', auth: 'BTBZMqHH6r4Tts7J_aSIgg' },
    new TextEncoder().encode('When I grow up, I want to be a watermelon'),
    unb64u('DGv6ra1nlYgDCS1FRnbzlw'), { privateKey: priv, publicKey: pub });
  assertEquals(b64u(out), 'DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPTpK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN');
});

Deno.test('VAPID JWT verifies with the public key, aud = push service origin', async () => {
  const kp = await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']) as CryptoKeyPair;
  const pubRaw = new Uint8Array(await crypto.subtle.exportKey('raw', kp.publicKey));
  const h = await vapidAuth('https://web.push.apple.com/QGuQ', await crypto.subtle.exportKey('jwk', kp.privateKey), b64u(pubRaw), 'mailto:info@farberparking.com');
  const m = h.match(/^vapid t=([^.]+)\.([^.]+)\.([^,]+), k=(.+)$/)!;
  const payload = JSON.parse(new TextDecoder().decode(unb64u(m[2])));
  assertEquals(payload.aud, 'https://web.push.apple.com');
  assert(payload.exp > Date.now() / 1000 && payload.exp < Date.now() / 1000 + 86400);
  assert(await crypto.subtle.verify({ name: 'ECDSA', hash: 'SHA-256' }, kp.publicKey, unb64u(m[3]), new TextEncoder().encode(`${m[1]}.${m[2]}`)));
});
