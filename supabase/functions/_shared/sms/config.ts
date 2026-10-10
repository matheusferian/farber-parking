// Runtime configuration for AirValet SMS — Supabase function secrets only.
// Nothing here is ever sent to the browser.
//
//   AIRVALET_SMS_MODE                 disabled (default) | mock | allowlist | live
//   AIRVALET_SMS_TEST_ALLOWLIST       comma-separated numbers allowed in 'allowlist'
//   AIRVALET_SMS_PUBLIC_FUNCTIONS_URL e.g. https://<ref>.supabase.co/functions/v1
//   TWILIO_ACCOUNT_SID                Farber account (AC…)
//   TWILIO_API_KEY_SID / _SECRET      restricted/standard API key used to SEND
//   TWILIO_AUTH_TOKEN                 ONLY to validate webhook signatures
//   TWILIO_MESSAGING_SERVICE_SID      "AirValet SMS" service (MG…)
//   AIRVALET_PASS_BASE_URL            passenger link base, default https://farberos.com/a#
//                                     (token in the #fragment: never sent to servers/logs)

import { normalizePhoneE164 } from './phone.ts';
import type { SmsMode } from './service.ts';

export type SmsConfig = {
  mode: SmsMode;
  allowlist: string[];
  publicFunctionsUrl: string | null;
  // Webhooks (inbound + status) can verify Twilio signatures and know which
  // Messaging Service is ours. Required for allowlist/live.
  webhookReady: boolean;
  passBaseUrl: string;
  twilio: {
    accountSid: string; apiKeySid: string; apiKeySecret: string;
    authToken: string | undefined; messagingServiceSid: string;
  } | null;
  problems: string[];
};

const MODES: SmsMode[] = ['disabled', 'mock', 'allowlist', 'live'];

export function readSmsConfig(get: (k: string) => string | undefined): SmsConfig {
  const problems: string[] = [];
  const rawMode = (get('AIRVALET_SMS_MODE') || 'disabled').trim().toLowerCase();
  let mode: SmsMode = MODES.includes(rawMode as SmsMode) ? (rawMode as SmsMode) : 'disabled';
  if (mode !== rawMode) problems.push('AIRVALET_SMS_MODE invalid → disabled');

  const allowlist = (get('AIRVALET_SMS_TEST_ALLOWLIST') || '')
    .split(',').map((s) => normalizePhoneE164(s)).filter((p) => p.valid).map((p) => (p as { e164: string }).e164);

  const publicFunctionsUrl = (get('AIRVALET_SMS_PUBLIC_FUNCTIONS_URL') || '').replace(/\/+$/, '') || null;
  if (publicFunctionsUrl && !/^https:\/\//.test(publicFunctionsUrl)) problems.push('public functions URL must be https');

  const rawPass = (get('AIRVALET_PASS_BASE_URL') || 'https://farberos.com/a#').trim();
  const passBaseUrl = /^https:\/\/[^\s#]+[#/]$/.test(rawPass) ? rawPass : 'https://farberos.com/a#';
  if (rawPass !== passBaseUrl) problems.push('AIRVALET_PASS_BASE_URL must be https and end with # or / → default used');

  const accountSid = get('TWILIO_ACCOUNT_SID') || '';
  const apiKeySid = get('TWILIO_API_KEY_SID') || '';
  const apiKeySecret = get('TWILIO_API_KEY_SECRET') || '';
  const messagingServiceSid = get('TWILIO_MESSAGING_SERVICE_SID') || '';
  const authToken = get('TWILIO_AUTH_TOKEN') || undefined;
  const twilioComplete = /^AC[0-9a-f]{32}$/i.test(accountSid) && /^SK[0-9a-f]{32}$/i.test(apiKeySid)
    && apiKeySecret.length >= 16 && /^MG[0-9a-f]{32}$/i.test(messagingServiceSid);

  // Real sending is only allowed when the replies/STOP/status path works too:
  // without the Auth Token every Twilio webhook would be refused (403) and
  // STOPs / delivery results would be silently lost.
  // Plain http is tolerated ONLY for a localhost stack in mock mode (local
  // tests never reach Twilio); allowlist/live always need https.
  const urlOk = !!publicFunctionsUrl && (/^https:\/\//.test(publicFunctionsUrl)
    || (mode === 'mock' && /^http:\/\/(127\.0\.0\.1|localhost)(:\d+)?\//.test(publicFunctionsUrl + '/')));
  const webhookReady = urlOk && /^[0-9a-f]{32}$/i.test(authToken || '') && /^MG[0-9a-f]{32}$/i.test(messagingServiceSid);
  if ((mode === 'allowlist' || mode === 'live') && (!twilioComplete || !webhookReady)) {
    problems.push('real sending requested but Twilio config incomplete (API key, Messaging Service, Auth Token, public URL) → disabled');
    mode = 'disabled';
  }
  if (mode === 'allowlist' && allowlist.length === 0) {
    problems.push('allowlist mode with empty allowlist → disabled');
    mode = 'disabled';
  }

  return {
    mode,
    allowlist,
    publicFunctionsUrl,
    webhookReady,
    passBaseUrl,
    twilio: twilioComplete ? { accountSid, apiKeySid, apiKeySecret, authToken, messagingServiceSid } : null,
    problems,
  };
}
