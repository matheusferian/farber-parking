// ══════════════════════════════════════════════════════════════════════
// AirValet — Offline Mode Phase 1: device identity + offline
// authorization-window infrastructure.
//
// IMPORTANT — read before touching this file:
// The "offline authorization" marker below is NOT a Supabase session and
// NEVER proves the user is currently authenticated. While offline,
// AirValet cannot contact Supabase to cryptographically revalidate
// anyone. This marker means exactly one thing:
//   "This specific operational iPad successfully authenticated online
//    within the last OFFLINE_AUTH_WINDOW_HOURS hours."
// That is an operational policy decision (is this device trusted enough,
// recently enough, to be allowed to queue check-ins while offline —
// once Phase 2 exists), not a security/authentication claim. Never
// present it in the UI as "signed in" or "authenticated" while offline.
//
// Never store here: password, Supabase JWT, refresh token, access
// token. Only a timestamp, an expiry, the device id, and (for display
// only) the email of whoever last signed in successfully.
// ══════════════════════════════════════════════════════════════════════

var OFFLINE_AUTH_WINDOW_HOURS = 24;

var LS_KEY_DEVICE_ID = 'airvalet_device_id';
var LS_KEY_DEVICE_CODE = 'airvalet_device_code';
var LS_KEY_OFFLINE_AUTH = 'airvalet_offline_auth';

// ── Device ID — stable, invisible, technical identifier ─────────────
// Generated once, never regenerated, never shown to attendants.
function getOfflineDeviceId(){
  var id = localStorage.getItem(LS_KEY_DEVICE_ID);
  if(!id){
    id = (crypto && crypto.randomUUID) ? crypto.randomUUID() : ('dev-'+Date.now()+'-'+Math.random().toString(36).slice(2));
    localStorage.setItem(LS_KEY_DEVICE_ID, id);
  }
  return id;
}

// ── Device Code — human-facing, manually provisioned, NEVER auto-generated ──
// Phase 1: configurable only from the diagnostics panel, for testing.
// Phase 3+ is expected to add a server-side uniqueness registry before
// this becomes load-bearing for real offline check-ins (see PROJECT.md).
function getOfflineDeviceCode(){
  return localStorage.getItem(LS_KEY_DEVICE_CODE) || '';
}

// Validation is deliberately strict and narrow:
//  - 1-4 characters, uppercase letters/digits only (no hyphens, no
//    slashes) — keeps the resulting ticket suffix (MMDD-N-<code>)
//    unambiguous and compact.
//  - must start with a letter (keeps it readable, e.g. "M1" not "1M").
//  - must never be exactly "A" and must never start with "A-" — even
//    though the code is only ever used as a ticket SUFFIX (never a
//    prefix, so it structurally cannot make isAscend()'s /^A-/ check
//    fire), this is an explicit extra guard against any future misuse
//    of the value as a prefix, and against operator confusion with the
//    Ascend "A-" convention.
function validateOfflineDeviceCode(code){
  var c = String(code || '').trim().toUpperCase();
  if(!/^[A-Z][A-Z0-9]{0,3}$/.test(c)){
    return {valid:false, reason:'Use 1-4 letters/digits, starting with a letter (e.g. M1).'};
  }
  if(c === 'A' || c.indexOf('A-') === 0){
    return {valid:false, reason:'Device codes cannot be "A" or start with "A-" (reserved by the Ascend ticket rule).'};
  }
  return {valid:true, code:c};
}

function setOfflineDeviceCode(code){
  var check = validateOfflineDeviceCode(code);
  if(!check.valid) throw new Error(check.reason);
  localStorage.setItem(LS_KEY_DEVICE_CODE, check.code);
  return check.code;
}

// ── Offline authorization window ─────────────────────────────────────
// Call on every SIGNED_IN / TOKEN_REFRESHED event (wired in index.html).
// Deliberately does NOT run on SIGNED_OUT — logging out neither
// refreshes nor clears this marker; it expires only on its own 24h
// schedule, independent of momentary session state. Already-queued
// offline records are never affected by this marker either way.
function recordOfflineAuthSuccess(userEmail){
  var now = Date.now();
  var marker = {
    deviceId: getOfflineDeviceId(),
    userEmail: userEmail || '',
    lastAuthenticatedAt: new Date(now).toISOString(),
    expiresAt: new Date(now + OFFLINE_AUTH_WINDOW_HOURS*3600000).toISOString()
  };
  localStorage.setItem(LS_KEY_OFFLINE_AUTH, JSON.stringify(marker));
  return marker;
}

// Returns {present, valid, marker} — never throws on missing/corrupt data.
function getOfflineAuthStatus(){
  var raw = localStorage.getItem(LS_KEY_OFFLINE_AUTH);
  if(!raw) return {present:false, valid:false, marker:null};
  var marker;
  try{ marker = JSON.parse(raw); }catch(e){ return {present:false, valid:false, marker:null}; }
  var expiresAt = marker && marker.expiresAt ? new Date(marker.expiresAt).getTime() : NaN;
  var valid = !isNaN(expiresAt) && Date.now() < expiresAt;
  return {present:true, valid:valid, marker:marker};
}
