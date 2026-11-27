// printer-poll — Epson Server Direct Print endpoint (owner 2026-11-27: print automatically from AirValet,
// not from the owner's Mac). The thermal printer TM-m30II in the hangar asks this URL every few seconds:
//   ConnectionType=GetRequest  → we answer with the slips that are due (or nothing)
//   ConnectionType=SetResponse → the printer tells us if it printed
// 8 AM: today's cars (flights landing 11 AM or later + any not printed yesterday). 2 PM: tomorrow, flights before 11 AM.
// Public endpoint: deploy with --no-verify-jwt; protected by the secret ?k= (PRINTER_POLL_KEY), set only in the printer.
import { createClient } from 'npm:@supabase/supabase-js@2';
import { buildSlips, dueJob, eposXml, keepFor, printRequestInfo, type Match, type Pax } from '../_shared/print/slips.ts';

const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });
const TZ = 'America/New_York';
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

async function getRequest(): Promise<Response> {
  const now = new Date(), et = etParts(now);
  const job = dueJob(et.date, addDay(et.date, 1), et.hour);
  if (!job) return nothing();
  const { data: row } = await admin.from('airvalet_print_jobs').select('*').eq('job_key', job.key).maybeSingle();
  if (row && (row.status === 'printed' || row.status === 'empty')) return nothing();
  if (row && (row.attempts || 0) >= 3) return nothing();
  if (row && row.status === 'sent' && Date.now() - new Date(row.sent_at).getTime() < 3 * 60_000) return nothing();
  const { matches, at } = await latestMatches(job.date);
  // 2 PM: wait for the 1:45 PM reading of tomorrow (until 3:30 PM at the latest).
  if (job.kind === 'pm') {
    const fresh = at && etParts(new Date(at)).date === et.date && etParts(new Date(at)).hour >= 13;
    if (!fresh && (et.hour < 15 || (et.hour === 15 && et.minute < 30))) return nothing();
  }
  let skip = new Set<number>();
  if (job.kind === 'am') {
    const { data: prev } = await admin.from('airvalet_print_jobs').select('passenger_ids').eq('job_key', `pm-${job.date}`).eq('status', 'printed').maybeSingle();
    skip = new Set((prev?.passenger_ids || []) as number[]);
  }
  const { data: pax } = await admin.from('passengers').select('id,name,return_flight,departure_time').eq('ret', retOf(job.date)).eq('status', 'PENDING');
  const slips = buildSlips(((pax || []) as Pax[]).filter((p) => !skip.has(p.id)), matches, keepFor(job.kind));
  const ids = slips.flatMap((s) => s.ids);
  if (!slips.length) {
    await admin.from('airvalet_print_jobs').upsert({ job_key: job.key, kind: job.kind, service_date: job.date, status: 'empty', passenger_ids: [], updated_at: now.toISOString() });
    return nothing();
  }
  const attempts = (row?.attempts || 0) + 1;
  await admin.from('airvalet_print_jobs').upsert({ job_key: job.key, kind: job.kind, service_date: job.date, status: 'sent', attempts,
    sent_at: now.toISOString(), passenger_ids: ids, flights: slips.length, updated_at: now.toISOString() });
  const t = etParts(now), h12 = `${t.hour % 12 || 12}:${String(t.minute).padStart(2, '0')} ${t.hour < 12 ? 'AM' : 'PM'}`;
  const stamp = `Printed ${t.date.slice(5, 7)}/${t.date.slice(8, 10)} ${h12} - Air Valet`;
  console.log(JSON.stringify({ event: 'print_sent', job: job.key, attempts, flights: slips.length, cars: ids.length }));
  return xml(printRequestInfo(eposXml(slips, dayLabel(job.date), stamp), `${job.key}~${attempts}`));
}

async function setResponse(form: URLSearchParams): Promise<Response> {
  const file = form.get('ResponseFile') || '';
  const jobId = (file.match(/<printjobid>([^<]*)<\/printjobid>/) || [])[1] || '';
  const ok = /success="true"/.test(file);
  const key = jobId.split('~')[0];
  if (key) {
    await admin.from('airvalet_print_jobs').update({ status: ok ? 'printed' : 'failed', printed_at: ok ? new Date().toISOString() : null,
      last_result: file.slice(0, 500), updated_at: new Date().toISOString() }).eq('job_key', key);
    console.log(JSON.stringify({ event: 'print_result', job: key, ok }));
  }
  return nothing();
}

Deno.serve(async (req) => {
  const k = new URL(req.url).searchParams.get('k') || '';
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
