// ONE LOGIN Phase 2C — "Continue with FarberOS" for HUMAN AirValet accounts.
//
// The browser (sso-client.js) brings back FarberOS's one-time authorization code
// plus its PKCE verifier. This function — server-side, holding the FarberOS client
// secret and the service-role key as Deno env vars only — exchanges the code with
// FarberOS (client-authenticated), lets FarberOS IAM decide (default deny), and only
// then signs the linked AirValet account in by minting a normal Supabase session for it.
//
// Hard limits (independent of what IAM says):
//   * only accounts linked in FarberOS IAM as `airvalet.user_profiles`;
//   * only active HUMAN roles ADMIN / MANAGER;
//   * never a protected/shared account (the makers@ shared operational login) and
//     never IPAD_OPS / IPHONE_OPS / TV_ONLY device accounts.
// Existing username/password login and every device/offline path are untouched.
//
// Env (Supabase function secrets): FARBEROS_SSO_ISSUER, FARBEROS_SSO_CLIENT_ID,
// FARBEROS_SSO_CLIENT_SECRET, FARBEROS_SSO_REDIRECT_URI (exact, e.g.
// https://airvalet.farberos.com/). SUPABASE_URL / SUPABASE_ANON_KEY /
// SUPABASE_SERVICE_ROLE_KEY are provided by the platform.

import { createClient } from 'npm:@supabase/supabase-js@2';
import { jwtSessionId, sealToken } from '../_shared/sso.ts';

const HUMAN_ROLES = ['ADMIN', 'MANAGER'];

type Claims = {
  sub: string;
  global_role: string;
  application: string;
  permissions: string[];
  external_identity: { system: string; id: string; username: string | null } | null;
  expires_at?: string | null;
};

function env(name: string): string {
  const v = Deno.env.get(name);
  if (!v) throw new Error(`missing env ${name}`);
  return v;
}

function cors(origin: string | null, allowed: string): Record<string, string> {
  return {
    'Access-Control-Allow-Origin': origin === allowed ? allowed : 'null',
    'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-client-info',
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    'Vary': 'Origin',
    'Cache-Control': 'no-store',
  };
}

function reply(status: number, body: unknown, headers: Record<string, string>): Response {
  return new Response(JSON.stringify(body), { status, headers: { ...headers, 'Content-Type': 'application/json' } });
}

