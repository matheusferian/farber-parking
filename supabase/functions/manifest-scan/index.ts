// manifest-scan — staff photograph the printed Makers Air passenger manifests (one photo per page)
// and get back who is coming in: early returns, guests expected but not on any list, the tail and
// arrival time to fill in, and names we spelled differently from the manifest (2026-11-06, owner).
//
// POST { images: [base64 JPEG, …] } → { ok, manifest_date, pages: [...], matches, missing, warnings }
// Claude (claude-opus-5-5) only READS each page into fixed JSON (structured output). Who is who is
// decided by _shared/manifest/match.ts with fixed rules. Nothing is written to passengers here:
// staff confirm each change in the app.
// Accuracy checks: each page is read on its own; when the names read do not add up to the page's
// "Total Pax", the page is read again at effort "max"; the same flight photographed twice is kept once.
// Privacy: photos are not stored. The scan log keeps only the rows that matched one of our guests.
// Auth: the caller's Supabase JWT + current_user_role() in the ops roles (same as pass-share).
// Secret: ANTHROPIC_API_KEY (Matt Solutions account), never sent to the browser.

import Anthropic from 'npm:@anthropic-ai/sdk@1.5.0';
import { z } from 'npm:zod@3.25.76';
import { createClient } from 'npm:@supabase/supabase-js@2';
import { Candidate, Feedback, ManifestPage, matchManifest } from '../_shared/manifest/match.ts';

const ALLOWED_ORIGINS = ['https://airvalet.farberos.com', 'https://matheusferian.github.io'];
const OPS = ['ADMIN', 'MANAGER', 'IPAD_OPS', 'IPHONE_OPS'];
const MODEL = 'claude-opus-5-5';
const MAX_IMAGES = 12, MAX_B64 = 2_000_000, SCANS_PER_USER_PER_DAY = 40, PARALLEL = 4;

function cors(origin: string | null): Record<string, string> {
  return {
    'Access-Control-Allow-Origin': origin && ALLOWED_ORIGINS.includes(origin) ? origin : ALLOWED_ORIGINS[0],
    'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, prefer',
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    Vary: 'Origin',
  };
}

const SYSTEM = `You read photos of printed Makers Air "Passenger manifest" pages for a valet company at Fort Lauderdale Executive (FXE).
Each page is one flight. Read ONLY the top sheet that is fully in view; other sheets under it, faint print showing through the paper, and columns cut off at the edge are not part of the page.

Return, exactly as printed:
- flight_number: the number in "Passenger manifest for flight N on MM/DD/YYYY".
- manifest_date: the date in that title, MM/DD/YYYY.
- route: the "Flight #" route, e.g. "GHC-FXE".
- tail_number: "Tail Number", e.g. "N740RV".
- arrival_time: the time after "Arrival : FXE ... at", 24-hour HH:MM.
- total_pax: the number after "Total Pax". 0 if not visible.
- ascend_mark: true only if the word ASCEND is written or stamped on the page.
- client_name: "Client Name" if filled, else "".
- passengers: one entry per numbered row of the passenger table, in order: last ("Last" column, keep suffixes such as JR, II, III), first ("First"), middle ("Midd", "" if empty or cut off), pnr ("PNR"), first_origin ("First Origin"). Names in capitals as printed, letter by letter; never correct or complete a name. Set uncertain=true for a row where any letter of the name is hard to read.
Ignore date of birth, gender, document, phone and weight columns.
If the photo is not a Makers Air passenger manifest, set is_manifest=false and leave the other fields empty.`;

const PassengerSchema = z.object({
  last: z.string(), first: z.string(), middle: z.string(), pnr: z.string(), first_origin: z.string(), uncertain: z.boolean(),
});
const PageSchema = z.object({
  is_manifest: z.boolean(), flight_number: z.string(), manifest_date: z.string(), route: z.string(), tail_number: z.string(),
  arrival_time: z.string(), total_pax: z.number().int(), ascend_mark: z.boolean(), client_name: z.string(),
  passengers: z.array(PassengerSchema),
});
type Page = z.infer<typeof PageSchema>;
const str = { type: 'string' };
const PAGE_JSON_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['is_manifest', 'flight_number', 'manifest_date', 'route', 'tail_number', 'arrival_time', 'total_pax', 'ascend_mark', 'client_name', 'passengers'],
  properties: {
    is_manifest: { type: 'boolean' }, flight_number: str, manifest_date: str, route: str, tail_number: str, arrival_time: str,
    total_pax: { type: 'integer' }, ascend_mark: { type: 'boolean' }, client_name: str,
    passengers: {
      type: 'array',
      items: {
        type: 'object', additionalProperties: false, required: ['last', 'first', 'middle', 'pnr', 'first_origin', 'uncertain'],
        properties: { last: str, first: str, middle: str, pnr: str, first_origin: str, uncertain: { type: 'boolean' } },
      },
    },
  },
};

