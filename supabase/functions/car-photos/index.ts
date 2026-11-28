// car-photos — arrival photos (front / rear) of a car, kept on the server for the car card on every device
// (owner 2026-11-19: "onde conseguimos ver as fotos", "30 dias depois que ele sai").
//
// Staff (Supabase JWT + ops role):
//   POST { action: 'add',  passenger_id, angle: 'front'|'rear', b64: '/9j/…' } → { ok, photo: { id, angle, taken_at, url } }
//   POST { action: 'list', passenger_id }                                      → { ok, photos: [{ id, angle, taken_at, url }] }
//     (newest first; url = signed link valid 1 hour)
//   POST { action: 'thumbs', passenger_ids: [..≤150] }                         → { ok, thumbs: { [id]: { angle, taken_at, url } } }
//     (one small picture per car — newest rear, else newest front; 360 px wide, signed 1 hour)
// Schedule (pg_cron, X-Car-Photos-Secret, constant-time):
//   POST { cleanup: true } → removes files + rows with delete_after < now() and hold = false (max 300 per run)
// Retention is set by the database: delete_after = 30 days after the ticket becomes DELIVERED / ARCHIVED
// (migration 20261156). Files live in the private bucket car-photos; nothing here is public.

import { createClient } from 'npm:@supabase/supabase-js@2';

const ALLOWED_ORIGINS = ['https://airvalet.farberos.com'];
const OPS = ['ADMIN', 'MANAGER', 'IPAD_OPS', 'IPHONE_OPS'];
const BUCKET = 'car-photos';
const MAX_B64 = 1_390_000;   // ≈ 1 MB of JPEG

function cors(origin: string | null): Record<string, string> {
  return {
    'Access-Control-Allow-Origin': origin && ALLOWED_ORIGINS.includes(origin) ? origin : ALLOWED_ORIGINS[0],
    'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, prefer',
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    Vary: 'Origin',
  };
}
function sameSecret(a: string, b: string): boolean {
  if (!a || !b || a.length !== b.length) return false;
  let d = 0; for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}
function b64ToBytes(b64: string): Uint8Array {
  const bin = atob(b64); const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}
async function sha256Hex(bytes: Uint8Array): Promise<string> {
  const h = new Uint8Array(await crypto.subtle.digest('SHA-256', bytes as unknown as ArrayBuffer));
  return Array.from(h, (x) => x.toString(16).padStart(2, '0')).join('');
}

