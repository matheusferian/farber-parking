// send-sms — authenticated AirValet staff ask the server to send ONE SMS.
//
// POST { passenger_id, message_type, event_ref?, custom_body?, staff_name?, preview? }
// preview: true → returns the exact text, characters, segments and estimated
// cost plus what would block it (consent, opt-out, device, test mode). Sends nothing.
// Header x-airvalet-device: this device's random key (localStorage). Logins are
// shared, so the server only sends from a device an ADMIN APPROVED (the DB
// compares the SHA-256; the key itself is never stored). staff_name = the
// employee picked in the UI (label only, never an authorization).
// Auth: the caller's Supabase JWT (verify_jwt: true) + current_user_role()
// through PostgREST/RLS, exactly like admin-manage-user. The phone number and
// all template variables come from the passengers row on the server — the
// browser can't choose the recipient or the text — except REPLY (staff
// answering in the inbox) and CUSTOM_OPERATIONAL (ADMIN/MANAGER, once approved).
//
// Always answers HTTP 200 with { ok, status, … } for SMS outcomes, so the
// AirValet UI treats an SMS problem as information, never as a failed ticket
// operation. 4xx only for malformed/unauthenticated requests.
//
// Env: see _shared/sms/config.ts. Platform: SUPABASE_URL, SUPABASE_ANON_KEY,
// SUPABASE_SERVICE_ROLE_KEY.

import { createClient } from 'npm:@supabase/supabase-js@2';
import { readSmsConfig } from '../_shared/sms/config.ts';
import { MockProvider, TwilioProvider } from '../_shared/sms/provider.ts';
import { deviceKeyHash, staffLabel } from '../_shared/sms/device.ts';
import { makeRedactor } from '../_shared/sms/sanitize.ts';
import { previewAirValetSms, sendAirValetSms } from '../_shared/sms/service.ts';
import { supabaseSmsStore } from '../_shared/sms/supabase-store.ts';
import type { Role } from '../_shared/sms/templates.ts';

const ALLOWED_ORIGINS = ['https://airvalet.farberos.com', 'https://matheusferian.github.io'];

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
  if (req.method !== 'POST') return json(405, { ok: false, status: 'rejected', error: { code: 'METHOD' } });

  const cfg = readSmsConfig((k) => Deno.env.get(k));
  const redact = makeRedactor([cfg.twilio?.apiKeySecret, cfg.twilio?.authToken, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')]);
  const log = (event: string, data: Record<string, unknown>) => console.log(redact(JSON.stringify({ event, ...data })));
  if (cfg.problems.length) log('sms.config', { problems: cfg.problems });

  const authHeader = req.headers.get('Authorization') || '';
  if (!authHeader.startsWith('Bearer ')) return json(401, { ok: false, status: 'rejected', error: { code: 'UNAUTHENTICATED' } });

  let payload: Record<string, unknown>;
  try { payload = await req.json(); } catch { return json(400, { ok: false, status: 'rejected', error: { code: 'BAD_JSON' } }); }

  const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
  const caller = createClient(SUPABASE_URL, Deno.env.get('SUPABASE_ANON_KEY')!, {
    global: { headers: { Authorization: authHeader } },
    auth: { persistSession: false },
  });
  const [{ data: userData }, { data: role, error: roleErr }] = await Promise.all([
    caller.auth.getUser(),
    caller.rpc('current_user_role'),
  ]);
  if (roleErr || !userData?.user) return json(401, { ok: false, status: 'rejected', error: { code: 'UNAUTHENTICATED' } });

  const admin = createClient(SUPABASE_URL, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });
  // Staff name snapshot for the inbox ("replied by"); never trusted from the body.
  const { data: profile } = await admin.from('user_profiles').select('display_name,username').eq('id', userData.user.id).maybeSingle();
  const provider = cfg.mode === 'allowlist' || cfg.mode === 'live'
    ? new TwilioProvider({ ...cfg.twilio!, timeoutMs: 10_000 })
    : new MockProvider();

  const deps = {
    mode: cfg.mode,
    store: supabaseSmsStore(admin),
    provider,
    allowlist: cfg.allowlist,
    passBaseUrl: cfg.passBaseUrl,
    statusCallbackUrl: provider.name === 'twilio' ? `${cfg.publicFunctionsUrl}/twilio-status-callback` : undefined,
    log,
  };
  const input = {
    passengerId: Number(payload.passenger_id),
    type: String(payload.message_type || ''),
    eventRef: typeof payload.event_ref === 'string' ? payload.event_ref : undefined,
    customBody: typeof payload.custom_body === 'string' ? payload.custom_body : undefined,
    actor: { userId: userData.user.id, role: (role as Role) ?? null, name: staffLabel(payload.staff_name) || profile?.display_name || profile?.username || null },
    deviceKeyHash: await deviceKeyHash(req.headers.get('x-airvalet-device')),
  };
  // Mandatory preview: same renderer and data, nothing claimed or sent.
  if (payload.preview === true) return json(200, await previewAirValetSms(deps, input));
  return json(200, await sendAirValetSms(deps, input));
});
