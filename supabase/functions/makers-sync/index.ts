// makers-sync — the Makers robot (owner 2026-11-06). 3 PM (tomorrow) and 7 AM (today) by pg_cron, and on demand
// ("Update from Makers" in the app) it logs in to Makers Air Suite and READS:
//   • tomorrow's flights landing at FXE and their passengers → matched with the cars we hold
//     (early returns, guests with no flight, tail + FXE arrival time to fill, name typos);
//   • the return date Makers has for every Makers car we hold → dates that differ / no return booked;
//   • tomorrow's departures from FXE (times, passenger counts).
// READ-ONLY by owner rule: only the search reports (see _shared/makers/suite.ts); it never edits
// anything in Makers, and keeps no documents, birth dates or contact data. Nothing is written to
// passengers here: staff confirm each change in the app. The result is saved in
// airvalet_manifest_scans (usage.mode = 'makers_sync') and, on the scheduled runs, one push goes to
// the phones with the "Summaries" reminders on.
//
// Auth: X-Makers-Sync-Secret (pg_cron, constant-time) or a staff JWT with an ops role.
// Env: MAKERS_SUITE_USER / MAKERS_SUITE_PASSWORD (set by the owner), MAKERS_SYNC_SECRET,
//      VAPID (push), SUPABASE_URL / SUPABASE_ANON_KEY / SUPABASE_SERVICE_ROLE_KEY.
// If Makers refuses the login (password changed), the run says so and the push tells the owner.

import { createClient } from 'npm:@supabase/supabase-js@2';
import { MakersSuite, MakersSuiteError } from '../_shared/makers/suite.ts';
import { HeldCar, runSync, SyncResult } from '../_shared/makers/sync.ts';
import { Feedback, parseDate } from '../_shared/manifest/match.ts';
import { notifyCategory } from '../_shared/notify/staff.ts';
import { readVapid } from '../_shared/notify/runtime.ts';

const ALLOWED_ORIGINS = ['https://airvalet.farberos.com', 'https://matheusferian.github.io'];
const OPS = ['ADMIN', 'MANAGER', 'IPAD_OPS', 'IPHONE_OPS'];

function cors(origin: string | null): Record<string, string> {
  return {
    'Access-Control-Allow-Origin': origin && ALLOWED_ORIGINS.includes(origin) ? origin : ALLOWED_ORIGINS[0],
    'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, prefer',
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    Vary: 'Origin',
  };
}
function timingSafeEqual(a: string, b: string): boolean {
  if (!a || a.length !== b.length) return false;
  let d = 0; for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}
// Business day in Fort Lauderdale.
function etDay(offset = 0): string {
  const d = new Date(Date.now() + offset * 864e5);
  return new Intl.DateTimeFormat('en-CA', { timeZone: 'America/New_York', year: 'numeric', month: '2-digit', day: '2-digit' }).format(d);
}
const dayLabel = (iso: string) => new Date(iso + 'T12:00:00Z').toLocaleDateString('en-US', { weekday: 'short', month: 'numeric', day: 'numeric', timeZone: 'UTC' });

export function summaryText(r: SyncResult): string {
  const pax = (l: { pax: number }[]) => l.reduce((a, f) => a + f.pax, 0);
  const parts = [`In: ${r.inbound.length} flights (${pax(r.inbound)} pax)`, `Out: ${r.outbound.length} flights (${pax(r.outbound)} pax)`];
  const ours = r.match.matches.filter((m) => m.kind !== 'surname_only' && m.state !== 'delivered').length;
  const early = r.match.matches.filter((m) => m.kind !== 'surname_only' && (m.state === 'early' || m.state === 'late' || m.state === 'no_date')).length;
  const todo = [early && `${early} on a different day`, r.match.missing.length && `${r.match.missing.length} with no flight`,
    r.date_diffs.length && `${r.date_diffs.length} return date changed`].filter(Boolean);
  return `${parts.join(' · ')}. Ours: ${ours}.` + (todo.length ? ` Check: ${todo.join(', ')}.` : ' Nothing to check.');
}

