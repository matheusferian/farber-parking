// Log / DB sanitization. Nothing that leaves an Edge Function (console log,
// error_message column, HTTP response) may carry a credential or a full
// phone number.

const PATTERNS: Array<[RegExp, string]> = [
  [/\bAC[0-9a-f]{32}\b/gi, 'AC…'],                   // Account SID
  [/\bSK[0-9a-f]{32}\b/gi, 'SK…'],                   // API Key SID
  [/\bBasic\s+[A-Za-z0-9+/=]{8,}/g, 'Basic …'],      // auth header
  [/\bBearer\s+[A-Za-z0-9._\-]{8,}/g, 'Bearer …'],   // JWTs
  [/\+?\d[\d\s().-]{8,}\d/g, '[phone]'],             // phone numbers
];

export function sanitizeProviderText(text: string, maxLen = 300): string {
  let out = String(text ?? '');
  for (const [re, rep] of PATTERNS) out = out.replace(re, rep);
  return out.slice(0, maxLen);
}

// Redacts exact secret values (Auth Token, API secret…) as well, for the rare
// case a provider echoes one back.
export function makeRedactor(secrets: Array<string | undefined>) {
  const values = secrets.filter((s): s is string => !!s && s.length >= 6);
  return (text: string): string => {
    let out = String(text ?? '');
    for (const s of values) out = out.split(s).join('[secret]');
    return sanitizeProviderText(out, 1000);
  };
}
