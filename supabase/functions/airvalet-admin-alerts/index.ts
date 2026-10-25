// airvalet-admin-alerts — Super Admin only (JWT + airvalet_super_admins):
//   POST { action: 'start_verify', phone }  → texts a 6-digit code to that phone
//   POST { action: 'test' }                 → one test copy to the verified phone
// The code is confirmed in the app through airvalet_admin_alerts_confirm().
// Texting follows AIRVALET_SMS_MODE (disabled → nothing is sent). Each send
// is logged in airvalet_notify_log (cost visibility); never to passengers.

import { createClient } from 'npm:@supabase/supabase-js@2';
import { readSmsConfig } from '../_shared/sms/config.ts';
import { normalizePhoneE164 } from '../_shared/sms/phone.ts';
import { makeRedactor } from '../_shared/sms/sanitize.ts';
import { countSegments } from '../_shared/sms/templates.ts';
import { adminSmsProvider } from '../_shared/notify/runtime.ts';

const ALLOWED_ORIGINS = ['https://airvalet.farberos.com'];

Deno.serve(async (req) => {
  const extra = (Deno.env.get('AIRVALET_APP_ORIGINS') || '').split(',').map((s) => s.trim()).filter(Boolean);
  const origins = [...ALLOWED_ORIGINS, ...extra];
  const origin = req.headers.get('origin');
  const headers = {
    'Access-Control-Allow-Origin': origin && origins.includes(origin) ? origin : origins[0],
    'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    'Content-Type': 'application/json',
    Vary: 'Origin',
  };
  const json = (status: number, body: unknown) => new Response(JSON.stringify(body), { status, headers });
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers });
  if (req.method !== 'POST') return json(405, { ok: false, error: 'METHOD' });

  const get = (k: string) => Deno.env.get(k);
  const cfg = readSmsConfig(get);
  const redact = makeRedactor([get('SUPABASE_SERVICE_ROLE_KEY'), cfg.twilio?.apiKeySecret]);
  const log = (event: string, d: Record<string, unknown>) => console.log(redact(JSON.stringify({ event, ...d })));
  const auth = req.headers.get('Authorization') || '';
  if (!auth.startsWith('Bearer ')) return json(401, { ok: false, error: 'UNAUTHENTICATED' });
  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return json(400, { ok: false, error: 'BAD_JSON' }); }

  const caller = createClient(get('SUPABASE_URL')!, get('SUPABASE_ANON_KEY')!, { global: { headers: { Authorization: auth } }, auth: { persistSession: false } });
  const [{ data: u }, { data: isSuper }] = await Promise.all([caller.auth.getUser(), caller.rpc('airvalet_is_super_admin')]);
  if (!u?.user || isSuper !== true) return json(403, { ok: false, error: 'FORBIDDEN' });
  const admin = createClient(get('SUPABASE_URL')!, get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });
  const provider = adminSmsProvider(cfg);
  if (!provider) return json(200, { ok: false, error: 'SMS_DISABLED' });

  let to: string; let text: string; let key: string;
  if (body.action === 'start_verify') {
    const p = normalizePhoneE164(String(body.phone || ''));
    if (!p.valid) return json(200, { ok: false, error: 'INVALID_PHONE' });
    const { data: code, error } = await admin.rpc('airvalet_admin_alerts_start_verify', { p_user: u.user.id, p_phone_e164: p.e164 });
    if (error || !code) return json(200, { ok: false, error: 'NOT_ALLOWED' });
    to = p.e164; text = `AirValet admin alerts: your verification code is ${code}. It expires in 10 minutes.`;
    key = `verify:${crypto.randomUUID()}`;
  } else if (body.action === 'test') {
    const { data: a } = await caller.rpc('airvalet_admin_alerts_get');
    if (!a?.phone_verified || !a?.phone_e164) return json(200, { ok: false, error: 'NOT_VERIFIED' });
    to = a.phone_e164; text = 'AIRVALET TEST\nAdmin alerts are working. Guest messages will arrive here as a short copy.';
    key = `test:${crypto.randomUUID()}`;
  } else {
    return json(400, { ok: false, error: 'ACTION' });
  }

  await admin.rpc('airvalet_notify_claim', { p_dedupe_key: key, p_channel: 'admin_sms' });
  const r = await provider.send({ to, body: text });
  const sent = r.kind === 'accepted';
  await admin.rpc('airvalet_notify_finish', { p_dedupe_key: key, p_status: sent ? 'sent' : 'failed', p_segments: countSegments(text), p_sid: sent ? r.sid : null, p_detail: sent ? body.action : r.errorCode });
  log('admin_alerts.sms', { action: body.action, sent });
  return json(200, { ok: sent, error: sent ? undefined : r.errorCode, segments: countSegments(text) });
});
