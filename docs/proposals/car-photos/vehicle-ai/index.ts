// DRAFT — NOT DEPLOYED. Proposal 2026-11-18. Kept under docs/ so `supabase functions deploy` never sees it.
//
// vehicle-ai — staff send 2–4 arrival photos of one car; the AI fills make, model, color and plate,
// and notes visible marks. Nothing is saved to the car here: the app shows the suggestion and staff tap
// "Looks right" (or fix a line). Same shape as manifest-scan: staff JWT + ops role, daily cap, JSON schema.
//
// Account: AirValet is Matt Solutions → the existing AirValet ANTHROPIC_API_KEY (the one manifest-scan uses).
// Never the FarberOS OpenAI key (Farber account). The prompt rules come from FarberOS vehicle-ai (prompt.ts).
//
// POST { passenger_id?: number, images: [{ angle: 'driver'|'front'|'passenger'|'rear', b64: '/9j/…' }] }
// → { ok, result: { make, model, color, plate, plate_state, marks: [{where, what}], confidence: {...} } }
// Photos are not stored by this function (the app uploads them to the car-photos bucket separately).

import Anthropic from 'npm:@anthropic-ai/sdk@1.5.0';
import { createClient } from 'npm:@supabase/supabase-js@2';

const ALLOWED_ORIGINS = ['https://airvalet.farberos.com'];
const OPS = ['ADMIN', 'MANAGER', 'IPAD_OPS', 'IPHONE_OPS'];
const MODEL = 'claude-opus-5-5';
const MAX_IMAGES = 4, MAX_B64 = 700_000, CALLS_PER_USER_PER_DAY = 80;
const ANGLES = ['driver', 'front', 'passenger', 'rear'];

const SYSTEM = `You identify one parked car for a valet company from 2 to 4 photos of the same car (driver side, front, passenger side, rear).

Return only the JSON requested.
- make: canonical manufacturer ("Chevy" → "Chevrolet", "Benz" → "Mercedes-Benz", "Range Rover" is a model by "Land Rover"). Decide from the badge, grille and lights; read any lettering first.
- model: only if you can identify it; otherwise null.
- color: one of Black, White, Gray, Silver, Blue, Red, Green, Brown, Gold, Beige, Other. White = flat opaque; Silver = light metallic; Gray = darker, muted. Glare and colored lights do not change the paint: judge from lower panels and lower the confidence when unsure.
- plate: the characters exactly as printed on the plate (no spaces added), from the front or rear photo; null if not fully readable. plate_state: the US state or country printed on the plate, else null. Never guess a character: if one is unclear, set plate to null.
- marks: visible damage only (scratch, dent, crack, missing part), each with where (e.g. "rear bumper, right") and what. Empty list if none is clearly visible. Do not report dirt, reflections, water drops or shadows.
- If the photos show different cars, set same_car to false and lower every confidence below 0.5.
- Confidence 0 to 1, calibrated: above 0.9 only when certain. Null is better than a wrong answer.`;

const str = { type: ['string', 'null'] };
const RESULT_SCHEMA = {
  type: 'object',
  properties: {
    same_car: { type: 'boolean' },
    make: str, model: str, color: str, plate: str, plate_state: str,
    marks: { type: 'array', items: { type: 'object', properties: { where: { type: 'string' }, what: { type: 'string' } }, required: ['where', 'what'], additionalProperties: false } },
    confidence: {
      type: 'object',
      properties: { make: { type: 'number' }, model: { type: 'number' }, color: { type: 'number' }, plate: { type: 'number' } },
      required: ['make', 'model', 'color', 'plate'], additionalProperties: false,
    },
  },
  required: ['same_car', 'make', 'model', 'color', 'plate', 'plate_state', 'marks', 'confidence'],
  additionalProperties: false,
};

