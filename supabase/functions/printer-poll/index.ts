// printer-poll — Epson Server Direct Print endpoint (owner 2026-11-27: print automatically from AirValet,
// not from the owner's Mac). The thermal printer TM-m30II in the hangar asks this URL every few seconds:
//   ConnectionType=GetRequest  → we answer with the slips that are due (or nothing)
//   ConnectionType=SetResponse → the printer tells us if it printed
// 8 AM: today's cars not printed yesterday. 2 PM: tomorrow, flights landing up to 1 PM.
// Public endpoint: deploy with --no-verify-jwt; protected by the secret ?k= (PRINTER_POLL_KEY), set only in the printer.
// Owner 2026-11-27: the hangar TM-m30II has no Server Direct Print, so the KIOSK iPad asks instead
// ({action:'due'} / {action:'done'} with the staff login) and sends the slips to the printer itself.
import { createClient } from 'npm:@supabase/supabase-js@2';
import { buildSlips, dueJob, eposXml, keepFor, printRequestInfo, type Match, type Pax } from '../_shared/print/slips.ts';

const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });
const TZ = 'America/New_York';
const ALLOWED_ORIGINS = ['https://airvalet.farberos.com'];
const corsOf = (origin: string | null): Record<string, string> => ({ 'Access-Control-Allow-Origin': origin && ALLOWED_ORIGINS.includes(origin) ? origin : ALLOWED_ORIGINS[0],
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, prefer', 'Access-Control-Allow-Methods': 'POST, OPTIONS', Vary: 'Origin' });
const nothing = () => new Response('', { status: 200, headers: { 'Content-Type': 'text/xml; charset=utf-8' } });
const xml = (body: string) => new Response(body, { status: 200, headers: { 'Content-Type': 'text/xml; charset=utf-8' } });

function etParts(d = new Date()) {
  const p = Object.fromEntries(new Intl.DateTimeFormat('en-US', { timeZone: TZ, year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', weekday: 'short', hour12: false })
    .formatToParts(d).map((x) => [x.type, x.value]));
  return { date: `${p.year}-${p.month}-${p.day}`, hour: +p.hour % 24, minute: +p.minute, weekday: p.weekday };
}
const addDay = (iso: string, n: number) => { const d = new Date(iso + 'T12:00:00Z'); d.setUTCDate(d.getUTCDate() + n); return d.toISOString().slice(0, 10); };
const retOf = (iso: string) => { const [y, m, d] = iso.split('-'); return `${+m}/${+d}/${y}`; };
const dayLabel = (iso: string) => { const d = new Date(iso + 'T12:00:00Z'); return `${d.toLocaleDateString('en-US', { weekday: 'short', timeZone: 'UTC' })} ${iso.slice(5, 7)}/${iso.slice(8, 10)}`; };

function sameKey(a: string, b: string) {
  if (!a || !b || a.length !== b.length) return false;
  let r = 0; for (let i = 0; i < a.length; i++) r |= a.charCodeAt(i) ^ b.charCodeAt(i); return r === 0;
}

async function latestMatches(date: string): Promise<{ matches: Match[]; at: string | null }> {
  const { data } = await admin.from('airvalet_manifest_scans').select('created_at,result').eq('service_date', date)
    .in('usage->>mode', ['makers_sync', 'makers_watch']).eq('usage->>ok', 'true').order('created_at', { ascending: false }).limit(10);
  for (const r of data || []) { const m = r.result?.matches; if (Array.isArray(m) && m.length) return { matches: m, at: r.created_at }; }
  return { matches: [], at: null };
}

type Picked = { jobId: string; epos: string; flights: number; cars: number };
// The print that is due now, claimed for 3 minutes so no other device prints it too. null = nothing to print.
async function pick(): Promise<Picked | null> {
  const now = new Date(), et = etParts(now);
  const job = dueJob(et.date, addDay(et.date, 1), et.hour);
  if (!job) return null;
  const { data: row } = await admin.from('airvalet_print_jobs').select('*').eq('job_key', job.key).maybeSingle();
  if (row && (row.status === 'printed' || row.status === 'empty')) return null;
  if (row && (row.attempts || 0) >= 3) return null;
  if (row && row.status === 'sent' && Date.now() - new Date(row.sent_at).getTime() < 3 * 60_000) return null;
  const { matches, at } = await latestMatches(job.date);
  // 2 PM: wait for the 1:45 PM reading of tomorrow (until 3:30 PM at the latest).
  if (job.kind === 'pm') {
    const fresh = at && etParts(new Date(at)).date === et.date && etParts(new Date(at)).hour >= 13;
    if (!fresh && (et.hour < 15 || (et.hour === 15 && et.minute < 30))) return null;
  }
  let skip = new Set<number>();
  if (job.kind === 'am') {
    const { data: prev } = await admin.from('airvalet_print_jobs').select('passenger_ids').eq('job_key', `pm-${job.date}`).eq('status', 'printed').maybeSingle();
    skip = new Set((prev?.passenger_ids || []) as number[]);
  }
  const { data: pax } = await admin.from('passengers').select('id,name,return_flight,departure_time').eq('ret', retOf(job.date)).eq('status', 'PENDING');
  const slips = buildSlips(((pax || []) as Pax[]).filter((p) => !skip.has(p.id)), matches, keepFor(job.kind));
  const ids = slips.flatMap((s) => s.ids);
  const base = { job_key: job.key, kind: job.kind, service_date: job.date, updated_at: now.toISOString() };
  if (!slips.length) {
    if (!row) await admin.from('airvalet_print_jobs').upsert({ ...base, status: 'empty', passenger_ids: [] }, { onConflict: 'job_key', ignoreDuplicates: true });
    else await admin.from('airvalet_print_jobs').update({ status: 'empty', updated_at: base.updated_at }).eq('job_key', job.key).eq('attempts', row.attempts);
    return null;
  }
  const attempts = (row?.attempts || 0) + 1;
  const claim = { ...base, status: 'sent', attempts, sent_at: now.toISOString(), passenger_ids: ids, flights: slips.length };
  // Claim it (two devices asking at once: only one wins).
  const won = row
    ? (await admin.from('airvalet_print_jobs').update(claim).eq('job_key', job.key).eq('attempts', row.attempts).select('job_key')).data
    : (await admin.from('airvalet_print_jobs').upsert(claim, { onConflict: 'job_key', ignoreDuplicates: true }).select('job_key')).data;
  if (!won || !won.length) return null;
  const h12 = `${et.hour % 12 || 12}:${String(et.minute).padStart(2, '0')} ${et.hour < 12 ? 'AM' : 'PM'}`;
  const stamp = `Printed ${et.date.slice(5, 7)}/${et.date.slice(8, 10)} ${h12} - Air Valet`;
  console.log(JSON.stringify({ event: 'print_sent', job: job.key, attempts, flights: slips.length, cars: ids.length }));
  return { jobId: `${job.key}~${attempts}`, epos: eposXml(slips, dayLabel(job.date), stamp), flights: slips.length, cars: ids.length };
}

async function getRequest(): Promise<Response> {
  const p = await pick();
  return p ? xml(printRequestInfo(p.epos, p.jobId)) : nothing();
}

async function markDone(jobId: string, ok: boolean, note: string) {
  const key = String(jobId || '').split('~')[0];
  if (!/^(am|pm)-\d{4}-\d{2}-\d{2}$/.test(key)) return;
  await admin.from('airvalet_print_jobs').update({ status: ok ? 'printed' : 'failed', printed_at: ok ? new Date().toISOString() : null,
    last_result: note.slice(0, 500), updated_at: new Date().toISOString() }).eq('job_key', key);
  console.log(JSON.stringify({ event: 'print_result', job: key, ok }));
}

const OPS = ['ADMIN', 'MANAGER', 'IPAD_OPS', 'IPHONE_OPS'];
const jsonRes = (status: number, b: unknown) => new Response(JSON.stringify(b), { status, headers: { 'Content-Type': 'application/json' } });
async function appRequest(req: Request): Promise<Response> {
  const authHeader = req.headers.get('Authorization') || '';
  if (!authHeader.startsWith('Bearer ')) return jsonRes(401, { ok: false, error: { code: 'UNAUTHENTICATED' } });
  const caller = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!, { global: { headers: { Authorization: authHeader } }, auth: { persistSession: false } });
  const [{ data: u }, { data: role, error: roleErr }] = await Promise.all([caller.auth.getUser(), caller.rpc('current_user_role')]);
  if (roleErr || !u?.user) return jsonRes(401, { ok: false, error: { code: 'UNAUTHENTICATED' } });
  if (!OPS.includes(String(role))) return jsonRes(403, { ok: false, error: { code: 'FORBIDDEN' } });
  let body: Record<string, unknown> = {};
  try { body = await req.json(); } catch { body = {}; }
  if (body.action === 'due') {
    const p = await pick();
    if (!p) return jsonRes(200, { ok: true, job: null });
    const soap = '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body>' + p.epos + '</s:Body></s:Envelope>';
    return jsonRes(200, { ok: true, job: p.jobId, soap, flights: p.flights, cars: p.cars });
  }
  if (body.action === 'done') {
    await markDone(String(body.job || ''), body.ok === true, `ipad ${u.user.email || u.user.id}: ${body.ok === true ? (body.queued ? 'queued on device' : 'printed') : 'printer refused'}`);
    return jsonRes(200, { ok: true });
  }
  return jsonRes(400, { ok: false, error: { code: 'BAD_ACTION' } });
}

async function setResponse(form: URLSearchParams): Promise<Response> {
  const file = form.get('ResponseFile') || '';
  const jobId = (file.match(/<printjobid>([^<]*)<\/printjobid>/) || [])[1] || '';
  await markDone(jobId, /success="true"/.test(file), file);
  return nothing();
}

Deno.serve(async (req) => {
  const CORS = corsOf(req.headers.get('Origin'));
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: CORS });
  const k = new URL(req.url).searchParams.get('k') || '';
  if (!k) {
    try { const r = await appRequest(req); Object.entries(CORS).forEach(([a, b]) => r.headers.set(a, b)); return r; }
    catch (e) { console.log(JSON.stringify({ event: 'print_error', error: String(e).slice(0, 200) })); return new Response('{"ok":false}', { status: 500, headers: { ...CORS, 'Content-Type': 'application/json' } }); }
  }
  if (!sameKey(k, Deno.env.get('PRINTER_POLL_KEY') || '')) return new Response('forbidden', { status: 403 });
  if (req.method !== 'POST') return nothing();
  const form = new URLSearchParams(await req.text());
  try {
    const type = form.get('ConnectionType');
    if (type === 'GetRequest') return await getRequest();
    if (type === 'SetResponse') return await setResponse(form);
  } catch (e) { console.log(JSON.stringify({ event: 'print_error', error: String(e).slice(0, 200) })); }
  return nothing();
});