type Usage = { input_tokens: number; output_tokens: number; calls: number };

async function readPage(client: Anthropic, b64: string, effort: 'high' | 'max', usage: Usage): Promise<Page> {
  // Server-side fallback: if a safety classifier declines, the API re-runs the request on its recommended model.
  // deno-lint-ignore no-explicit-any
  const params: any = {
    model: MODEL, max_tokens: 16000,
    betas: ['server-side-fallback-2026-07-01'], fallbacks: 'default',
    output_config: { effort, format: { type: 'json_schema', schema: PAGE_JSON_SCHEMA } },
    system: SYSTEM,
    messages: [{ role: 'user', content: [
      { type: 'image', source: { type: 'base64', media_type: 'image/jpeg', data: b64 } },
      { type: 'text', text: 'Read this manifest page.' },
    ] }],
  };
  const msg = await client.beta.messages.create(params);
  usage.calls++;
  usage.input_tokens += msg.usage?.input_tokens || 0;
  usage.output_tokens += msg.usage?.output_tokens || 0;
  if (msg.stop_reason === 'refusal') throw new Error('REFUSED');
  if (msg.stop_reason === 'max_tokens') throw new Error('TRUNCATED');
  // deno-lint-ignore no-explicit-any
  const text = (msg.content as any[]).filter((b) => b.type === 'text').map((b) => b.text).join('');
  return PageSchema.parse(JSON.parse(text));
}

