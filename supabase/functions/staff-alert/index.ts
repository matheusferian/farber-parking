// staff-alert — called by the database (triggers airvalet_staff_alert_*, via
// pg_net) for a new check-in or a Stripe tip; sends the push to the phones
// that turned that alert on. See _shared/notify/staff.ts.
//
// Auth: X-Staff-Alert-Secret header (constant-time) checked before anything
// else, plus the platform JWT (verify_jwt) the trigger sends.
// Body: { kind: 'CHECK_IN' | 'TIP', id } (database triggers) or { kind: 'REMINDERS' } (pg_cron, every minute).
// Env: STAFF_ALERT_SECRET, AIRVALET_VAPID_PRIVATE_JWK / AIRVALET_VAPID_PUBLIC /
//      AIRVALET_VAPID_SUBJECT, SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY (platform).
// Answers 200 once authorized: an alert problem is never retried into a flood.

import { createClient } from 'npm:@supabase/supabase-js@2';
import { notifyReminders, notifyStaff, type StaffDeps } from '../_shared/notify/staff.ts';
import { readVapid } from '../_shared/notify/runtime.ts';

function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' } });
}

export async function handle(req: Request, get: (k: string) => string | undefined = (k) => Deno.env.get(k),
  makeDeps?: () => StaffDeps): Promise<Response> {
  if (req.method !== 'POST') return json(405, { error: 'method' });
  const expected = get('STAFF_ALERT_SECRET');
  if (!expected) return json(500, { error: 'secret_not_configured' });
  const provided = req.headers.get('X-Staff-Alert-Secret') ?? '';
  if (!timingSafeEqual(provided, expected)) return json(401, { error: 'unauthorized' });

  let kind = '', id = 0;
  try { const b = await req.json(); kind = String(b?.kind || ''); id = Number(b?.id ?? 0); } catch { return json(400, { error: 'bad_json' }); }

  const deps = makeDeps ? makeDeps() : {
    db: createClient(get('SUPABASE_URL')!, get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false, autoRefreshToken: false } }),
    vapid: readVapid(get),
    log: (event: string, data: Record<string, unknown>) => console.log(JSON.stringify({ event, ...data })),
  };
  if (kind === 'REMINDERS') return json(200, await notifyReminders(deps));
  return json(200, await notifyStaff(deps, kind, id));
}

if (import.meta.main) {
  Deno.serve((req) => handle(req).catch((err) => {
    console.error('staff-alert: unexpected error:', (err as Error).message);
    return json(500, { error: 'server_error' });
  }));
}
