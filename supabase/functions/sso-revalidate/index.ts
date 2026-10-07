// ONE LOGIN Phase 2C — revalidates HUMAN FarberOS-SSO sessions (cron, every minute).
//
// For each public.sso_sessions row not validated in the last 5 minutes it asks FarberOS
// (/api/sso/userinfo, with the session's own FarberOS token):
//   * still allowed            → keep; sync ADMIN/MANAGER from IAM; stamp last_validated_at
//   * 401 (logout / disabled /
//     grant removed)            → sso_terminate_session (role check denies at once, refresh
//                                 tokens deleted)
//   * FarberOS unreachable      → keep for up to 15 minutes since the last good check, then
//                                 terminate (fail closed)
// It never reads or touches anything but sso_sessions rows: makers@, iPad / iPhone / TV,
// password and offline sessions have no row and are completely independent of FarberOS.
//
// Auth: X-SSO-Revalidate-Secret header (constant-time) checked before anything else.
// Env: SSO_REVALIDATE_SCHEDULER_SECRET, FARBEROS_SSO_ISSUER, FARBEROS_SSO_CLIENT_SECRET,
//      SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY (platform).

import { createClient } from 'npm:@supabase/supabase-js@2';
import { decide, openToken, REVALIDATE_EVERY_MS, type UserinfoOutcome } from '../_shared/sso.ts';

function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' } });
}

export async function handle(req: Request, fetchImpl: typeof fetch = fetch, now = Date.now()): Promise<Response> {
  const expected = Deno.env.get('SSO_REVALIDATE_SCHEDULER_SECRET');
  if (!expected) return json(500, { error: 'scheduler_secret_not_configured' });
  const provided = req.headers.get('X-SSO-Revalidate-Secret') ?? '';
  if (!timingSafeEqual(provided, expected)) return json(401, { error: 'unauthorized' });

  const issuer = (Deno.env.get('FARBEROS_SSO_ISSUER') ?? '').replace(/\/+$/, '');
  const clientSecret = Deno.env.get('FARBEROS_SSO_CLIENT_SECRET') ?? '';
  const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const { data: due, error } = await admin
    .from('sso_sessions')
    .select('id, user_id, supabase_session_id, farberos_principal_id, farberos_token_enc, expires_at, last_validated_at')
    .is('revoked_at', null)
    .lt('last_validated_at', new Date(now - REVALIDATE_EVERY_MS).toISOString())
    .order('last_validated_at', { ascending: true })
    .limit(200);
  if (error) return json(500, { error: 'query_failed' });

  const summary = { checked: 0, kept: 0, terminated: 0, waiting: 0 };
  for (const s of due ?? []) {
    summary.checked++;
    let outcome: UserinfoOutcome;
    const token = issuer && clientSecret ? await openToken(clientSecret, s.farberos_token_enc) : null;
    if (!token) {
      outcome = { kind: 'unreachable' };
    } else {
      try {
        const res = await fetchImpl(`${issuer}/api/sso/userinfo`, { headers: { authorization: `Bearer ${token}` }, signal: AbortSignal.timeout(5_000) });
        outcome = res.status === 401 ? { kind: 'revoked' } : res.ok ? { kind: 'ok', claims: await res.json() } : { kind: 'unreachable' };
      } catch {
        outcome = { kind: 'unreachable' };
      }
    }

    const d = decide(s, outcome, now);
    if (d.action === 'terminate') {
      await admin.rpc('sso_terminate_session', { p_session: s.supabase_session_id, p_reason: d.reason });
      summary.terminated++;
      console.log(`sso-revalidate: terminated ${s.supabase_session_id} (${d.reason})`);
    } else if (d.action === 'keep') {
      await admin.from('user_profiles').update({ role: d.role, updated_at: new Date(now).toISOString() }).eq('id', s.user_id).neq('role', d.role);
      await admin.from('sso_sessions').update({ last_validated_at: new Date(now).toISOString() }).eq('id', s.id);
      summary.kept++;
    } else {
      summary.waiting++;
    }
  }
  return json(200, summary);
}

if (import.meta.main) {
  Deno.serve((req) => handle(req).catch((err) => {
    console.error('sso-revalidate: unexpected error:', (err as Error).message);
    return json(500, { error: 'server_error' });
  }));
}
