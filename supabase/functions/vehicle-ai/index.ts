// vehicle-ai — staff take the optional Front / Rear photos at check-in and tap "Fill car from photos";
// this returns make, model and color with a confidence for each. Nothing is saved to the car here:
// the app shows the answer and staff tap "Looks right" (same save as tapping the chips).
//
// Owner 2026-11-19: "AI pode ser o mesmo do Funky Buddha", "Farber paga", "AirValet usa a FarberOS".
// So this function does NOT call OpenAI itself: it checks the staff login and the daily cap here, then
// asks FarberOS (POST /api/airvalet/vehicle-ai), which runs the SAME Vehicle AI as Funky Buddha (same
// model, prompt, OpenAI key and cost log on FarberOS /admin/ai). No OpenAI key lives in this project.
// Secrets: AIRVALET_VEHICLE_AI_SECRET (same value as on FarberOS), optional FARBEROS_VEHICLE_AI_URL.
//
// POST { passenger_id?: number, images: [{ angle: 'front'|'rear', b64: '/9j/…' }] } (1 or 2 images)
// → { ok, result: { vehicle_visible, color, make, model, raw_color_description, confidence: {color,make,model} } }
// Auth: the caller's Supabase JWT + current_user_role() in the ops roles (same as manifest-scan).
// Privacy: photos are not stored (here or on FarberOS). Each call adds one activity_log row
// (action VEHICLE_AI) with the answer — that is also the daily cap.

import { createClient } from 'npm:@supabase/supabase-js@2';

const ALLOWED_ORIGINS = ['https://airvalet.farberos.com'];
const OPS = ['ADMIN', 'MANAGER', 'IPAD_OPS', 'IPHONE_OPS'];
const MAX_IMAGES = 2, MAX_B64 = 900_000, CALLS_PER_DAY = 200, TIMEOUT_MS = 40_000;
const ANGLES = ['front', 'rear', 'auto'];   // auto (owner 11/19): ONE photo, FarberOS also says front / rear
const FARBEROS_URL = Deno.env.get('FARBEROS_VEHICLE_AI_URL') || 'https://farberos.com/api/airvalet/vehicle-ai';

// Placeholder words the model sometimes returns instead of null (FarberOS vehicle-update-rules).
const PLACEHOLDER = /^(null|none|unknown|n\/a|na|other|-|\?)$/i;
function clean(v: unknown): string | null {
  if (typeof v !== 'string') return null;
  const s = v.trim();
  return s && !PLACEHOLDER.test(s) ? s.slice(0, 40) : null;
}
function conf(v: unknown): number {
  const n = typeof v === 'number' ? v : 0;
  return Number.isFinite(n) ? Math.max(0, Math.min(1, n)) : 0;
}

