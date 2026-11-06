// spider-sync (owner 2026-11-06): every minute (pg_cron 'spider-sync', 5:30 AM – 9 PM Fort Lauderdale)
// read the Makers Air fleet positions from Spidertracks (READ-ONLY) into airvalet_spider_state for the TV.
// Auth: cron header X-Makers-Sync-Secret (same secret as makers-sync) or an ops JWT (manual run).
// Login: the owner's Spidertracks user (SPIDER_USER / SPIDER_PASS secrets, set by the owner) through the
// web app's own Cognito pool; the refresh token is kept in airvalet_spider_session (service role only),
// so the robot signs in with the password only when the refresh token is gone.
// A wrong/changed password pushes ONE alert a day to the DAILY phones ("tell Matheus").

import { createClient } from 'npm:@supabase/supabase-js@2';
import { loginPassword, loginRefresh, parseTracks, SpiderAuthError, TRACKS_URL } from '../_shared/spider/spider.ts';
import { notifyCategory } from '../_shared/notify/staff.ts';
import { readVapid } from '../_shared/notify/runtime.ts';

const OPS = ['ADMIN', 'MANAGER', 'IPAD_OPS', 'IPHONE_OPS'];
function timingSafeEqual(a: string, b: string): boolean {
  if (!a || !b || a.length !== b.length) return false;
  let r = 0; for (let i = 0; i < a.length; i++) r |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return r === 0;
}
const json = (status: number, body: unknown) => new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' } });
const etNow = () => {
  const p = Object.fromEntries(new Intl.DateTimeFormat('en-US', { timeZone: 'America/New_York', hour: 'numeric', minute: 'numeric', hour12: false, year: 'numeric', month: '2-digit', day: '2-digit' })
    .formatToParts(new Date()).map((x) => [x.type, x.value]));
  return { min: (+p.hour % 24) * 60 + +p.minute, day: `${p.year}-${p.month}-${p.day}` };
};

Deno.serve(async (req) => {
  if (req.method !== 'POST') return json(405, { ok: false, error: { code: 'METHOD' } });
  const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
  const admin = createClient(SUPABASE_URL, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false, autoRefreshToken: false } });
  const isCron = timingSafeEqual(req.headers.get('X-Makers-Sync-Secret') ?? '', Deno.env.get('MAKERS_SYNC_SECRET') ?? '');
  if (!isCron) {
    const authHeader = req.headers.get('Authorization') || '';
    const caller = createClient(SUPABASE_URL, Deno.env.get('SUPABASE_ANON_KEY')!, { global: { headers: { Authorization: authHeader } }, auth: { persistSession: false } });
    const [{ data: u }, { data: role }] = await Promise.all([caller.auth.getUser(), caller.rpc('current_user_role')]);
    if (!u?.user || !OPS.includes(String(role))) return json(403, { ok: false, error: { code: 'FORBIDDEN' } });
  }
  const now = etNow();
  if (isCron && (now.min < 5 * 60 + 30 || now.min > 21 * 60)) return json(200, { ok: true, skipped: 'night' });
  const user = Deno.env.get('SPIDER_USER'), pass = Deno.env.get('SPIDER_PASS');
  if (!user || !pass) return json(200, { ok: false, error: { code: 'NOT_CONFIGURED' } });

  const { data: sess } = await admin.from('airvalet_spider_session').select('*').eq('id', 1).maybeSingle();
  const saveSession = (patch: Record<string, unknown>) => admin.from('airvalet_spider_session').upsert({ id: 1, ...patch });

  // 1. A valid id token: cached → refresh token → password.
  let idToken: string | null = sess?.id_token && sess?.id_expires_at && Date.parse(sess.id_expires_at) - Date.now() > 120_000 ? sess.id_token : null;
  try {
    if (!idToken && sess?.refresh_token) {
      try { const a = await loginRefresh(sess.refresh_token); idToken = a.idToken; await saveSession({ id_token: a.idToken, id_expires_at: new Date(Date.now() + a.expiresIn * 1000).toISOString() }); }
      catch { idToken = null; }   // refresh token expired/revoked: fall back to the password
    }
    if (!idToken) {
      const a = await loginPassword(user, pass);
      idToken = a.idToken;
      await saveSession({ id_token: a.idToken, refresh_token: a.refreshToken, id_expires_at: new Date(Date.now() + a.expiresIn * 1000).toISOString() });
    }
  } catch (e) {
    const code = e instanceof SpiderAuthError ? e.code : 'AUTH_FAILED';
    await saveSession({ last_error: code, last_error_at: new Date().toISOString(), id_token: null });
    if (code === 'NotAuthorizedException' && sess?.alerted_on !== now.day) {
      await saveSession({ alerted_on: now.day });
      await notifyCategory({ db: admin, vapid: readVapid((k) => Deno.env.get(k)), log: () => {} }, 'DAILY', {
        title: 'Spidertracks robot could not sign in', body: 'Did the Spidertracks password change? Tell Matheus. The TV uses the public radar meanwhile.', url: '/', tag: 'spider-auth' });
    }
    return json(200, { ok: false, error: { code } });
  }

  // 2. Fleet positions (read-only).
  let res = await fetch(TRACKS_URL, { headers: { Authorization: 'Bearer ' + idToken } });
  if (res.status === 401) {   // token revoked early: one fresh sign-in, then give up until the next minute
    try { const a = await loginPassword(user, pass); idToken = a.idToken; await saveSession({ id_token: a.idToken, refresh_token: a.refreshToken, id_expires_at: new Date(Date.now() + a.expiresIn * 1000).toISOString() }); }
    catch { return json(200, { ok: false, error: { code: 'AUTH_FAILED' } }); }
    res = await fetch(TRACKS_URL, { headers: { Authorization: 'Bearer ' + idToken } });
  }
  if (!res.ok) { await saveSession({ last_error: 'HTTP_' + res.status, last_error_at: new Date().toISOString() }); return json(200, { ok: false, error: { code: 'HTTP', status: res.status } }); }
  let positions;
  try { positions = parseTracks(await res.json()); }
  catch { await saveSession({ last_error: 'LAYOUT', last_error_at: new Date().toISOString() }); return json(200, { ok: false, error: { code: 'LAYOUT' } }); }

  // 3. Store, keeping the previous distance to FXE (closing in or going away).
  const { data: prev } = await admin.from('airvalet_spider_state').select('registration,dist_fxe_nm,prev_dist_fxe_nm,last_at');
  const prevBy = new Map((prev || []).map((p) => [p.registration, p]));
  const rows = positions.map((p) => {
    const old = prevBy.get(p.registration);
    const moved = old && old.last_at && Date.parse(old.last_at) < Date.parse(p.last_at);
    return { ...p, prev_dist_fxe_nm: moved ? old!.dist_fxe_nm : (old as { prev_dist_fxe_nm?: number } | undefined)?.prev_dist_fxe_nm ?? null, polled_at: new Date().toISOString() };
  });
  if (rows.length) { const { error } = await admin.from('airvalet_spider_state').upsert(rows); if (error) return json(500, { ok: false, error: { code: 'DB' } }); }
  await saveSession({ last_ok_at: new Date().toISOString(), last_error: null });
  return json(200, { ok: true, aircraft: rows.map((r) => ({ reg: r.registration, status: r.track_status, nm: r.dist_fxe_nm, kt: r.speed_kt, inbound: r.inbound })) });
});