Deno.serve(async (req) => {
  const headers = { ...cors(req.headers.get('origin')), 'Content-Type': 'application/json', 'Cache-Control': 'no-store' };
  const json = (status: number, body: unknown) => new Response(JSON.stringify(body), { status, headers });
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers });
  if (req.method !== 'POST') return json(405, { ok: false, error: { code: 'METHOD' } });

  const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
  const admin = createClient(SUPABASE_URL, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false, autoRefreshToken: false } });
  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return json(400, { ok: false, error: { code: 'BAD_JSON' } }); }

  // ── Daily cleanup (schedule only) ──
  if (body.cleanup === true) {
    if (!sameSecret(req.headers.get('X-Car-Photos-Secret') ?? '', Deno.env.get('CAR_PHOTOS_CLEANUP_SECRET') ?? '')) return json(401, { ok: false, error: { code: 'UNAUTHORIZED' } });
    const { data: due, error } = await admin.from('airvalet_car_photos').select('id,path')
      .lt('delete_after', new Date().toISOString()).eq('hold', false).limit(300);
    if (error) return json(500, { ok: false, error: { code: 'LOOKUP_FAILED' } });
    if (!due?.length) return json(200, { ok: true, removed: 0 });
    const { error: rmErr } = await admin.storage.from(BUCKET).remove(due.map((r) => r.path));
    if (rmErr) return json(500, { ok: false, error: { code: 'REMOVE_FAILED' } });
    await admin.from('airvalet_car_photos').delete().in('id', due.map((r) => r.id));
    console.log(JSON.stringify({ event: 'car_photos.cleanup', removed: due.length }));
    return json(200, { ok: true, removed: due.length });
  }

  // ── Staff ──
  const authHeader = req.headers.get('Authorization') || '';
  if (!authHeader.startsWith('Bearer ')) return json(401, { ok: false, error: { code: 'UNAUTHENTICATED' } });
  const caller = createClient(SUPABASE_URL, Deno.env.get('SUPABASE_ANON_KEY')!, { global: { headers: { Authorization: authHeader } }, auth: { persistSession: false } });
  const [{ data: u }, { data: role, error: roleErr }] = await Promise.all([caller.auth.getUser(), caller.rpc('current_user_role')]);
  if (roleErr || !u?.user) return json(401, { ok: false, error: { code: 'UNAUTHENTICATED' } });
  if (!OPS.includes(String(role))) return json(403, { ok: false, error: { code: 'FORBIDDEN' } });

  // Cars by hangar (owner 2026-11-27): one small picture per car, rear first (shows the plate), else front.
  if (body.action === 'thumbs') {
    const ids = Array.isArray(body.passenger_ids) ? body.passenger_ids.map(Number).filter((n) => Number.isSafeInteger(n) && n > 0) : [];
    if (!ids.length || ids.length > 150) return json(400, { ok: false, error: { code: 'BAD_PASSENGERS' } });
    const { data: rows, error } = await admin.from('airvalet_car_photos').select('passenger_id,angle,taken_at,path')
      .in('passenger_id', ids).order('taken_at', { ascending: false }).limit(1000);
    if (error) return json(500, { ok: false, error: { code: 'LOOKUP_FAILED' } });
    const pick: Record<number, { angle: string; taken_at: string; path: string }> = {};
    for (const r of rows || []) {
      const cur = pick[r.passenger_id];
      if (!cur || (cur.angle !== 'rear' && r.angle === 'rear')) pick[r.passenger_id] = r;
    }
    const thumbs: Record<number, { angle: string; taken_at: string; url: string | null }> = {};
    await Promise.all(Object.entries(pick).map(async ([k, r]) => {
      const { data } = await admin.storage.from(BUCKET).createSignedUrl(r.path, 3600, { transform: { width: 360, quality: 60 } });
      thumbs[Number(k)] = { angle: r.angle, taken_at: r.taken_at, url: data?.signedUrl || null };
    }));
    return json(200, { ok: true, thumbs });
  }

  const pid = Number(body.passenger_id);
  if (!Number.isSafeInteger(pid) || pid <= 0) return json(400, { ok: false, error: { code: 'BAD_PASSENGER' } });
  const { data: pax } = await admin.from('passengers').select('id,status').eq('id', pid).maybeSingle();
  if (!pax) return json(404, { ok: false, error: { code: 'NOT_FOUND' } });

  const sign = async (path: string) => (await admin.storage.from(BUCKET).createSignedUrl(path, 3600)).data?.signedUrl || null;

  if (body.action === 'list') {
    const { data: rows, error } = await admin.from('airvalet_car_photos').select('id,angle,taken_at,path')
      .eq('passenger_id', pid).order('taken_at', { ascending: false }).limit(20);
    if (error) return json(500, { ok: false, error: { code: 'LOOKUP_FAILED' } });
    const photos = await Promise.all((rows || []).map(async (r) => ({ id: r.id, angle: r.angle, taken_at: r.taken_at, url: await sign(r.path) })));
    return json(200, { ok: true, photos });
  }

  if (body.action === 'add') {
    const angle = String(body.angle || '');
    const b64 = typeof body.b64 === 'string' ? body.b64 : '';
    if (angle !== 'front' && angle !== 'rear') return json(400, { ok: false, error: { code: 'BAD_ANGLE' } });
    if (!b64.startsWith('/9j/') || b64.length > MAX_B64) return json(400, { ok: false, error: { code: 'BAD_IMAGE' } });
    if (pax.status === 'ARCHIVED') return json(409, { ok: false, error: { code: 'NOT_ACTIVE' } });
    const bytes = b64ToBytes(b64);
    const path = `${pid}/${angle}-${crypto.randomUUID()}.jpg`;
    const { error: upErr } = await admin.storage.from(BUCKET).upload(path, bytes, { contentType: 'image/jpeg', upsert: false });
    if (upErr) return json(500, { ok: false, error: { code: 'UPLOAD_FAILED' } });
    const deleteAfter = pax.status === 'DELIVERED' ? new Date(Date.now() + 30 * 864e5).toISOString() : null;
    const { data: row, error: insErr } = await admin.from('airvalet_car_photos')
      .insert({ passenger_id: pid, angle, path, bytes: bytes.length, sha256: await sha256Hex(bytes), taken_by: u.user.id, delete_after: deleteAfter })
      .select('id,angle,taken_at').single();
    if (insErr) { await admin.storage.from(BUCKET).remove([path]); return json(500, { ok: false, error: { code: 'SAVE_FAILED' } }); }
    return json(200, { ok: true, photo: { ...row, url: await sign(path) } });
  }

  return json(400, { ok: false, error: { code: 'BAD_ACTION' } });
});
