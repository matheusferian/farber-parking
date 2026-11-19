// vehicle-ai — staff take the optional Front / Rear photos at check-in and tap "Fill car from photos";
// this returns make, model and color with a confidence for each. Nothing is saved to the car here:
// the app shows the answer and staff tap "Looks right" (same save as tapping the chips).
//
// Owner 2026-11-19: "AI pode ser o mesmo do Funky Buddha" + "Farber paga" → the same AI as FarberOS
// Vehicle AI (src/lib/vehicle-ai in the farberos repo): same OpenAI model, same prompt and JSON schema,
// billed to Farber's OpenAI account (secret OPENAI_API_KEY in this project = a Farber key made for AirValet).
//
// POST { passenger_id?: number, images: [{ angle: 'front'|'rear', b64: '/9j/…' }] } (1 or 2 images)
// → { ok, result: { vehicle_visible, color, make, model, raw_color_description, confidence: {color,make,model} } }
// Auth: the caller's Supabase JWT + current_user_role() in the ops roles (same as manifest-scan).
// Privacy: photos are not stored here. Each call adds one activity_log row (action VEHICLE_AI) with the
// answer and the token count — that is also the daily cap.

import { createClient } from 'npm:@supabase/supabase-js@2';

const ALLOWED_ORIGINS = ['https://airvalet.farberos.com'];
const OPS = ['ADMIN', 'MANAGER', 'IPAD_OPS', 'IPHONE_OPS'];
const MODEL = Deno.env.get('OPENAI_VEHICLE_MODEL') || 'gpt-5.4-nano';   // FarberOS default
const MAX_IMAGES = 2, MAX_B64 = 900_000, CALLS_PER_DAY = 200, TIMEOUT_MS = 20_000;
const ANGLES = ['front', 'rear'];
const OPENAI_URL = (Deno.env.get('OPENAI_BASE_URL') || 'https://api.openai.com/v1') + '/chat/completions';

// Same text as FarberOS src/lib/vehicle-ai/prompt.ts, plus one line: several photos may show the same car.
const SYSTEM = `You are a vehicle identification system. Analyze the provided vehicle photo and identify the vehicle's color, make, and model.

Rules:
- Return ONLY the JSON schema requested. No extra text.
- You may get more than one photo (front and rear) of the SAME vehicle; use all of them for one answer.
- For color, use one of these normalized values: Black, White, Gray, Silver, Blue, Red, Green, Brown, Beige, Gold, Orange, Yellow, Purple, Other
- Also provide your detailed raw color observation as raw_color_description.
- Color distinction guidance:
  - WHITE: the paint appears genuinely white — a flat, opaque, non-metallic finish with no gray or silver undertone.
  - SILVER: a light-colored metallic paint with visible metallic flake or sheen, often described as "silver", "champagne silver", or "platinum". Overcast sky reflections on a silver car can wash the hood toward white — look at the lower body panels and bumper for the true tone.
  - GRAY: a darker, non-metallic or muted finish without the bright metallic luster of Silver. Includes charcoal, gunmetal, and medium grays.
  - When strong sunlight or overcast light makes the distinction uncertain between White, Silver, and Gray, reduce color confidence rather than defaulting to White. Reflections and glare do not change the actual paint color.
- For make, use the canonical manufacturer name:
  - "Chevy" → "Chevrolet"
  - "Benz" or "Merc" → "Mercedes-Benz"
  - "VW" → "Volkswagen"
  - "Range Rover" is a model by "Land Rover"
- For model, return the model name only if you can identify it with reasonable confidence.
- Set vehicle_visible to false if no vehicle is clearly visible in the image.
- If you cannot determine a field, set it to null and its confidence to 0.
- Confidence values are 0 to 1. Be calibrated: only score above 0.9 when very certain.
- Do NOT invent or guess values. Null is always better than a wrong answer.`;

