// spider-sync (owner 2026-11-06): every minute (pg_cron 'spider-sync', 5:30 AM – 9 PM Fort Lauderdale)
// read the Makers Air fleet positions from Spidertracks (READ-ONLY) into airvalet_spider_state for the TV.
// Auth: cron header X-Spider-Sync-Secret (its OWN secret since 2026-11-06, never the Makers robot one) or an ops JWT.
// Login: the owner's Spidertracks user (SPIDER_USER / SPIDER_PASS secrets, set by the owner) through the
// web app's own Cognito pool; the refresh token is kept in airvalet_spider_session (service role only),
// so the robot signs in with the password only when the refresh token is gone.
// A wrong/changed password pushes ONE alert a day to the DAILY phones ("tell Matheus").

import { createClient } from 'npm:@supabase/supabase-js@2';
import { loginPassword, loginRefresh, parseTracks, SpiderAuthError, TRACKS_URL } from '../_shared/spider/spider.ts';
import { notifyCategory } from '../_shared/notify/staff.ts';
import { readVapid } from '../_shared/notify/runtime.ts';

const OPS = ['ADMIN', 'MANAGER', 'IPAD_OPS', 'IPHONE_OPS'];
const ROBOT_OWNERS = ['matheusferian@airvalet.local'];   // the only login that may run this robot by hand
function timingSafeEqual(a: string, b: string): boolean {
  if (!a || !b || a.length !== b.length) return false;
  let r = 0; for (let i = 0; i < a.length; i++) r |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return r === 0;
}
const json = (status: number, body: unknown) => new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' } });
const etNow = () => {
  const p = Object.fromEntries(new Intl.DateTimeFormat('en-US', { timeZone: 'America/New_York', hour: 'numeric', minute: 'numeric', hour12: false, year: 'numeric', month: '2-digit', day: '2-digit' })
    .formatToParts(new Date()).map((x) => [x.type, x.value]));
  return { min: (+p.hour % 24) * 60 + +p.minute, day: `${p.year}-${p.month}-${p.day}` };
};

