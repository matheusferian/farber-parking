// deno test supabase/functions/_shared/sso.test.ts
import { assertEquals, assertNotEquals } from 'jsr:@std/assert@1';
import { decide, GRACE_MS, jwtSessionId, openToken, sealToken } from './sso.ts';

const now = Date.parse('2026-10-07T12:00:00Z');
const session = {
  user_id: 'u-1',
  farberos_principal_id: 'p-1',
  expires_at: '2026-10-07T20:00:00Z',
  last_validated_at: '2026-10-07T11:50:00Z',
};
const claims = { sub: 'p-1', application: 'airvalet', permissions: ['airvalet.passengers.view', 'airvalet.users.manage'], external_identity: { system: 'airvalet.user_profiles', id: 'u-1' } };

Deno.test('still allowed → keep, role from IAM', () => {
  assertEquals(decide(session, { kind: 'ok', claims }, now), { action: 'keep', role: 'ADMIN' });
  assertEquals(decide(session, { kind: 'ok', claims: { ...claims, permissions: ['airvalet.passengers.view'] } }, now), { action: 'keep', role: 'MANAGER' });
});

Deno.test('FarberOS logout / IAM disable (401) → terminate', () => {
  assertEquals(decide(session, { kind: 'revoked' }, now), { action: 'terminate', reason: 'farberos_revoked' });
});

Deno.test('grant removed or identity swapped → terminate', () => {
  assertEquals(decide(session, { kind: 'ok', claims: { ...claims, permissions: ['farberos.ops.view'] } }, now).action, 'terminate');
  assertEquals(decide(session, { kind: 'ok', claims: { ...claims, sub: 'p-2' } }, now).action, 'terminate');
  assertEquals(decide(session, { kind: 'ok', claims: { ...claims, external_identity: { system: 'airvalet.user_profiles', id: 'u-2' } } }, now).action, 'terminate');
});

Deno.test('FarberOS unreachable: wait inside the 15-minute grace, then fail closed', () => {
  assertEquals(decide(session, { kind: 'unreachable' }, now), { action: 'wait' });
  const stale = { ...session, last_validated_at: new Date(now - GRACE_MS - 1).toISOString() };
  assertEquals(decide(stale, { kind: 'unreachable' }, now), { action: 'terminate', reason: 'farberos_unreachable' });
});

Deno.test('expired FarberOS session → terminate even if FarberOS says ok', () => {
  assertEquals(decide({ ...session, expires_at: '2026-10-07T11:59:59Z' }, { kind: 'ok', claims }, now), { action: 'terminate', reason: 'expired' });
});

Deno.test('token sealing: round trip, wrong secret and tampering fail closed', async () => {
  const sealed = await sealToken('client-secret', 'farberos-token-123');
  assertNotEquals(sealed.includes('farberos-token-123'), true);
  assertEquals(await openToken('client-secret', sealed), 'farberos-token-123');
  assertEquals(await openToken('other-secret', sealed), null);
  const [iv, ct] = sealed.split('.');
  assertEquals(await openToken('client-secret', `${iv}.A${ct.slice(1)}`), null);
});

Deno.test('session id from a Supabase access token', () => {
  const payload = btoa(JSON.stringify({ sub: 'u', session_id: '11111111-2222-3333-4444-555555555555' })).replace(/=+$/, '');
  assertEquals(jwtSessionId(`h.${payload}.s`), '11111111-2222-3333-4444-555555555555');
  assertEquals(jwtSessionId('garbage'), null);
});