Deno.serve(async (req) => {
  const headers = { ...cors(req.headers.get('origin')), 'Content-Type': 'application/json', 'Cache-Control': 'no-store' };
  const json = (status: number, body: unknown) => new Response(JSON.stringify(body), { status, headers });
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers });
  if (req.method !== 'POST') return json(405, { ok: false, error: { code: 'METHOD' } });

  const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
  const admin = createClient(SUPABASE_URL, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false, autoRefreshToken: false } });
  const isCron = timingSafeEqual(req.headers.get('X-Makers-Sync-Secret') ?? '', Deno.env.get('MAKERS_SYNC_SECRET') ?? '');
  let userId: string | null = null;
  if (!isCron) {
    const authHeader = req.headers.get('Authorization') || '';
    if (!authHeader.startsWith('Bearer ')) return json(401, { ok: false, error: { code: 'UNAUTHENTICATED' } });
    const caller = createClient(SUPABASE_URL, Deno.env.get('SUPABASE_ANON_KEY')!, { global: { headers: { Authorization: authHeader } }, auth: { persistSession: false } });
    const [{ data: u }, { data: role, error: roleErr }] = await Promise.all([caller.auth.getUser(), caller.rpc('current_user_role')]);
    if (roleErr || !u?.user) return json(401, { ok: false, error: { code: 'UNAUTHENTICATED' } });
    if (!OPS.includes(String(role))) return json(403, { ok: false, error: { code: 'FORBIDDEN' } });
    userId = u.user.id;
    // One manual run at a time per minute: Makers is not ours to hammer.
    const { count } = await admin.from('airvalet_manifest_scans').select('id', { count: 'exact', head: true })
      .eq('usage->>mode', 'makers_sync').gte('created_at', new Date(Date.now() - 60_000).toISOString());
    if ((count || 0) > 0) return json(200, { ok: false, error: { code: 'TOO_SOON' } });
  }

  // Owner schedule: 3 PM Fort Lauderdale → check TOMORROW; 7 AM → re-check TODAY. pg_cron (UTC) fires
  // at 11/12 and 19/20 UTC; only the run that is 7 AM or 3 PM in America/New_York (EDT or EST) works.
  let target = etDay(1);
  if (isCron) {
    const h = +new Intl.DateTimeFormat('en-US', { timeZone: 'America/New_York', hour: 'numeric', hour12: false }).format(new Date());
    if (h === 7) target = etDay(0);
    else if (h !== 15) return json(200, { ok: true, skipped: 'not 7 AM or 3 PM in Fort Lauderdale' });
  } else {
    let body: Record<string, unknown> = {};
    try { body = await req.json(); } catch { body = {}; }
    if (body.day === 'today') target = etDay(0);
  }
  const user = Deno.env.get('MAKERS_SUITE_USER'), pass = Deno.env.get('MAKERS_SUITE_PASSWORD');
  if (!user || !pass) return json(200, { ok: false, error: { code: 'NOT_CONFIGURED' } });
  const date = target, today = etDay(0);
  const vapid = readVapid((k) => Deno.env.get(k));
  const deps = { db: admin, vapid, log: (event: string, data: Record<string, unknown>) => console.log(JSON.stringify({ event, ...data })) };
  const t0 = Date.now();

  let result: SyncResult;
  try {
    const suite = new MakersSuite();
    await suite.login(user, pass);
    const [{ data: cars, error: cErr }, { data: fb, error: fErr }] = await Promise.all([
      admin.from('passengers').select('id,ticket,name,ret,status,deldate,return_flight,departure_time,return_operator,ts,archived_at').eq('status', 'PENDING').limit(2000),
      admin.from('airvalet_manifest_feedback').select('manifest_name,system_name,verdict').limit(5000),
    ]);
    if (cErr || fErr) return json(500, { ok: false, error: { code: 'LOOKUP_FAILED' } });
    const pool: HeldCar[] = (cars || []).filter((c) => !c.archived_at).map((c) => ({ ...c, checkin: parseDate(String(c.ts || '').split(',')[0]) }));
    result = await runSync(suite, { date, today, pool, feedback: (fb || []) as Feedback[] });
  } catch (e) {
    const code = e instanceof MakersSuiteError ? e.code : 'READ_FAILED';
    console.log(JSON.stringify({ event: 'makers_sync.error', code, msg: (e as Error).message }));
    await admin.from('airvalet_manifest_scans').insert({ created_by: userId, service_date: date, result: { error: code }, usage: { mode: 'makers_sync', ok: false, cron: isCron } });
    if (isCron) {
      await notifyCategory(deps, 'DAILY', { title: 'Makers robot could not read the flights',
        body: code === 'LOGIN_FAILED' ? 'Makers Air Suite did not accept the login. Did the password change? Tell Matheus.' : 'Makers Air Suite did not answer as expected. Check the list by hand today.',
        url: '/?mf=1', tag: 'makers-sync-error' });
    }
    return json(200, { ok: false, error: { code } });
  }

  const m = result.match;
  const surprises = m.matches.filter((x) => x.state === 'early' || x.state === 'late' || x.state === 'no_date').length + result.date_diffs.length;
  const saved = {
    date: result.date, inbound: result.inbound, outbound: result.outbound, matches: m.matches, missing: m.missing,
    date_diffs: result.date_diffs, no_return: result.no_return, not_found_list: result.not_found_list, checked: result.checked, not_found: result.not_found, warnings: result.warnings,
  };
  await admin.from('airvalet_manifest_scans').insert({
    created_by: userId, service_date: date, pages: result.inbound.length, manifest_rows: m.manifest_rows, matched: m.matches.length,
    surprises, missing: m.missing.length, result: saved, usage: { mode: 'makers_sync', ok: true, cron: isCron, secs: Math.round((Date.now() - t0) / 1000) },
  });
  if (isCron) {
    await notifyCategory(deps, 'DAILY', { title: `Makers · ${date === today ? 'today' : 'tomorrow'} ${dayLabel(date)}`, body: summaryText(result), url: '/?mf=1', tag: `makers-sync-${date}` });
  }
  return json(200, { ok: true, created_at: new Date().toISOString(), ...saved });
});
