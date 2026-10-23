// Local test harness for the Event Valet pages (never deployed).
//   :8789  static dist/ with the same rewrites as vercel.json
//   :8790  event-valet Edge Function handler (SMS mode = mock, test auth token)
//   :8791  fake Epson printer (HTTP, CORS) — records each XML job; GET /fail toggles failures
// deno run -A tests/event_valet/devserver.ts   (env: EV_SB_URL, EV_SERVICE_KEY_FILE, EV_ANON_KEY_FILE)
import { makeHandler } from '../../supabase/functions/event-valet/handler.ts';

const ROOT = new URL('../../dist/', import.meta.url).pathname;
const SB = Deno.env.get('EV_SB_URL') ?? 'http://127.0.0.1:55331';
const SERVICE = Deno.readTextFileSync(Deno.env.get('EV_SERVICE_KEY_FILE')!).trim();
const ANON = Deno.readTextFileSync(Deno.env.get('EV_ANON_KEY_FILE')!).trim();
const JOBS = Deno.env.get('EV_PRINT_LOG') ?? '/tmp/ev_print_jobs.log';

const REWRITES: Record<string, string> = {
  '/events/makers-halloween-2026': '/events/makers-halloween-2026/index.html',
  '/events/makers-halloween-2026/t': '/events/makers-halloween-2026/t.html',
};
const TYPES: Record<string, string> = { html: 'text/html; charset=utf-8', js: 'text/javascript', css: 'text/css', png: 'image/png', webmanifest: 'application/manifest+json' };
Deno.serve({ port: 8789 }, async (req) => {
  let p = decodeURIComponent(new URL(req.url).pathname);
  p = REWRITES[p] ?? (p.endsWith('/') ? p + 'index.html' : p);
  if (p.includes('..')) return new Response('bad', { status: 400 });
  try {
    const data = await Deno.readFile(ROOT + p.slice(1));
    return new Response(data, { headers: { 'Content-Type': TYPES[p.split('.').pop()!] ?? 'application/octet-stream', 'Cache-Control': 'no-store' } });
  } catch { return new Response('not found', { status: 404 }); }
});

const handle = makeHandler((k) => ({
  SUPABASE_URL: SB, SUPABASE_SERVICE_ROLE_KEY: SERVICE, SUPABASE_ANON_KEY: ANON,
  EVENT_VALET_SMS_MODE: 'mock', EVENT_VALET_PUBLIC_URL: 'http://127.0.0.1:8790/event-valet',
  EVENT_VALET_SITE_URL: 'http://127.0.0.1:8789', EVENT_VALET_ALLOWED_ORIGINS: 'http://127.0.0.1:8789',
  TWILIO_AUTH_TOKEN: 'local_test_auth_token', TWILIO_ACCOUNT_SID: 'AClocal', TWILIO_MESSAGING_SERVICE_SID: 'MGlocal',
} as Record<string, string>)[k]);
Deno.serve({ port: 8790 }, handle);

let fail = false;
Deno.serve({ port: 8791 }, async (req) => {
  const cors = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'content-type, soapaction', 'Access-Control-Allow-Methods': 'POST, OPTIONS' };
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: cors });
  if (req.method === 'GET' && new URL(req.url).pathname === '/fail') { fail = !fail; return new Response(`fail=${fail}`, { headers: cors }); }
  const xml = await req.text();
  if (xml.includes('<text')) await Deno.writeTextFile(JOBS, xml + '\n', { append: true });
  const ok = !fail;
  return new Response(`<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><response success="${ok}" code="${ok ? '' : 'EPTR_REC_EMPTY'}" status="0" battery="0"/></s:Body></s:Envelope>`,
    { headers: { ...cors, 'Content-Type': 'text/xml' } });
});
console.log('event valet devserver: 8789 pages, 8790 edge (mock), 8791 printer');
