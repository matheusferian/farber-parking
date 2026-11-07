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
// If Makers refuses the login (password changed), the run says so and the push tells the owner; the
// scheduled runs then STOP trying (no account lock-out) until a staff member runs "Update from Makers".
// Security rules and what is kept: makers-sync/SECURITY.md.

import { createClient } from 'npm:@supabase/supabase-js@2';
import { MakersSuite, MakersSuiteError } from '../_shared/makers/suite.ts';
import { HeldCar, runSync, SyncResult } from '../_shared/makers/sync.ts';
import { Feedback, parseDate } from '../_shared/manifest/match.ts';
import { notifyCategory } from '../_shared/notify/staff.ts';
import { changeLine, diffDepartures, KEY_VERSION, type DepChange, type DepFlight } from '../_shared/makers/changes.ts';
import { readVapid } from '../_shared/notify/runtime.ts';

const ALLOWED_ORIGINS = ['https://airvalet.farberos.com', 'https://matheusferian.github.io'];
const OPS = ['ADMIN', 'MANAGER', 'IPAD_OPS', 'IPHONE_OPS'];
const ROBOT_OWNERS = ['matheusferian@airvalet.local'];   // the only login that may run this robot by hand

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
    // Owner 2026-11-06: "não deixe qualquer um acessar o robô — somente eu". Only the owner's own login
    // (ADMIN) can run it by hand; everyone else gets FORBIDDEN. The schedule uses the robot secret.
    if (String(role) !== 'ADMIN' || !ROBOT_OWNERS.includes(String(u.user.email || '').toLowerCase())) return json(403, { ok: false, error: { code: 'FORBIDDEN' } });
    userId = u.user.id;
    // One manual run at a time per minute: Makers is not ours to hammer.
    const { count } = await admin.from('airvalet_manifest_scans').select('id', { count: 'exact', head: true })
      .eq('usage->>mode', 'makers_sync').gte('created_at', new Date(Date.now() - 60_000).toISOString());
    if ((count || 0) > 0) return json(200, { ok: false, error: { code: 'TOO_SOON' } });
  }

  // Owner schedule: 3 PM Fort Lauderdale → check TOMORROW; 6 AM → re-check TODAY (owner 2026-11-06: the
  // Makers office is open by 6 AM, last changes are in). pg_cron (UTC) fires at 10/11 and 19/20 UTC; only
  // the run that is 6 AM or 3 PM in America/New_York (EDT or EST) works.
  // Owner 2026-11-06: also 11 AM (today), 7 PM and 11 PM (tomorrow) to catch changes sooner; those only push
  // when something changed (the daily summary stays at 6 AM / 3 PM).
  let target = etDay(1), summaryRun = !isCron, noShowRun = false;
  let cronBody: Record<string, unknown> = {};
  if (isCron) { try { cronBody = await req.clone().json(); } catch { cronBody = {}; } }
  if (isCron && (cronBody.day === 'today' || cronBody.day === 'tomorrow')) {
    // An on-demand run with the robot secret (owner 2026-11-06: tomorrow's names now): that day, no summary push.
    target = cronBody.day === 'today' ? etDay(0) : etDay(1);
  } else if (isCron) {
    const h = +new Intl.DateTimeFormat('en-US', { timeZone: 'America/New_York', hour: 'numeric', hour12: false }).format(new Date());
    // 4:30 PM (cron 'makers-sync-1630'): today again, before the last flights leave the islands — no-show check.
    if (h === 6 || h === 11 || h === 16) { target = etDay(0); noShowRun = h === 16; }
    else if (h !== 15 && h !== 19 && h !== 23) return json(200, { ok: true, skipped: 'not 6 AM, 11 AM, 3 PM, 4:30 PM, 7 PM or 11 PM in Fort Lauderdale' });
    summaryRun = h === 6 || h === 15;
  } else {
    let body: Record<string, unknown> = {};
    try { body = await req.json(); } catch { body = {}; }
    if (body.day === 'today') target = etDay(0);
  }
  const user = Deno.env.get('MAKERS_SUITE_USER'), pass = Deno.env.get('MAKERS_SUITE_PASSWORD');
  if (!user || !pass) return json(200, { ok: false, error: { code: 'NOT_CONFIGURED' } });
  // An on-demand run with the robot secret follows the same once-a-minute rule as the app button.
  if (isCron && cronBody.day) {
    const { count } = await admin.from('airvalet_manifest_scans').select('id', { count: 'exact', head: true })
      .eq('usage->>mode', 'makers_sync').gte('created_at', new Date(Date.now() - 60_000).toISOString());
    if ((count || 0) > 0) return json(200, { ok: false, error: { code: 'TOO_SOON' } });
  }
  // Last reading refused the login (password changed?): the schedule stops trying so the Makers account is
  // never locked by repeated failures. A staff "Update from Makers" tries again (after the owner fixes it).
  if (isCron) {
    const { data: last } = await admin.from('airvalet_manifest_scans').select('result,usage').eq('usage->>mode', 'makers_sync')
      .order('created_at', { ascending: false }).limit(1).maybeSingle();
    const stopCode = last && last.usage?.ok === false ? String(last.result?.error || '') : '';
    if (['LOGIN_FAILED', 'LAYOUT', 'BLOCKED'].includes(stopCode)) return json(200, { ok: false, error: { code: 'STOPPED_' + stopCode } });
  }
  // One run at a time (cron, app button and on-demand), even when two start together.
  const { data: locked } = await admin.rpc('airvalet_robot_lock', { p_name: 'makers-sync', p_secs: 150 });
  if (locked !== true) return json(200, { ok: false, error: { code: 'BUSY' } });
  const unlock = () => admin.rpc('airvalet_robot_unlock', { p_name: 'makers-sync' });
  const date = target, today = etDay(0);
  const vapid = readVapid((k) => Deno.env.get(k));
  const deps = { db: admin, vapid, log: (event: string, data: Record<string, unknown>) => console.log(JSON.stringify({ event, ...data })) };
  const t0 = Date.now();

  let result: SyncResult;
  let noDateIds = new Set<number>();   // Return Date Follow-Up guests (status NO DATE)
  try {
    const suite = new MakersSuite();
    await suite.login(user, pass);
    const [{ data: cars, error: cErr }, { data: fb, error: fErr }] = await Promise.all([
      admin.from('passengers').select('id,ticket,name,ret,status,deldate,return_flight,departure_time,return_operator,ts,archived_at').in('status', ['PENDING', 'NO DATE']).limit(2000),
      admin.from('airvalet_manifest_feedback').select('manifest_name,system_name,verdict').limit(5000),
    ]);
    if (cErr || fErr) { await unlock(); return json(500, { ok: false, error: { code: 'LOOKUP_FAILED' } }); }
    const pool: HeldCar[] = (cars || []).filter((c) => !c.archived_at).map((c) => ({ ...c, checkin: parseDate(String(c.ts || '').split(',')[0]) }));
    noDateIds = new Set(pool.filter((c) => c.status === 'NO DATE').map((c) => c.id));
    result = await runSync(suite, { date, today, pool, feedback: (fb || []) as Feedback[], keySecret: Deno.env.get('MAKERS_SYNC_SECRET') || undefined });
  } catch (e) {
    const code = e instanceof MakersSuiteError ? e.code : 'READ_FAILED';
    console.log(JSON.stringify({ event: 'makers_sync.error', code, msg: (e as Error).message }));
    await admin.from('airvalet_manifest_scans').insert({ created_by: userId, service_date: date, result: { error: code }, usage: { mode: 'makers_sync', ok: false, cron: isCron } });
    // Owner 2026-11-06: a changed Makers page (or anything the read-only guard refused) = stop at once, change
    // nothing, tell the owner right away; the schedule stays stopped until it is fixed and a staff member runs
    // "Update from Makers" again.
    const pageChanged = code === 'LAYOUT' || code === 'BLOCKED';
    if (isCron || pageChanged || code === 'LOGIN_FAILED') {
      await notifyCategory(deps, 'DAILY', {
        title: pageChanged ? 'Makers robot STOPPED — Makers page changed' : 'Makers robot could not read the flights',
        body: code === 'LOGIN_FAILED' ? 'Makers Air Suite did not accept the login. Did the password change? Tell Matheus. The robot stopped trying.'
          : pageChanged ? 'Nothing was changed in Makers. The robot stopped and will not run again until it is fixed. Tell Matheus.'
          : 'Makers Air Suite did not answer as expected. Check the list by hand today.',
        url: '/?mf=1', tag: 'makers-sync-error' });
    }
    await unlock();
    return json(200, { ok: false, error: { code } });
  }

  const m = result.match;
  const surprises = m.matches.filter((x) => x.state === 'early' || x.state === 'late' || x.state === 'no_date').length + result.date_diffs.length;
  // Departures changed since the previous good reading of the same day (owner 2026-11-06: cancellations,
  // moves, tail/time swaps). The first reading of a day has nothing to compare with.
  const { data: prevRow } = await admin.from('airvalet_manifest_scans').select('created_at,result')
    .eq('service_date', date).eq('usage->>mode', 'makers_sync').eq('usage->>ok', 'true')
    .order('created_at', { ascending: false }).limit(1).maybeSingle();
  let changes: { since: string; items: DepChange[]; lines: string[] } | null = null;
  // Keys of another kind (before HMAC, 2026-11-06) cannot be compared: counts only for that reading.
  const prevOut = (prevRow?.result?.outbound as DepFlight[] | undefined)?.map((f) => prevRow?.result?.kv === KEY_VERSION ? f : { ...f, ids: undefined });
  // Owner 2026-11-07: key version 3 counts people only (pets excluded) — a reading of another version counts
  // differently, so it is never compared (no false "1 cancelled" for a dog).
  if (prevRow && Array.isArray(prevOut) && Number(prevRow?.result?.kv || 0) >= 3) {
    const items = diffDepartures(prevOut, result.outbound as DepFlight[]);
    changes = { since: prevRow.created_at, items, lines: items.map(changeLine) };
  }
  // No-show watch (owner 2026-11-06): only guests WITH a car here (status PENDING, return today, Makers return —
  // Ascend / other boat are not in these lists). A guest who was on a flight in the previous reading and is on
  // none now = possible no-show (cancelled or rebooked). At 4:30 PM: everyone still not on any flight today.
  type NoShow = { passenger_id: number; ticket: string; system_name: string; was_flight?: string; was_time?: string };
  let no_show: NoShow[] = [];
  let still_off: NoShow[] = [];
  if (date === today) {
    const opOk = (o: unknown) => !['ASCEND', 'OTHER'].includes(String(o || 'MAKERS').toUpperCase());
    const missing = (m.missing || []).filter((x) => opOk(x.operator));
    const prevMatches = ((prevRow?.result?.matches || []) as { passenger_id: number; flight_number: string; arrival_time: string; kind: string }[])
      .filter((x) => x.kind !== 'surname_only');
    const prevBy = new Map(prevMatches.map((x) => [x.passenger_id, x]));
    no_show = missing.filter((x) => prevBy.has(x.passenger_id))
      .map((x) => ({ passenger_id: x.passenger_id, ticket: x.ticket, system_name: x.system_name, was_flight: prevBy.get(x.passenger_id)!.flight_number, was_time: prevBy.get(x.passenger_id)!.arrival_time }));
    if (noShowRun) still_off = missing.filter((x) => !prevBy.has(x.passenger_id)).map((x) => ({ passenger_id: x.passenger_id, ticket: x.ticket, system_name: x.system_name }));
  }
  const saved = {
    kv: KEY_VERSION,
    no_show, still_off,
    changes,
    date: result.date, inbound: result.inbound, outbound: result.outbound, matches: m.matches, missing: m.missing,
    date_diffs: result.date_diffs, no_return: result.no_return, not_found_list: result.not_found_list, checked: result.checked, not_found: result.not_found, warnings: result.warnings,
    followup_seen: result.followup_seen,
  };
  await admin.from('airvalet_manifest_scans').insert({
    created_by: userId, service_date: date, pages: result.inbound.length, manifest_rows: m.manifest_rows, matched: m.matches.length,
    surprises, missing: m.missing.length, result: saved, usage: { mode: 'makers_sync', ok: true, cron: isCron, secs: Math.round((Date.now() - t0) / 1000) },
  });
  // Check-in name suggestions (owner 2026-11-06): this day's FXE departures, name only, replaced on every
  // reading; anything older than today is deleted. Never in the scan result or in this response.
  let namesSaved = 0;
  try {
    await admin.from('airvalet_makers_names').delete().lt('service_date', today);
    await admin.from('airvalet_makers_names').delete().eq('service_date', date);
    if (result.names.length) {
      const { error } = await admin.from('airvalet_makers_names').insert(result.names.map((n) => ({ service_date: date, name: n.name, flight: n.flight, dep_time: n.time, dest: n.dest })));
      if (!error) namesSaved = result.names.length;
    }
  } catch { /* suggestions are a convenience: never fail the robot */ }
  if (isCron && summaryRun) {
    await notifyCategory(deps, 'DAILY', { title: `Makers · ${date === today ? 'today' : 'tomorrow'} ${dayLabel(date)}`, body: summaryText(result), url: '/?mf=1', tag: `makers-sync-${date}` });
  }
  if (no_show.length) {
    await notifyCategory(deps, 'DAILY', { title: 'Possible no-show — car waiting',
      body: no_show.map((x) => `${x.system_name} (#${x.ticket}) is no longer on flight ${x.was_flight}${x.was_time ? ' ' + x.was_time : ''}`).join('\n') + '\nCheck with Makers before waiting.',
      url: '/?mf=1', tag: `makers-noshow-${date}` });
  }
  if (still_off.length) {
    await notifyCategory(deps, 'DAILY', { title: `Not on any Makers flight today — ${still_off.length} car${still_off.length === 1 ? '' : 's'} waiting`,
      body: still_off.slice(0, 5).map((x) => `${x.system_name} (#${x.ticket})`).join('\n') + (still_off.length > 5 ? `\n+${still_off.length - 5} more` : '') + '\nCheck before the last flights.',
      url: '/?mf=1', tag: `makers-stilloff-${date}` });
  }
  // Return Date Follow-Up guests the robot found (owner 2026-11-06): on a flight that day, or a return booked in Makers.
  const fuLines = [
    ...result.followup_seen.map((f) => `${f.system_name}: ${f.direction === 'out' ? 'flying out' : 'coming back'} ${f.route} flight ${f.flight}${f.time ? ' ' + f.time : ''}`),
    ...result.date_diffs.filter((d) => noDateIds.has(d.passenger_id)).map((d) => `${d.system_name}: return booked ${d.makers} in Makers`),
  ];
  if (fuLines.length) {
    await notifyCategory(deps, 'DAILY', { title: 'Follow-up guest found in Makers', body: fuLines.slice(0, 4).join('\n') + (fuLines.length > 4 ? `\n+${fuLines.length - 4} more` : ''),
      url: '/?mf=1', tag: `makers-followup-${date}` });
  }
  // Any run (robot or Update button) that finds departures changed tells the phones/iPad: resend the picture.
  if (changes && changes.items.length) {
    await notifyCategory(deps, 'DAILY', { title: `Makers changes · departures ${date === today ? 'today' : 'tomorrow'} ${dayLabel(date)}`,
      body: changes.lines.slice(0, 4).join('\n') + (changes.lines.length > 4 ? `\n+${changes.lines.length - 4} more` : '') + '\nOpen Makers Flights to resend the updated picture.',
      url: '/?mf=1', tag: `makers-changes-${date}` });
  }
  await unlock();
  // The scheduler's copy of the answer is kept by pg_net (net._http_response): counts only, no names.
  if (isCron) return json(200, { ok: true, date, names_saved: namesSaved, inbound: result.inbound.length, outbound: result.outbound.length,
    matches: m.matches.length, missing: m.missing.length, changes: changes ? changes.items.length : 0 });
  return json(200, { ok: true, created_at: new Date().toISOString(), names_saved: namesSaved, ...saved });
});