export async function handle(req: Request, fetchImpl: typeof fetch = fetch): Promise<Response> {
  const redirectUri = env('FARBEROS_SSO_REDIRECT_URI');
  const allowedOrigin = new URL(redirectUri).origin;
  const headers = cors(req.headers.get('origin'), allowedOrigin);
  if (req.method === 'OPTIONS') return new Response('ok', { headers });
  if (req.method !== 'POST') return reply(405, { error: 'method_not_allowed' }, headers);

  const body = await req.json().catch(() => null) as { code?: string; code_verifier?: string; redirect_uri?: string } | null;
  if (!body?.code || !body.code_verifier || body.redirect_uri !== redirectUri) {
    return reply(400, { error: 'invalid_request' }, headers);
  }

  // 1. Code → claims at FarberOS (client secret never leaves this function).
  const issuer = env('FARBEROS_SSO_ISSUER').replace(/\/+$/, '');
  const clientId = env('FARBEROS_SSO_CLIENT_ID');
  const clientSecret = env('FARBEROS_SSO_CLIENT_SECRET');
  const basic = 'Basic ' + btoa(`${encodeURIComponent(clientId)}:${encodeURIComponent(clientSecret)}`);
  let tokenJson: { access_token?: string; claims?: Claims; error?: string };
  try {
    const res = await fetchImpl(`${issuer}/api/sso/token`, {
      method: 'POST',
      headers: { 'content-type': 'application/x-www-form-urlencoded', authorization: basic },
      body: new URLSearchParams({ grant_type: 'authorization_code', code: body.code, redirect_uri: redirectUri, code_verifier: body.code_verifier }).toString(),
      signal: AbortSignal.timeout(10_000),
    });
    tokenJson = await res.json().catch(() => ({}));
    if (!res.ok || !tokenJson.access_token || !tokenJson.claims) {
      return reply(403, { error: tokenJson.error === 'access_denied' ? 'access_denied' : 'token_error' }, headers);
    }
  } catch {
    return reply(502, { error: 'farberos_unreachable' }, headers);
  }
  const claims = tokenJson.claims;
  const farberosToken = tokenJson.access_token;
  // The FarberOS session is KEPT (sealed below) so sso-revalidate can re-check it every
  // ~5 minutes: FarberOS logout / IAM disable then ends this AirValet session too.
  const revokeAtFarberos = () =>
    fetchImpl(`${issuer}/api/sso/revoke`, {
      method: 'POST',
      headers: { 'content-type': 'application/x-www-form-urlencoded', authorization: basic },
      body: new URLSearchParams({ token: farberosToken }).toString(),
    }).catch(() => undefined);

  // 2. IAM decides (default deny) — and the mapping must be an AirValet human account.
  const link = claims.external_identity;
  if (claims.application !== 'airvalet' || !claims.permissions.some((p) => p.startsWith('airvalet.'))) {
    await revokeAtFarberos();
    return reply(403, { error: 'access_denied' }, headers);
  }
  if (!link || link.system !== 'airvalet.user_profiles' || !link.id) {
    await revokeAtFarberos();
    return reply(403, { error: 'not_linked' }, headers);
  }

  const admin = createClient(env('SUPABASE_URL'), env('SUPABASE_SERVICE_ROLE_KEY'), { auth: { persistSession: false, autoRefreshToken: false } });
  const { data: profile } = await admin.from('user_profiles').select('id, role, is_active, is_protected').eq('id', link.id).maybeSingle();
  if (!profile || !profile.is_active || profile.is_protected || !HUMAN_ROLES.includes(profile.role)) {
    await revokeAtFarberos();
    return reply(403, { error: 'not_a_human_account' }, headers);
  }

  // 3. IAM is the source of truth for the human role: User Access ⇒ ADMIN, otherwise MANAGER.
  const desiredRole = claims.permissions.includes('airvalet.users.manage') ? 'ADMIN' : 'MANAGER';
  if (profile.role !== desiredRole) {
    const { error } = await admin.from('user_profiles').update({ role: desiredRole, updated_at: new Date().toISOString() }).eq('id', profile.id);
    if (error) return reply(500, { error: 'role_sync_failed' }, headers);
  }

  // 4. Sign the linked account in: one-time magic-link token, verified server-side.
  const { data: authUser } = await admin.auth.admin.getUserById(profile.id);
  const email = authUser?.user?.email;
  if (!email) return reply(403, { error: 'not_a_human_account' }, headers);
  const { data: link2, error: linkErr } = await admin.auth.admin.generateLink({ type: 'magiclink', email });
  const tokenHash = link2?.properties?.hashed_token;
  if (linkErr || !tokenHash) return reply(500, { error: 'session_error' }, headers);
  const anon = createClient(env('SUPABASE_URL'), env('SUPABASE_ANON_KEY'), { auth: { persistSession: false, autoRefreshToken: false } });
  const { data: verified, error: verifyErr } = await anon.auth.verifyOtp({ type: 'magiclink', token_hash: tokenHash });
  if (verifyErr || !verified?.session) return reply(500, { error: 'session_error' }, headers);

  // 5. Register the human SSO session for revalidation — fail closed if we cannot.
  const sessionId = jwtSessionId(verified.session.access_token);
  const expiresAt = claims.expires_at && Number.isFinite(Date.parse(claims.expires_at))
    ? claims.expires_at
    : new Date(Date.now() + 8 * 3600 * 1000).toISOString();
  const { error: regErr } = sessionId
    ? await admin.from('sso_sessions').insert({
        user_id: profile.id,
        supabase_session_id: sessionId,
        farberos_principal_id: claims.sub,
        farberos_token_enc: await sealToken(clientSecret, farberosToken),
        expires_at: expiresAt,
      })
    : { error: { message: 'no session_id claim' } };
  if (regErr) {
    if (sessionId) await admin.rpc('sso_terminate_session', { p_session: sessionId, p_reason: 'registration_failed' });
    await revokeAtFarberos();
    return reply(500, { error: 'session_error' }, headers);
  }

  console.log(`sso-exchange: signed in ${profile.id} (${desiredRole}) for FarberOS principal ${claims.sub}`);
  return reply(200, {
    access_token: verified.session.access_token,
    refresh_token: verified.session.refresh_token,
    expires_in: verified.session.expires_in,
  }, headers);
}

if (import.meta.main) {
  Deno.serve((req) => handle(req).catch((err) => {
    console.error('sso-exchange: unexpected error:', (err as Error).message);
    return new Response(JSON.stringify({ error: 'server_error' }), { status: 500, headers: { 'Content-Type': 'application/json' } });
  }));
}
