// Builds NotifyDeps from the function secrets. Push needs the AirValet VAPID
// key pair (never the Event Valet keys); the admin SMS copy follows the SMS
// mode: disabled → none, mock → MockProvider, allowlist → only to an
// allowlisted number, live → Twilio.
//   AIRVALET_VAPID_PRIVATE_JWK  JSON JWK (P-256, d/x/y)
//   AIRVALET_VAPID_PUBLIC       base64url uncompressed public key
//   AIRVALET_VAPID_SUBJECT      mailto: or https: contact (default mailto:info@farberparking.com)
//   AIRVALET_APP_URL            staff app origin (default https://airvalet.farberos.com)

import type { SmsConfig } from '../sms/config.ts';
import { MockProvider, TwilioProvider, type SmsProvider } from '../sms/provider.ts';
import type { NotifyDeps, Vapid } from './notify.ts';

// deno-lint-ignore no-explicit-any
type Db = { rpc(fn: string, args: Record<string, unknown>): PromiseLike<{ data: any; error: any }> };

export function readVapid(get: (k: string) => string | undefined): Vapid | null {
  try {
    const jwk = JSON.parse(get('AIRVALET_VAPID_PRIVATE_JWK') || 'null');
    const pub = get('AIRVALET_VAPID_PUBLIC') || '';
    if (!jwk || jwk.kty !== 'EC' || jwk.crv !== 'P-256' || !jwk.d || !/^[A-Za-z0-9_-]{80,100}$/.test(pub)) return null;
    return { privateJwk: jwk, publicKey: pub, subject: get('AIRVALET_VAPID_SUBJECT') || 'mailto:info@farberparking.com' };
  } catch {
    return null;
  }
}

export function adminSmsProvider(cfg: SmsConfig): SmsProvider | null {
  if (cfg.mode === 'mock') return new MockProvider();
  if ((cfg.mode === 'allowlist' || cfg.mode === 'live') && cfg.twilio) {
    const tw = new TwilioProvider({ ...cfg.twilio, timeoutMs: 10_000 });
    if (cfg.mode === 'live') return tw;
    return {
      name: tw.name,
      send: (req) => cfg.allowlist.includes(req.to)
        ? tw.send(req)
        : Promise.resolve({ kind: 'rejected', errorCode: 'NOT_ALLOWLISTED', errorMessage: 'test mode: admin phone not on the allowlist' }),
    };
  }
  return null;
}

export function makeNotifyDeps(db: Db, cfg: SmsConfig, get: (k: string) => string | undefined,
  log: (event: string, data: Record<string, unknown>) => void): NotifyDeps {
  return {
    db,
    vapid: readVapid(get),
    adminProvider: adminSmsProvider(cfg),
    appUrl: (get('AIRVALET_APP_URL') || 'https://airvalet.farberos.com').replace(/\/+$/, ''),
    log,
  };
}
