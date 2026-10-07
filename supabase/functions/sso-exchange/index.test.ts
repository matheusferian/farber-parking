// deno test --allow-env supabase/functions/sso-exchange/index.test.ts
// Deny paths of sso-exchange that are decided before any database access.
// (The success path is exercised end-to-end against a local Supabase stack.)
import { assertEquals } from 'jsr:@std/assert@1';
import { handle } from './index.ts';

Deno.env.set('FARBEROS_SSO_ISSUER', 'https://farberos.test');
Deno.env.set('FARBEROS_SSO_CLIENT_ID', 'airvalet');
Deno.env.set('FARBEROS_SSO_CLIENT_SECRET', 'secret');
Deno.env.set('FARBEROS_SSO_REDIRECT_URI', 'https://airvalet.test/');
Deno.env.set('SUPABASE_URL', 'http://127.0.0.1:1');
Deno.env.set('SUPABASE_SERVICE_ROLE_KEY', 'x');
Deno.env.set('SUPABASE_ANON_KEY', 'x');

const ORIGIN = 'https://airvalet.test';
function post(body: unknown, origin = ORIGIN) {
  return new Request('https://fn.test/sso-exchange', { method: 'POST', headers: { origin, 'content-type': 'application/json' }, body: JSON.stringify(body) });
}
const good = { code: 'c', code_verifier: 'v'.repeat(43), redirect_uri: 'https://airvalet.test/' };
const claims = { sub: 'p', global_role: 'NONE', application: 'airvalet', permissions: ['airvalet.passengers.view'], external_identity: { system: 'airvalet.user_profiles', id: 'u', username: 'x' } };

function fakeFetch(status: number, json: unknown, calls: Request[] = []) {
  return (async (input: RequestInfo | URL, init?: RequestInit) => {
    calls.push(new Request(input, init));
    return new Response(JSON.stringify(json), { status });
  }) as typeof fetch;
}

Deno.test('CORS: only the registered AirValet origin is echoed', async () => {
  const res = await handle(new Request('https://fn.test', { method: 'OPTIONS', headers: { origin: 'https://evil.test' } }));
  assertEquals(res.headers.get('access-control-allow-origin'), 'null');
  const ok = await handle(new Request('https://fn.test', { method: 'OPTIONS', headers: { origin: ORIGIN } }));
  assertEquals(ok.headers.get('access-control-allow-origin'), ORIGIN);
});

Deno.test('redirect_uri must match exactly; missing code/verifier rejected — FarberOS never called', async () => {
  const calls: Request[] = [];
  for (const body of [{ ...good, redirect_uri: 'https://airvalet.test/x' }, { ...good, code: '' }, { ...good, code_verifier: undefined }]) {
    const res = await handle(post(body), fakeFetch(200, {}, calls));
    assertEquals(res.status, 400);
  }
  assertEquals(calls.length, 0);
});

Deno.test('client secret is sent to FarberOS only via Basic auth, with the PKCE verifier', async () => {
  const calls: Request[] = [];
  await handle(post(good), fakeFetch(400, { error: 'access_denied' }, calls));
  assertEquals(calls[0].url, 'https://farberos.test/api/sso/token');
  assertEquals(calls[0].headers.get('authorization'), 'Basic ' + btoa('airvalet:secret'));
  const body = new URLSearchParams(await calls[0].text());
  assertEquals(body.get('code_verifier'), good.code_verifier);
  assertEquals(body.get('client_secret'), null);
});

Deno.test('IAM denial at FarberOS → 403 access_denied', async () => {
  const res = await handle(post(good), fakeFetch(400, { error: 'access_denied' }));
  assertEquals(res.status, 403);
  assertEquals((await res.json()).error, 'access_denied');
});

Deno.test('claims for another app, without AirValet permissions, or unlinked → denied', async () => {
  for (const [c, err] of [
    [{ ...claims, application: 'revenue' }, 'access_denied'],
    [{ ...claims, permissions: ['farberos.ops.view'] }, 'access_denied'],
    [{ ...claims, external_identity: null }, 'not_linked'],
    [{ ...claims, external_identity: { system: 'revenue.admin_users', id: 'u', username: null } }, 'not_linked'],
  ] as const) {
    const res = await handle(post(good), fakeFetch(200, { access_token: 't', claims: c }));
    assertEquals(res.status, 403);
    assertEquals((await res.json()).error, err);
  }
});

Deno.test('FarberOS unreachable → 502, no session', async () => {
  const res = await handle(post(good), (async () => { throw new Error('down'); }) as typeof fetch);
  assertEquals(res.status, 502);
});
