// pass-share — staff create a guest's valet pass link WITHOUT sending a text,
// for an international number (incl. +1 Caribbean). Twilio never texts those
// (cost): staff send the link from the device by WhatsApp or iMessage.
//
// POST { passenger_id } → { ok, url, body, phone } where body is the welcome
// text with the link. Each call mints a NEW link (the previous one stops
// working, airvalet_pass_mint rotates). Only tickets enrolled at check-in
// (consent recorded on an approved device) get a link.
// Auth: the caller's Supabase JWT + current_user_role(), like send-sms.
// US/Canada numbers are refused (they get the pass by the normal welcome SMS).

import { createClient } from 'npm:@supabase/supabase-js@2';
import { readSmsConfig } from '../_shared/sms/config.ts';
import { isTwilioDomestic, normalizePhoneE164 } from '../_shared/sms/phone.ts';
import { shareWelcomeBody } from '../_shared/sms/templates.ts';

const ALLOWED_ORIGINS = ['https://airvalet.farberos.com', 'https://matheusferian.github.io'];
const OPS = ['ADMIN', 'MANAGER', 'IPAD_OPS', 'IPHONE_OPS'];

function cors(origin: string | null): Record<string, string> {
  return {
    'Access-Control-Allow-Origin': origin && ALLOWED_ORIGINS.includes(origin) ? origin : ALLOWED_ORIGINS[0],
    'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-airvalet-device',
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    Vary: 'Origin',
  };
}

Deno.serve(async (req) => {
  const headers = { ...cors(req.headers.get('origin')), 'Content-Type': 'application/json' };
  const json = (status: number, body: unknown) => new Response(JSON.stringify(body), { status, headers });
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers });
  if (req.method !== 'POST') return json(405, { ok: false, error: { code: 'METHOD' } });

  const authHeader = req.headers.get('Authorization') || '';
  if (!authHeader.startsWith('Bearer ')) return json(401, { ok: false, error: { code: 'UNAUTHENTICATED' } });
  let payload: Record<string, unknown>;
  try { payload = await req.json(); } catch { return json(400, { ok: false, error: { code: 'BAD_JSON' } }); }
  const passengerId = Number(payload.passenger_id);
  if (!Number.isSafeInteger(passengerId) || passengerId <= 0) return json(400, { ok: false, error: { code: 'INVALID_PASSENGER' } });

  const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
  const caller = createClient(SUPABASE_URL, Deno.env.get('SUPABASE_ANON_KEY')!, {
    global: { headers: { Authorization: authHeader } },
    auth: { persistSession: false },
  });
  const [{ data: userData }, { data: role, error: roleErr }] = await Promise.all([
    caller.auth.getUser(),
    caller.rpc('current_user_role'),
  ]);
  if (roleErr || !userData?.user) return json(401, { ok: false, error: { code: 'UNAUTHENTICATED' } });
  if (!OPS.includes(String(role))) return json(403, { ok: false, error: { code: 'FORBIDDEN' } });

  const cfg = readSmsConfig((k) => Deno.env.get(k));
  const admin = createClient(SUPABASE_URL, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });
  const { data: p, error: pErr } = await admin.from('passengers').select('id,name,phone,ticket,loc').eq('id', passengerId).maybeSingle();
  if (pErr) return json(500, { ok: false, error: { code: 'LOOKUP_FAILED' } });
  if (!p) return json(200, { ok: false, error: { code: 'PASSENGER_NOT_FOUND' } });
  const phone = normalizePhoneE164(p.phone);
  if (!phone.valid) return json(200, { ok: false, error: { code: 'INVALID_PHONE' } });
  if (isTwilioDomestic(phone.e164)) return json(200, { ok: false, error: { code: 'DOMESTIC_USE_SMS' } });

  const { data: token, error: mErr } = await admin.rpc('airvalet_pass_mint', { p_passenger_id: passengerId });
  if (mErr) return json(500, { ok: false, error: { code: 'MINT_FAILED' } });
  // null: not enrolled at check-in (no consent / unapproved device) or archived.
  if (!token) return json(200, { ok: false, error: { code: 'NO_PASS_LINK' } });

  const url = cfg.passBaseUrl + token;
  const ts = new Date().toLocaleString('en-US', { timeZone: 'America/New_York' });
  await admin.from('activity_log').insert({
    ts, action: 'EDITED', passenger: p.name || '', ticket: p.ticket || '', location: p.loc || '',
    detail: 'Valet pass link created to share by WhatsApp / iMessage (international number, no SMS)',
    passenger_id: p.id, changed_by: userData.user.email || null,
  });
  return json(200, { ok: true, url, body: shareWelcomeBody(url), phone: phone.e164 });
});
