// valet-pass — public, read-only data for the Makers Air Valet passenger link
// in the check-in SMS: https://farberos.com/a#<token>.
//
// The token lives in the URL fragment, so it never reaches any server log or
// Referer. pass.html (served at farberos.com/a) POSTs it here as JSON, via the
// same-origin rewrite farberos.com/a/api → this function. This is the ONLY
// place the token is validated (airvalet_pass_view, SHA-256 lookup).
//
// Deploy with --no-verify-jwt (passengers have no login). Never logs the
// token, the body or the client address. Throttling is server-side in SQL,
// keyed by a salted hash of the client address (never the raw IP).
// Unknown, malformed, revoked and expired tokens all get { state: 'expired' }.

import { createClient } from 'npm:@supabase/supabase-js@2';

const ORIGINS = ['https://farberos.com'];
const TOKEN_RE = /^[A-Za-z0-9]{17}$/;
const MAX_BODY = 512;

const enc = new TextEncoder();
async function clientKey(req: Request): Promise<string | null> {
  const ip = (req.headers.get('x-forwarded-for') || '').split(',')[0].trim() || req.headers.get('x-real-ip') || '';
  if (!ip) return null;
  const salt = Deno.env.get('AIRVALET_PASS_RATE_SALT') || Deno.env.get('SUPABASE_URL') || 'airvalet';
  const d = new Uint8Array(await crypto.subtle.digest('SHA-256', enc.encode(salt + '|' + ip)));
  return Array.from(d.slice(0, 12), (b) => b.toString(16).padStart(2, '0')).join('');
}

Deno.serve(async (req) => {
  const origin = req.headers.get('origin');
  const headers: Record<string, string> = {
    'Content-Type': 'application/json',
    'Cache-Control': 'no-store',
    'Referrer-Policy': 'no-referrer',
    'X-Content-Type-Options': 'nosniff',
    'X-Robots-Tag': 'noindex, nofollow',
    'Access-Control-Allow-Origin': origin && ORIGINS.includes(origin) ? origin : ORIGINS[0],
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    'Access-Control-Allow-Headers': 'content-type',
    Vary: 'Origin',
  };
  const reply = (status: number, body: unknown) => new Response(JSON.stringify(body), { status, headers });
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers });
  if (req.method !== 'POST') return reply(405, { state: 'error' });

  let token = '';
  try {
    const raw = await req.text();
    if (raw.length > MAX_BODY) return reply(413, { state: 'error' });
    const t = (JSON.parse(raw) as { t?: unknown })?.t;
    token = typeof t === 'string' ? t : '';
  } catch {
    token = '';
  }
  // Malformed input still goes through the SQL view so it is throttled and
  // answered exactly like an unknown token (no shortcut, no oracle).
  if (!TOKEN_RE.test(token)) token = '';

  const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });
  const { data, error } = await admin.rpc('airvalet_pass_view', { p_token: token, p_client: await clientKey(req) });
  if (error) return reply(503, { state: 'error' });
  const row = Array.isArray(data) ? data[0] : null;
  if (!row || row.state === 'expired') return reply(200, { state: 'expired' });
  if (row.state === 'limited') return reply(429, { state: 'limited' });
  const { state: _s, ...pass } = row;
  return reply(200, { state: 'ok', pass });
});
