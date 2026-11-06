// Spidertracks (satellite tracking of the Makers Air fleet) — READ-ONLY reader (owner 2026-11-06).
// The public ADS-B feed loses the Caravans ~110 nm out over the Bahamas; Spidertracks (Iridium)
// reports them from takeoff to shutdown. Only positions of the 8 Makers aircraft are kept: no
// messages, contacts, crew or anything else from the account.
//
// Login: the owner's Spidertracks user (Supabase secrets SPIDER_USER / SPIDER_PASS, set by the owner),
// Cognito USER_PASSWORD_AUTH (the web app's own flow), then REFRESH_TOKEN_AUTH while the refresh token
// lives, so the robot does not sign in every minute.

export const FXE = { lat: 26.1973, lon: -80.1707 };
export const MAKERS_FLEET = ['N208JH', 'N740RV', 'N821DD', 'N310CH', 'N146WM', 'N512DH', 'N633AH', 'N624JR'];
export const COGNITO = { region: 'us-west-2', clientId: '1a745oi1bkj71d7chgpjqiadvl' };
export const TRACKS_URL = 'https://api.spidertracks.io/v2/tracks/latest?active=true&pointsPerTrack=1&fetchEvents=false&fetchDeviceConnection=false';

export type SpiderPos = {
  registration: string; track_id: string | null; departed_at: string | null; last_at: string;
  lat: number; lon: number; alt_ft: number | null; speed_kt: number | null; heading: number | null;
  track_status: string | null; dist_fxe_nm: number; inbound: boolean;
};

const rad = (d: number) => d * Math.PI / 180;
export function distNm(aLat: number, aLon: number, bLat = FXE.lat, bLon = FXE.lon): number {
  const R = 3440.065, dLat = rad(bLat - aLat), dLon = rad(bLon - aLon);
  const h = Math.sin(dLat / 2) ** 2 + Math.cos(rad(aLat)) * Math.cos(rad(bLat)) * Math.sin(dLon / 2) ** 2;
  return 2 * R * Math.asin(Math.min(1, Math.sqrt(h)));
}
export function bearingTo(aLat: number, aLon: number, bLat = FXE.lat, bLon = FXE.lon): number {
  const y = Math.sin(rad(bLon - aLon)) * Math.cos(rad(bLat));
  const x = Math.cos(rad(aLat)) * Math.sin(rad(bLat)) - Math.sin(rad(aLat)) * Math.cos(rad(bLat)) * Math.cos(rad(bLon - aLon));
  return (Math.atan2(y, x) * 180 / Math.PI + 360) % 360;
}
// Heading within 50° of the bearing to FXE = coming to FXE.
export function headingToFxe(lat: number, lon: number, heading: number | null): boolean {
  if (heading == null || !isFinite(heading)) return false;
  const d = Math.abs(((heading - bearingTo(lat, lon)) + 540) % 360 - 180);
  return d <= 50;
}

const num = (v: unknown) => (typeof v === 'number' && isFinite(v) ? v : (typeof v === 'string' && v.trim() !== '' && isFinite(+v) ? +v : null));
const feet = (v: number | null, unit: unknown) => v == null ? null : (String(unit || 'ft').toLowerCase().startsWith('m') ? v * 3.28084 : v);
const knots = (v: number | null, unit: unknown) => {
  if (v == null) return null;
  const u = String(unit || 'knots').toLowerCase();
  return u.startsWith('km') ? v / 1.852 : u.startsWith('m') && u.includes('h') ? v / 1.15078 : v;
};
const iso = (ms: unknown) => { const n = num(ms); return n ? new Date(n).toISOString() : null; };

// tracks/latest → one position per Makers aircraft (latest point of its latest track).
export function parseTracks(body: unknown): SpiderPos[] {
  const items = (body as { items?: unknown[] })?.items;
  if (!Array.isArray(items)) throw new Error('LAYOUT');
  const best = new Map<string, SpiderPos>();
  for (const it of items as Record<string, any>[]) {
    const reg = String(it?.aircraft?.registration || '').toUpperCase().replace(/[^A-Z0-9]/g, '');
    if (!MAKERS_FLEET.includes(reg)) continue;
    const p = Array.isArray(it.points) && it.points.length ? it.points[it.points.length - 1] : null;
    const lat = num(p?.latitude), lon = num(p?.longitude), ts = num(p?.timestamp);
    if (lat == null || lon == null || !ts) continue;
    const heading = num(p.heading);
    const pos: SpiderPos = {
      registration: reg, track_id: it.trackId ? String(it.trackId) : null, departed_at: iso(it.departedTime), last_at: new Date(ts).toISOString(),
      lat, lon, alt_ft: (() => { const a = feet(num(p.altitude), p.altitudeUnit); return a == null ? null : Math.round(a); })(),
      speed_kt: (() => { const s = knots(num(p.speed), p.speedUnit); return s == null ? null : Math.round(s); })(),
      heading, track_status: p.trackStatus ? String(p.trackStatus) : null,
      dist_fxe_nm: Math.round(distNm(lat, lon) * 10) / 10, inbound: headingToFxe(lat, lon, heading),
    };
    const prev = best.get(reg);
    if (!prev || prev.last_at < pos.last_at) best.set(reg, pos);
  }
  return [...best.values()];
}

// Cognito (the web app's own user pool). Errors carry Cognito's __type (NotAuthorizedException = wrong
// or changed password).
export class SpiderAuthError extends Error { constructor(public code: string, msg: string) { super(msg); } }
export async function cognito(target: 'InitiateAuth', body: Record<string, unknown>, fetchFn = fetch) {
  const r = await fetchFn(`https://cognito-idp.${COGNITO.region}.amazonaws.com/`, {
    method: 'POST', headers: { 'Content-Type': 'application/x-amz-json-1.1', 'X-Amz-Target': `AWSCognitoIdentityProviderService.${target}` },
    body: JSON.stringify(body),
  });
  const j = await r.json().catch(() => ({}));
  if (!r.ok) throw new SpiderAuthError(String(j.__type || 'HTTP_' + r.status).split('#').pop()!, String(j.message || ''));
  const a = j.AuthenticationResult;
  if (!a?.IdToken) throw new SpiderAuthError(j.ChallengeName ? 'CHALLENGE_' + j.ChallengeName : 'NO_TOKEN', 'no token');
  return { idToken: String(a.IdToken), refreshToken: a.RefreshToken ? String(a.RefreshToken) : null, expiresIn: Number(a.ExpiresIn || 3600) };
}
export const loginPassword = (user: string, pass: string, f = fetch) =>
  cognito('InitiateAuth', { AuthFlow: 'USER_PASSWORD_AUTH', ClientId: COGNITO.clientId, AuthParameters: { USERNAME: user, PASSWORD: pass } }, f);
export const loginRefresh = (refresh: string, f = fetch) =>
  cognito('InitiateAuth', { AuthFlow: 'REFRESH_TOKEN_AUTH', ClientId: COGNITO.clientId, AuthParameters: { REFRESH_TOKEN: refresh } }, f);