// ── Plane pushes (owner 2026-11-06: "5 min before it lands, a push I can see on my watch; and when it
// leaves Customs"). For today's Makers legs that carry a guest whose car we still hold: LANDING_SOON
// (about 5 min out), LANDED (first stop at FXE = Customs), LEFT_CUSTOMS (tracker on again near FXE = taxi
// to Hangar 19). One push per leg and event (airvalet_spider_events), to the DAILY phones.
type Pos = { registration: string; last_at: string; departed_at: string | null; dist_fxe_nm: number; speed_kt: number | null; track_status: string | null; inbound: boolean; prev_dist_fxe_nm: number | null };
function etMs(day: string, hhmm: string): number | null {
  const m = /^(\d{1,2}):(\d{2})/.exec(hhmm || ''); if (!m) return null;
  const guess = Date.parse(`${day}T${m[1].padStart(2, '0')}:${m[2]}:00Z`);
  const p = Object.fromEntries(new Intl.DateTimeFormat('en-US', { timeZone: 'America/New_York', hour12: false, year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit' })
    .formatToParts(new Date(guess)).map((x) => [x.type, x.value]));
  const asEt = Date.UTC(+p.year, +p.month - 1, +p.day, +p.hour % 24, +p.minute);
  return guess - (asEt - guess);
}
const t12 = (hhmm: string) => { const m = /^(\d{1,2}):(\d{2})/.exec(hhmm || ''); if (!m) return hhmm; const h = +m[1]; return `${((h + 11) % 12) + 1}:${m[2]} ${h < 12 ? 'AM' : 'PM'}`; };
const PLACE: Record<string, string> = { ASD: 'Fresh Creek', COX: 'Congo Town', GHC: 'Great Harbor Cay', GHB: "Governor's Harbour", ATC: "Arthur's Town", SAQ: 'San Andros',
  TYM: 'Staniel Cay', ELH: 'North Eleuthera', TBI: 'Cat Island', RSD: 'Rock Sound', CCZ: 'Chub Cay', SML: 'Long Island', MHH: 'Marsh Harbour', NAS: 'Nassau', BIM: 'Bimini' };
// deno-lint-ignore no-explicit-any
async function planeEvents(admin: any, positions: Pos[], day: string): Promise<string[]> {
  const { data: scan } = await admin.from('airvalet_manifest_scans').select('result').eq('service_date', day)
    .eq('usage->>mode', 'makers_sync').eq('usage->>ok', 'true').order('created_at', { ascending: false }).limit(1).maybeSingle();
  const res = scan?.result; if (!res) return [];
  const matches = ((res.matches || []) as { passenger_id: number; flight_number: string; route: string; registration: string; arrival_time: string; kind: string }[])
    .filter((x) => x.kind !== 'surname_only' && x.registration);
  const inbound = (res.inbound || []) as { flight: string; tail: string; time: string; dep?: string; route?: string; pax?: number }[];
  const { data: cars } = await admin.from('passengers').select('id,name,car,loc,status').in('id', [...new Set(matches.map((x) => x.passenger_id))]);
  const held = new Map(((cars || []) as { id: number; name: string; car: string; loc: string; status: string }[]).filter((c) => c.status === 'PENDING').map((c) => [c.id, c]));
  const legs = new Map<string, { flight: string; reg: string; route: string; arr: string; pax: number; guests: { name: string; car: string; loc: string }[] }>();
  for (const x of matches) {
    const c = held.get(x.passenger_id); if (!c) continue;
    const k = `${x.flight_number}|${String(x.registration).toUpperCase()}`;
    if (!legs.has(k)) legs.set(k, { flight: x.flight_number, reg: String(x.registration).toUpperCase(), route: x.route, arr: x.arrival_time, pax: 0, guests: [] });
    legs.get(k)!.guests.push({ name: c.name, car: c.car, loc: c.loc });
  }
  // Owner 2026-11-06 (WM): Makers flights with passengers but none of our cars get the same three pushes,
  // marked "No cars · N pax".
  for (const f of inbound) {
    const reg = String(f.tail || '').toUpperCase(), k = `${f.flight}|${reg}`;
    if (!reg || legs.has(k) || !(Number(f.pax) > 0)) continue;
    legs.set(k, { flight: String(f.flight), reg, route: String(f.route || ''), arr: f.time, pax: Number(f.pax), guests: [] });
  }
  if (!legs.size) return [];
  const closest = (reg: string, flight: string, ref: number) => {
    let best: { d: number; flight: string } | null = null;
    for (const f of inbound) {
      if (String(f.tail).toUpperCase() !== reg) continue;
      const a = etMs(day, f.time); if (a == null) continue;
      const d = Math.abs(a - ref); if (!best || d < best.d) best = { d, flight: String(f.flight) };
    }
    return !best || best.flight === String(flight);
  };
  const vapid = readVapid((k) => Deno.env.get(k));
  const deps = { db: admin, vapid, log: () => {} };
  const sent: string[] = [];
  const once = async (legKey: string, event: string) => {
    const { data, error } = await admin.from('airvalet_spider_events').upsert({ service_date: day, leg_key: legKey, event }, { onConflict: 'service_date,leg_key,event', ignoreDuplicates: true }).select('event');
    return !error && Array.isArray(data) && data.length > 0;
  };
  const now = Date.now();
  for (const [k, L] of legs) {
    const sp = positions.find((p) => p.registration === L.reg); if (!sp) continue;
    const arr = etMs(day, L.arr), last = Date.parse(sp.last_at), dist = Number(sp.dist_fxe_nm), kt = Number(sp.speed_kt) || 0;
    if (!arr || now - last > 15 * 60000) continue;
    const dep = etMs(day, (inbound.find((f) => String(f.flight) === String(L.flight)) || {}).dep || '');
    const code = String(L.route || '').split('-')[0], from = PLACE[code] || code, tail = L.reg.replace(/^N\d*/, '');
    const who = L.guests.length ? L.guests.map((g) => `${g.name} (${[g.car, g.loc].filter(Boolean).join(', ')})`).join(' · ') : `No cars · ${L.pax} pax`;
    const inWin = (ms: number) => ms - arr > -120 * 60000 && ms - arr < 360 * 60000;
    const closing = sp.prev_dist_fxe_nm != null ? Number(sp.prev_dist_fxe_nm) > dist + 0.2 : sp.inbound;
    if (kt >= 40 && dist > 1 && (sp.inbound || closing)) {
      const eta = dist / kt * 60;
      if (eta <= 6 && inWin(now + eta * 60000) && closest(L.reg, L.flight, now + eta * 60000) && await once(k, 'LANDING_SOON')) {
        await notifyCategory(deps, 'DAILY', { title: `${tail} landing in ~${Math.max(1, Math.round(eta))} min`, body: `${from} → FXE · flight ${L.flight}\n${who}`, url: '/', tag: `plane-${k}-soon` });
        sent.push(`${k}:LANDING_SOON`);
      }
    }
    // Shut down at FXE (the Caravan powers off at Customs) — a slow taxi with the tracker on is not a landing push.
    // The shutdown must end a real flight (track > 20 min): the short Customs → Hangar 19 hop is not a landing.
    const flew = sp.departed_at ? last - Date.parse(sp.departed_at) > 20 * 60000 : true;
    const stopped = dist <= 3 && sp.track_status === 'POWER_OFF' && flew && (!dep || last >= dep - 10 * 60000);
    if (stopped && inWin(last) && closest(L.reg, L.flight, last) && await once(k, 'LANDED')) {
      await notifyCategory(deps, 'DAILY', { title: `${tail} landed · at Customs`, body: `${from} → FXE · flight ${L.flight}\n${who}`, url: '/', tag: `plane-${k}-landed` });
      sent.push(`${k}:LANDED`);
    }
    if (dist <= 3 && sp.track_status !== 'POWER_OFF' && kt < 40) {
      const { data: landed } = await admin.from('airvalet_spider_events').select('at').eq('service_date', day).eq('leg_key', k).eq('event', 'LANDED').maybeSingle();
      // A NEW track (tracker switched on again) that started after the Customs shutdown = taxi to Hangar 19.
      const onAgain = sp.departed_at ? Date.parse(sp.departed_at) > (landed ? Date.parse(landed.at) - 5 * 60000 : Infinity) : false;
      // Owner 2026-11-07: only within 1 h of the landing — a tracker switched on hours later is a parked plane
      // (or the next departure), not the Customs → Hangar 19 hop.
      const recent = landed && last - Date.parse(landed.at) <= 60 * 60000;
      if (landed && onAgain && recent && last > Date.parse(landed.at) && await once(k, 'LEFT_CUSTOMS')) {
        await notifyCategory(deps, 'DAILY', { title: `${tail} left Customs → Hangar 19`, body: `Flight ${L.flight} from ${from}\n${who}`, url: '/', tag: `plane-${k}-h19` });
        sent.push(`${k}:LEFT_CUSTOMS`);
      }
    }
  }
  return sent;
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return json(405, { ok: false, error: { code: 'METHOD' } });
  const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
  const admin = createClient(SUPABASE_URL, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false, autoRefreshToken: false } });
  const isCron = timingSafeEqual(req.headers.get('X-Spider-Sync-Secret') ?? '', Deno.env.get('SPIDER_SYNC_SECRET') ?? '');
  if (!isCron) {
    const authHeader = req.headers.get('Authorization') || '';
    const caller = createClient(SUPABASE_URL, Deno.env.get('SUPABASE_ANON_KEY')!, { global: { headers: { Authorization: authHeader } }, auth: { persistSession: false } });
    const [{ data: u }, { data: role }] = await Promise.all([caller.auth.getUser(), caller.rpc('current_user_role')]);
    // Owner 2026-11-06: only the owner's own login runs the robot by hand.
    if (!u?.user || String(role) !== 'ADMIN' || !ROBOT_OWNERS.includes(String(u.user.email || '').toLowerCase())) return json(403, { ok: false, error: { code: 'FORBIDDEN' } });
  }
  const now = etNow();
  if (isCron && (now.min < 5 * 60 + 30 || now.min > 21 * 60)) return json(200, { ok: true, skipped: 'night' });
  const user = Deno.env.get('SPIDER_USER'), pass = Deno.env.get('SPIDER_PASS');
  if (!user || !pass) return json(200, { ok: false, error: { code: 'NOT_CONFIGURED' } });

  const { data: sess } = await admin.from('airvalet_spider_session').select('*').eq('id', 1).maybeSingle();
  const saveSession = (patch: Record<string, unknown>) => admin.from('airvalet_spider_session').upsert({ id: 1, ...patch });

  // 1. A valid id token: cached → refresh token → password.
  let idToken: string | null = sess?.id_token && sess?.id_expires_at && Date.parse(sess.id_expires_at) - Date.now() > 120_000 ? sess.id_token : null;
  try {
    if (!idToken && sess?.refresh_token) {
      try { const a = await loginRefresh(sess.refresh_token); idToken = a.idToken; await saveSession({ id_token: a.idToken, id_expires_at: new Date(Date.now() + a.expiresIn * 1000).toISOString() }); }
      catch { idToken = null; }   // refresh token expired/revoked: fall back to the password
    }
    if (!idToken) {
      const a = await loginPassword(user, pass);
      idToken = a.idToken;
      await saveSession({ id_token: a.idToken, refresh_token: a.refreshToken, id_expires_at: new Date(Date.now() + a.expiresIn * 1000).toISOString() });
    }
  } catch (e) {
    const code = e instanceof SpiderAuthError ? e.code : 'AUTH_FAILED';
    await saveSession({ last_error: code, last_error_at: new Date().toISOString(), id_token: null });
    if (code === 'NotAuthorizedException' && sess?.alerted_on !== now.day) {
      await saveSession({ alerted_on: now.day });
      await notifyCategory({ db: admin, vapid: readVapid((k) => Deno.env.get(k)), log: () => {} }, 'DAILY', {
        title: 'Spidertracks robot could not sign in', body: 'Did the Spidertracks password change? Tell Matheus. The TV uses the public radar meanwhile.', url: '/', tag: 'spider-auth' });
    }
    return json(200, { ok: false, error: { code } });
  }

  // 2. Fleet positions (read-only).
  let res = await fetch(TRACKS_URL, { headers: { Authorization: 'Bearer ' + idToken } });
  if (res.status === 401) {   // token revoked early: one fresh sign-in, then give up until the next minute
    try { const a = await loginPassword(user, pass); idToken = a.idToken; await saveSession({ id_token: a.idToken, refresh_token: a.refreshToken, id_expires_at: new Date(Date.now() + a.expiresIn * 1000).toISOString() }); }
    catch { return json(200, { ok: false, error: { code: 'AUTH_FAILED' } }); }
    res = await fetch(TRACKS_URL, { headers: { Authorization: 'Bearer ' + idToken } });
  }
  if (!res.ok) { await saveSession({ last_error: 'HTTP_' + res.status, last_error_at: new Date().toISOString() }); return json(200, { ok: false, error: { code: 'HTTP', status: res.status } }); }
  let positions;
  try { positions = parseTracks(await res.json()); }
  catch { await saveSession({ last_error: 'LAYOUT', last_error_at: new Date().toISOString() }); return json(200, { ok: false, error: { code: 'LAYOUT' } }); }

  // 3. Store, keeping the previous distance to FXE (closing in or going away).
  const { data: prev } = await admin.from('airvalet_spider_state').select('registration,dist_fxe_nm,prev_dist_fxe_nm,last_at');
  const prevBy = new Map((prev || []).map((p) => [p.registration, p]));
  const rows = positions.map((p) => {
    const old = prevBy.get(p.registration);
    const moved = old && old.last_at && Date.parse(old.last_at) < Date.parse(p.last_at);
    return { ...p, prev_dist_fxe_nm: moved ? old!.dist_fxe_nm : (old as { prev_dist_fxe_nm?: number } | undefined)?.prev_dist_fxe_nm ?? null, polled_at: new Date().toISOString() };
  });
  if (rows.length) { const { error } = await admin.from('airvalet_spider_state').upsert(rows); if (error) return json(500, { ok: false, error: { code: 'DB' } }); }
  await saveSession({ last_ok_at: new Date().toISOString(), last_error: null });
  let events: string[] = [];
  try { events = await planeEvents(admin, rows, now.day); } catch (e) { console.log(JSON.stringify({ event: 'spider.events_error', msg: String((e as Error)?.message || e) })); }
  return json(200, { ok: true, events, aircraft: rows.map((r) => ({ reg: r.registration, status: r.track_status, nm: r.dist_fxe_nm, kt: r.speed_kt, inbound: r.inbound })) });
});