function cors(origin: string | null): Record<string, string> {
  return {
    'Access-Control-Allow-Origin': origin && ALLOWED_ORIGINS.includes(origin) ? origin : ALLOWED_ORIGINS[0],
    'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, prefer',
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
  const images = (Array.isArray(payload.images) ? payload.images : []) as { angle: string; b64: string }[];
  if (images.length < 1 || images.length > MAX_IMAGES) return json(400, { ok: false, error: { code: 'NEED_1_OR_2_PHOTOS' } });
  if (!images.every((x) => x && ANGLES.includes(x.angle) && typeof x.b64 === 'string' && x.b64.startsWith('/9j/') && x.b64.length <= MAX_B64)) {
    return json(400, { ok: false, error: { code: 'BAD_IMAGE' } });
  }
  if (images.some((x) => x.angle === 'auto') && images.length !== 1) return json(400, { ok: false, error: { code: 'BAD_IMAGE' } });
  const passengerId = Number.isSafeInteger(payload.passenger_id) ? payload.passenger_id as number : null;

  const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
  const caller = createClient(SUPABASE_URL, Deno.env.get('SUPABASE_ANON_KEY')!, {
    global: { headers: { Authorization: authHeader } }, auth: { persistSession: false },
  });
  const [{ data: userData }, { data: role, error: roleErr }] = await Promise.all([caller.auth.getUser(), caller.rpc('current_user_role')]);
  if (roleErr || !userData?.user) return json(401, { ok: false, error: { code: 'UNAUTHENTICATED' } });
  if (!OPS.includes(String(role))) return json(403, { ok: false, error: { code: 'FORBIDDEN' } });

  const secret = Deno.env.get('AIRVALET_VEHICLE_AI_SECRET');
  if (!secret) return json(200, { ok: false, error: { code: 'NOT_CONFIGURED' } });
  const admin = createClient(SUPABASE_URL, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });

  // Daily cap for the whole app (cost guard), counted from the log rows this function writes.
  const since = new Date(Date.now() - 24 * 3600 * 1000).toISOString();
  const { count, error: cErr } = await admin.from('activity_log').select('id', { count: 'exact', head: true })
    .eq('action', 'VEHICLE_AI').gte('created_at', since);
  if (cErr) return json(500, { ok: false, error: { code: 'LOOKUP_FAILED' } });
  if ((count || 0) >= CALLS_PER_DAY) return json(200, { ok: false, error: { code: 'DAILY_LIMIT' } });

  // deno-lint-ignore no-explicit-any
  let data: any;
  try {
    const ctl = new AbortController(); const t = setTimeout(() => ctl.abort(), TIMEOUT_MS);
    const res = await fetch(FARBEROS_URL, {
      method: 'POST', signal: ctl.signal,
      headers: { Authorization: `Bearer ${secret}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ images: images.map((i) => ({ angle: i.angle, b64: i.b64 })) }),
    });
    clearTimeout(t);
    data = await res.json().catch(() => null);
    if (!data?.ok) {
      const e = String(data?.error || '');
      const code = e === 'AI_DISABLED' || e === 'NO_API_KEY' || e === 'NOT_CONFIGURED' || res.status === 401 ? 'NOT_CONFIGURED'
        : e === 'AI_BUSY' ? 'AI_BUSY' : e === 'AI_KEY_INVALID' || e === 'AI_QUOTA' ? 'AI_KEY_INVALID' : 'AI_FAILED';
      return json(200, { ok: false, error: { code } });
    }
  } catch {
    return json(200, { ok: false, error: { code: 'AI_FAILED' } });
  }
  const raw = data.result || {};
  const result = {
    vehicle_visible: !!raw.vehicle_visible,
    color: clean(raw.color), make: clean(raw.make), model: clean(raw.model),
    raw_color_description: clean(raw.raw_color_description),
    confidence: { color: conf(raw.confidence?.color), make: conf(raw.confidence?.make), model: conf(raw.confidence?.model), plate: conf(raw.confidence?.plate) },
    view: ['front', 'rear', 'side'].includes(raw.view) ? raw.view : null,
    // Owner 2026-11-19: the plate as printed (upper case, letters/digits), null when the AI was not sure.
    plate: typeof raw.plate === 'string' && /^[A-Z0-9]{2,10}$/.test(raw.plate.toUpperCase().replace(/[\s-]/g, '')) ? raw.plate.toUpperCase().replace(/[\s-]/g, '') : null,
    plate_state: typeof raw.plate_state === 'string' && raw.plate_state.trim().length >= 2 ? raw.plate_state.trim().toUpperCase().slice(0, 20) : null,
  };

  await admin.from('activity_log').insert({
    ts: new Date().toLocaleString('en-US', { timeZone: 'America/New_York' }),
    action: 'VEHICLE_AI', passenger_id: passengerId, ticket: '', passenger: '', location: '',
    detail: JSON.stringify({
      via: 'farberos', model: String(data.model || ''), photos: images.map((i) => i.angle), by: userData.user.id,
      make: result.make, model_name: result.model, color: result.color, plate_read: !!result.plate, confidence: result.confidence,
    }).slice(0, 1900),
  });

  return json(200, { ok: true, result });
});