async function mapLimit<T, R>(items: T[], limit: number, fn: (x: T, i: number) => Promise<R>): Promise<R[]> {
  const out: R[] = new Array(items.length);
  let next = 0;
  await Promise.all(Array.from({ length: Math.min(limit, items.length) }, async () => {
    while (next < items.length) { const i = next++; out[i] = await fn(items[i], i); }
  }));
  return out;
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
  const images = Array.isArray(payload.images) ? payload.images : [];
  {
    if (!images.length) return json(400, { ok: false, error: { code: 'NO_IMAGES' } });
    if (images.length > MAX_IMAGES) return json(400, { ok: false, error: { code: 'TOO_MANY_IMAGES', max: MAX_IMAGES } });
    if (!images.every((x) => typeof x === 'string' && x.startsWith('/9j/') && x.length <= MAX_B64)) {
      return json(400, { ok: false, error: { code: 'BAD_IMAGE' } });
    }
  }

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

  const { count, error: cErr } = await admin.from('airvalet_manifest_scans').select('id', { count: 'exact', head: true })
    .eq('created_by', userData.user.id).gte('created_at', new Date(Date.now() - 24 * 3600 * 1000).toISOString());
  if (cErr) return json(500, { ok: false, error: { code: 'LOOKUP_FAILED' } });
  if ((count || 0) >= SCANS_PER_USER_PER_DAY) return json(200, { ok: false, error: { code: 'DAILY_LIMIT' } });

  const usage: Usage = { input_tokens: 0, output_tokens: 0, calls: 0 };
  const warnings: { photo: number; code: string; detail?: string }[] = [];
  let pages: Page[];
  {
  const client = new Anthropic({ apiKey, timeout: 120_000, maxRetries: 2 });
  const read = await mapLimit(images as string[], PARALLEL, async (b64, i) => {
    try {
      let pg = await readPage(client, b64, 'high', usage);
      if (pg.is_manifest && pg.total_pax > 0 && pg.passengers.length !== pg.total_pax) {
        const again = await readPage(client, b64, 'max', usage);
        if (again.is_manifest && again.passengers.length === again.total_pax) pg = again;
        else warnings.push({ photo: i + 1, code: 'COUNT_MISMATCH', detail: `${pg.passengers.length}/${pg.total_pax}` });
      }
      if (!pg.is_manifest) { warnings.push({ photo: i + 1, code: 'NOT_A_MANIFEST' }); return null; }
      if (pg.passengers.some((p) => p.uncertain)) warnings.push({ photo: i + 1, code: 'HARD_TO_READ', detail: pg.flight_number });
      return { photo: i + 1, page: pg };
    } catch (e) {
      const m = e instanceof Error ? e.message : '';
      if (e instanceof Anthropic.AuthenticationError) throw e;
      warnings.push({ photo: i + 1, code: m === 'REFUSED' ? 'REFUSED' : m === 'TRUNCATED' ? 'TRUNCATED' : 'READ_FAILED' });
      return null;
    }
  }).catch((e) => e);
  if (read instanceof Anthropic.AuthenticationError) return json(200, { ok: false, error: { code: 'AI_KEY_INVALID' } });
  if (read instanceof Error) return json(200, { ok: false, error: { code: 'READ_FAILED' } });

  // Same flight photographed twice: keep the reading with more rows.
  const byFlight = new Map<string, { photo: number; page: Page }>();
  for (const r of read as ({ photo: number; page: Page } | null)[]) {
    if (!r) continue;
    const key = `${r.page.flight_number}|${r.page.manifest_date}`;
    const prev = byFlight.get(key);
    if (prev) warnings.push({ photo: r.photo, code: 'DUPLICATE_PAGE', detail: r.page.flight_number });
    if (!prev || r.page.passengers.length > prev.page.passengers.length) byFlight.set(key, r);
  }
  pages = [...byFlight.values()].map((r) => r.page);
  }
  if (!pages.length) return json(200, { ok: false, error: { code: 'NO_MANIFEST_READ' }, warnings });

  // Cars we hold + cars delivered on the manifest day(s) (deldate is stored "M/D/YYYY").
  const delDays = [...new Set(pages.flatMap((p) => {
    const m = p.manifest_date.match(/^(\d{1,2})\/(\d{1,2})\/(\d{4})$/);
    return m ? [`${+m[1]}/${+m[2]}/${m[3]}`, `${m[1].padStart(2, '0')}/${m[2].padStart(2, '0')}/${m[3]}`] : [];
  }))];
  const COLS = 'id,ticket,name,ret,status,deldate,return_flight,departure_time,return_operator,archived_at';
  const [{ data: held, error: pErr }, { data: out, error: dErr }, { data: fb, error: fErr }] = await Promise.all([
    admin.from('passengers').select(COLS).eq('status', 'PENDING').limit(2000),
    delDays.length ? admin.from('passengers').select(COLS).eq('status', 'DELIVERED').in('deldate', delDays).limit(500) : Promise.resolve({ data: [], error: null }),
    admin.from('airvalet_manifest_feedback').select('manifest_name,system_name,verdict').limit(5000),
  ]);
  if (pErr || dErr || fErr) return json(500, { ok: false, error: { code: 'LOOKUP_FAILED' } });
  const pool = [...(held || []), ...(out || [])].filter((c) => !c.archived_at) as Candidate[];
  const result = matchManifest(pages as ManifestPage[], pool, (fb || []) as Feedback[]);

  const dates = new Set(pages.map((p) => p.manifest_date));
  if (dates.size > 1) warnings.push({ photo: 0, code: 'MIXED_DATES', detail: [...dates].join(', ') });

  const surprises = result.matches.filter((m) => m.state === 'early' || m.state === 'late' || m.state === 'no_date').length;
  await admin.from('airvalet_manifest_scans').insert({
    created_by: userData.user.id, service_date: result.manifest_date, pages: pages.length, manifest_rows: result.manifest_rows,
    matched: result.matches.length, surprises, missing: result.missing.length,
    result: { matches: result.matches, missing: result.missing, warnings }, usage: { model: MODEL, ...usage },
  });

  return json(200, {
    ok: true, manifest_date: result.manifest_date,
    pages: pages.map((p) => ({ flight_number: p.flight_number, route: p.route, tail_number: p.tail_number, arrival_time: p.arrival_time, total_pax: p.total_pax, read_pax: p.passengers.length, ascend_mark: p.ascend_mark })),
    manifest_rows: result.manifest_rows, matches: result.matches, missing: result.missing, warnings,
  });
});