const RESPONSE_FORMAT = {
  type: 'json_schema',
  json_schema: {
    name: 'vehicle_identification',
    strict: true,
    schema: {
      type: 'object',
      properties: {
        vehicle_visible: { type: 'boolean' },
        color: { type: ['string', 'null'] },
        make: { type: ['string', 'null'] },
        model: { type: ['string', 'null'] },
        raw_color_description: { type: ['string', 'null'] },
        confidence: {
          type: 'object',
          properties: { color: { type: 'number' }, make: { type: 'number' }, model: { type: 'number' } },
          required: ['color', 'make', 'model'],
          additionalProperties: false,
        },
      },
      required: ['vehicle_visible', 'color', 'make', 'model', 'raw_color_description', 'confidence'],
      additionalProperties: false,
    },
  },
};

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
  const passengerId = Number.isSafeInteger(payload.passenger_id) ? payload.passenger_id as number : null;

  const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
  const caller = createClient(SUPABASE_URL, Deno.env.get('SUPABASE_ANON_KEY')!, {
    global: { headers: { Authorization: authHeader } }, auth: { persistSession: false },
  });
  const [{ data: userData }, { data: role, error: roleErr }] = await Promise.all([caller.auth.getUser(), caller.rpc('current_user_role')]);
  if (roleErr || !userData?.user) return json(401, { ok: false, error: { code: 'UNAUTHENTICATED' } });
  if (!OPS.includes(String(role))) return json(403, { ok: false, error: { code: 'FORBIDDEN' } });

  const apiKey = Deno.env.get('OPENAI_API_KEY');
  if (!apiKey) return json(200, { ok: false, error: { code: 'NOT_CONFIGURED' } });
  const admin = createClient(SUPABASE_URL, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });

  // Daily cap for the whole app (cost guard), counted from the log rows this function writes.
  const since = new Date(Date.now() - 24 * 3600 * 1000).toISOString();
  const { count, error: cErr } = await admin.from('activity_log').select('id', { count: 'exact', head: true })
    .eq('action', 'VEHICLE_AI').gte('created_at', since);
  if (cErr) return json(500, { ok: false, error: { code: 'LOOKUP_FAILED' } });
  if ((count || 0) >= CALLS_PER_DAY) return json(200, { ok: false, error: { code: 'DAILY_LIMIT' } });

  const content: unknown[] = [{ type: 'text', text: images.length > 1 ? 'Identify the vehicle in these photos (front and rear of the same car).' : 'Identify the vehicle in this photo.' }];
  for (const im of images) content.push({ type: 'image_url', image_url: { url: `data:image/jpeg;base64,${im.b64}`, detail: 'auto' } });

  let data: Record<string, unknown>;
  try {
    const ctl = new AbortController(); const t = setTimeout(() => ctl.abort(), TIMEOUT_MS);
    const res = await fetch(OPENAI_URL, {
      method: 'POST', signal: ctl.signal,
      headers: { Authorization: `Bearer ${apiKey}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        model: MODEL,
        messages: [{ role: 'system', content: SYSTEM }, { role: 'user', content }],
        response_format: RESPONSE_FORMAT,
        max_completion_tokens: 2000,
      }),
    });
    clearTimeout(t);
    if (res.status === 401) return json(200, { ok: false, error: { code: 'AI_KEY_INVALID' } });
    if (res.status === 429) return json(200, { ok: false, error: { code: 'AI_BUSY' } });
    if (!res.ok) return json(200, { ok: false, error: { code: 'AI_FAILED', status: res.status } });
    data = await res.json();
  } catch {
    return json(200, { ok: false, error: { code: 'AI_FAILED' } });
  }

  // deno-lint-ignore no-explicit-any
  const choice = (data.choices as any[])?.[0];
  const text = choice?.message?.content;
  if (!text || choice?.message?.refusal) return json(200, { ok: false, error: { code: 'AI_NO_ANSWER' } });
  // deno-lint-ignore no-explicit-any
  let raw: any;
  try { raw = JSON.parse(text); } catch { return json(200, { ok: false, error: { code: 'AI_BAD_JSON' } }); }
  const result = {
    vehicle_visible: !!raw.vehicle_visible,
    color: clean(raw.color), make: clean(raw.make), model: clean(raw.model),
    raw_color_description: clean(raw.raw_color_description),
    confidence: { color: conf(raw.confidence?.color), make: conf(raw.confidence?.make), model: conf(raw.confidence?.model) },
  };

  // deno-lint-ignore no-explicit-any
  const usage = (data.usage || {}) as any;
  await admin.from('activity_log').insert({
    ts: new Date().toLocaleString('en-US', { timeZone: 'America/New_York' }),
    action: 'VEHICLE_AI', passenger_id: passengerId, ticket: '', passenger: '', location: '',
    detail: JSON.stringify({
      model: String(data.model || MODEL), photos: images.map((i) => i.angle), by: userData.user.id,
      tokens_in: usage.prompt_tokens ?? null, tokens_out: usage.completion_tokens ?? null,
      make: result.make, model_name: result.model, color: result.color, confidence: result.confidence,
    }).slice(0, 1900),
  });

  return json(200, { ok: true, result });
});