function cors(origin: string | null): Record<string, string> {
  return {
    'Access-Control-Allow-Origin': origin && ALLOWED_ORIGINS.includes(origin) ? origin : ALLOWED_ORIGINS[0],
    'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
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
  if (images.length < 2 || images.length > MAX_IMAGES) return json(400, { ok: false, error: { code: 'NEED_2_TO_4_PHOTOS' } });
  if (!images.every((x) => ANGLES.includes(x?.angle) && typeof x?.b64 === 'string' && x.b64.startsWith('/9j/') && x.b64.length <= MAX_B64)) {
    return json(400, { ok: false, error: { code: 'BAD_IMAGE' } });
  }
  const passengerId = Number.isSafeInteger(payload.passenger_id) ? payload.passenger_id as number : null;

  const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
  const caller = createClient(SUPABASE_URL, Deno.env.get('SUPABASE_ANON_KEY')!, {
    global: { headers: { Authorization: authHeader } }, auth: { persistSession: false },
  });
  const [{ data: userData }, { data: role, error: roleErr }] = await Promise.all([caller.auth.getUser(), caller.rpc('current_user_role')]);
  if (roleErr || !userData?.user) return json(401, { ok: false, error: { code: 'UNAUTHENTICATED' } });
  if (!OPS.includes(String(role))) return json(403, { ok: false, error: { code: 'FORBIDDEN' } });

  const apiKey = Deno.env.get('ANTHROPIC_API_KEY');
  if (!apiKey) return json(200, { ok: false, error: { code: 'NOT_CONFIGURED' } });
  const admin = createClient(SUPABASE_URL, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });

  const { count, error: cErr } = await admin.from('airvalet_vehicle_ai').select('id', { count: 'exact', head: true })
    .eq('created_by', userData.user.id).gte('created_at', new Date(Date.now() - 24 * 3600 * 1000).toISOString());
  if (cErr) return json(500, { ok: false, error: { code: 'LOOKUP_FAILED' } });
  if ((count || 0) >= CALLS_PER_USER_PER_DAY) return json(200, { ok: false, error: { code: 'DAILY_LIMIT' } });

  const client = new Anthropic({ apiKey, timeout: 60_000, maxRetries: 1 });
  // deno-lint-ignore no-explicit-any
  const content: any[] = [];
  for (const im of images) {
    content.push({ type: 'text', text: `Photo: ${im.angle}` });
    content.push({ type: 'image', source: { type: 'base64', media_type: 'image/jpeg', data: im.b64 } });
  }
  content.push({ type: 'text', text: 'Identify this car.' });

  let msg;
  try {
    // deno-lint-ignore no-explicit-any
    const params: any = {
      model: MODEL, max_tokens: 4000,
      betas: ['server-side-fallback-2026-07-01'], fallbacks: 'default',
      output_config: { effort: 'low', format: { type: 'json_schema', schema: RESULT_SCHEMA } },
      system: SYSTEM,
      messages: [{ role: 'user', content }],
    };
    msg = await client.beta.messages.create(params);
  } catch (e) {
    if (e instanceof Anthropic.AuthenticationError) return json(200, { ok: false, error: { code: 'AI_KEY_INVALID' } });
    if (e instanceof Anthropic.RateLimitError) return json(200, { ok: false, error: { code: 'AI_BUSY' } });
    return json(200, { ok: false, error: { code: 'AI_FAILED' } });
  }
  if (msg.stop_reason === 'refusal' || msg.stop_reason === 'max_tokens') return json(200, { ok: false, error: { code: 'AI_NO_ANSWER' } });
  // deno-lint-ignore no-explicit-any
  const text = (msg.content as any[]).filter((b) => b.type === 'text').map((b) => b.text).join('');
  let result;
  try { result = JSON.parse(text); } catch { return json(200, { ok: false, error: { code: 'AI_BAD_JSON' } }); }

  await admin.from('airvalet_vehicle_ai').insert({
    passenger_id: passengerId, model: msg.model, created_by: userData.user.id,
    input_tokens: msg.usage?.input_tokens ?? null, output_tokens: msg.usage?.output_tokens ?? null, result,
  });
  return json(200, { ok: true, result });
});
