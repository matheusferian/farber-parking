// Device authorization helpers (AirValet logins are shared, so SMS is tied to
// an ADMIN-approved DEVICE, not to a login). The browser keeps a random key in
// localStorage and sends it as x-airvalet-device; only its SHA-256 is compared
// in the DB (airvalet_sms_devices.key_hash). Same rule as the SQL function
// airvalet_sms_device_key_hash(): 43-128 chars of [A-Za-z0-9_-], else no device.

const DEVICE_KEY_RE = /^[A-Za-z0-9_-]{43,128}$/;

export async function deviceKeyHash(key: string | null | undefined): Promise<string | null> {
  if (!key || !DEVICE_KEY_RE.test(key)) return null;
  const d = new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(key)));
  return Array.from(d, (b) => b.toString(16).padStart(2, '0')).join('');
}

// Employee picked in the UI ("who is texting"): a label for the audit trail,
// never an authorization.
export function staffLabel(v: unknown): string | null {
  if (typeof v !== 'string') return null;
  const s = v.replace(/[\u0000-\u001f\u007f]/g, '').trim().slice(0, 60);
  return s.length ? s : null;
}
