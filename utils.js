// AirValet — Developed by Matt Solutions. Built exclusively for Makers Air. © 2026

// ── XSS HELPER ─────────────────────────────────────────────────
function escapeHTML(s) {
  if (s == null) return '';
  return String(s)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

// ── DATE HELPERS ───────────────────────────────────────────────
function getToday()    { var d=new Date(); d.setHours(0,0,0,0); return d; }
function getTomorrow() { var d=getToday(); d.setDate(d.getDate()+1); return d; }
function getTodayStr() { var d=getToday(); return (d.getMonth()+1)+'/'+d.getDate()+'/'+d.getFullYear(); }

function pd(s) {
  if (!s) return null;
  s = String(s).trim();
  if(s.toUpperCase()==='TODAY') { var _t=getToday(); return new Date(_t.getFullYear(),_t.getMonth(),_t.getDate()); }
  var p = s.split('/');
  if (p.length === 3) {
    var mo = parseInt(p[0],10), d = parseInt(p[1],10), y = parseInt(p[2],10);
    if (String(p[2]).length === 2) y += 2000;
    var dt = new Date(y, mo-1, d);
    return isNaN(dt.getTime()) ? null : dt;
  }
  var q = s.split('-');
  if (q.length === 3 && q[0].length === 4) return new Date(parseInt(q[0],10), parseInt(q[1],10)-1, parseInt(q[2],10));
  return null;
}
function sd(a,b) { return a&&b&&a.getFullYear()===b.getFullYear()&&a.getMonth()===b.getMonth()&&a.getDate()===b.getDate(); }
function isToday(s)  { return sd(pd(s), getToday()); }
function isTmrw(s)   { return sd(pd(s), getTomorrow()); }
function isLate(s)   { var t=getToday(); var d=pd(s); return d&&d<t&&!sd(d,t); }
var isLate2 = isLate;
function nextSunday() {
  var d=getToday(); var day=d.getDay(); var diff=day===0?7:7-day;
  d.setDate(d.getDate()+diff); return d;
}
function isSunday(s) { return sd(pd(s), nextSunday()); }
function isArrToday(ts) {
  if (!ts) return false;
  var t=getToday();
  var s = String(ts).trim(), p = s.split('/');
  if (p.length >= 3) { var d=new Date(parseInt(p[2],10),parseInt(p[0],10)-1,parseInt(p[1],10)); if(!isNaN(d.getTime())) return sd(d,t); }
  var d2=new Date(s); return !isNaN(d2.getTime())&&sd(d2,t);
}

// ── FORMATTERS ─────────────────────────────────────────────────
function fmtD(s) {
  if (!s) return '-';
  var d=pd(s); if(!d) return s;
  return d.toLocaleDateString('en-US',{weekday:'short',month:'short',day:'numeric',year:'numeric'});
}
function fmtP(p) {
  if (!p) return '-';
  var d=String(p).replace(/\D/g,'');
  if(d.length===10) return '('+d.slice(0,3)+') '+d.slice(3,6)+'-'+d.slice(6);
  if(d.length===11&&d[0]==='1') return '('+d.slice(1,4)+') '+d.slice(4,7)+'-'+d.slice(7);
  return p;
}
function fmtA(ts) {
  if (!ts) return '-';
  var s=String(ts).trim(), p=s.split('/');
  if(p.length>=3){ var d=new Date(parseInt(p[2],10),parseInt(p[0],10)-1,parseInt(p[1],10)); if(!isNaN(d.getTime())) return d.toLocaleDateString('en-US',{month:'short',day:'numeric',year:'numeric'}); }
  var d2=new Date(s); if(!isNaN(d2.getTime())) return d2.toLocaleDateString('en-US',{month:'short',day:'numeric',year:'numeric'});
  return ts;
}
function d2us(v) {
  if(!v) return '';
  var d=pd(v); if(!d) return '';
  return (d.getMonth()+1)+'/'+d.getDate()+'/'+d.getFullYear();
}
function tsToDateInput(ts) {
  if (!ts) return '';
  var s=String(ts).trim(), p=s.split('/'), d;
  if (p.length>=3) d=new Date(parseInt(p[2],10),parseInt(p[0],10)-1,parseInt(p[1],10));
  if (!d||isNaN(d.getTime())) d=new Date(ts);
  if (!d||isNaN(d.getTime())) return '';
  return d.getFullYear()+'-'+String(d.getMonth()+1).padStart(2,'0')+'-'+String(d.getDate()).padStart(2,'0');
}

// ── PHONE NORMALIZATION (E.164) ──────────────────────────────────
// Added for the Twilio migration groundwork (Fase 1 — see
// docs/TWILIO_MIGRATION_AUDIT.md). Pure/local-only: does not call any
// network API and is not used by the native sms: flow (which keeps using
// its own raw digit-stripping, unchanged, to avoid any behavior change).
// Never guesses a country code for an ambiguous international number —
// returns invalid instead of inventing one.
function normalizePhoneE164(raw) {
  var original = raw == null ? '' : String(raw);
  var trimmed = original.trim();
  if (!trimmed) return { original: original, e164: '', valid: false, reason: 'Phone number is empty' };
  var hasPlus = trimmed.charAt(0) === '+';
  var digits = trimmed.replace(/[^\d]/g, '');
  if (hasPlus) {
    if (digits.length < 8 || digits.length > 15) {
      return { original: original, e164: '', valid: false, reason: 'International number must have 8–15 digits after +' };
    }
    return { original: original, e164: '+' + digits, valid: true, reason: '' };
  }
  if (digits.length === 10) {
    return { original: original, e164: '+1' + digits, valid: true, reason: '' };
  }
  if (digits.length === 11 && digits.charAt(0) === '1') {
    return { original: original, e164: '+' + digits, valid: true, reason: '' };
  }
  return { original: original, e164: '', valid: false, reason: 'Not a recognizable 10-digit US number, and no leading + for an international number' };
}

// ── STRING HELPERS ─────────────────────────────────────────────
function fuzzyMatch(a, b) {
  a = a.toUpperCase().trim(); b = b.toUpperCase().trim();
  if(a===b) return true;
  var ap=a.split(' '), bp=b.split(' ');
  var matches=0;
  ap.forEach(function(p){if(p.length>1&&bp.some(function(q){return q.indexOf(p)>=0||p.indexOf(q)>=0;}))matches++;});
  return matches>=Math.min(ap.length,bp.length)&&matches>0;
}

// ── RETURN / PICKUP MODEL (single client-side source of truth) ─────────
// Mirrors the SQL functions in migrations/20261010_add_passenger_return_operator.sql
// (airvalet_departure_operator / airvalet_pickup_location). Every screen,
// print, TV view and SMS builder asks THESE helpers where the vehicle is
// picked up — nothing reads delivery_at_customs on its own to decide it.
//   Flying with  = departure, from the ticket prefix ('A-' = Ascend). History.
//   Returning with (return_operator) = MAKERS | ASCEND | OTHER, editable.
//   Pickup: MAKERS → Hangar 19 (Customs only as a staff-approved EXCEPTION,
//           i.e. delivery_at_customs) · ASCEND → Customs · OTHER → manual.
var RETURN_OPERATOR_LABELS = { MAKERS: 'Makers Air', ASCEND: 'Ascend', OTHER: 'Other' };
function departureOperator(r) {
  return /^A-/.test(String((r && r.ticket) || '')) ? 'ASCEND' : 'MAKERS';
}
// Rows saved before return_operator existed (delivered history) have none;
// derive it the same way the migration backfill did.
function returnOperator(r) {
  if (!r) return null;
  if (r.return_operator === 'MAKERS' || r.return_operator === 'ASCEND' || r.return_operator === 'OTHER') return r.return_operator;
  if (r.not_returning_with_makers_air) return 'OTHER';
  return departureOperator(r);
}
// 'HANGAR_19' | 'CUSTOMS' | null (null = OTHER: manual handling, no place)
function pickupLocation(r) {
  var op = returnOperator(r);
  if (op === 'MAKERS') return r.delivery_at_customs ? 'CUSTOMS' : 'HANGAR_19';
  if (op === 'ASCEND') return 'CUSTOMS';
  return null;
}
function isCustomsException(r) {
  return returnOperator(r) === 'MAKERS' && !!r.delivery_at_customs;
}
function isCustomsRequestPending(r) {
  return returnOperator(r) === 'MAKERS' && !r.delivery_at_customs && !!r.customs_exception_requested_at;
}
function pickupLabel(r) {
  var p = pickupLocation(r);
  return p === 'HANGAR_19' ? 'Hangar 19' : p === 'CUSTOMS' ? 'Customs' : 'Manual (Other)';
}

// ── REQUIRED MOVE (single decision for Dashboard + TV) ────────────────
// Where the vehicle is NOW comes from the existing `loc` field (no new
// state); 'CUSTOMS' is a valid loc value for a vehicle staged at Customs.
// Where it must BE comes from pickupLocation() above. The only output:
//   'MOVE_TO_HANGAR_19' | 'MOVE_TO_CUSTOMS' | null
// Other return → never an automatic move. A pending Customs request keeps
// the Hangar 19 target (pickupLocation already says so) until approved.
var CUSTOMS_LOC = 'CUSTOMS';
function vehicleLocationKey(r) {
  var l = String((r && r.loc) || '').trim().toUpperCase().replace(/\s+/g, ' ');
  return l === 'HANGAR 19' ? 'HANGAR_19' : l === CUSTOMS_LOC ? 'CUSTOMS' : 'ELSEWHERE';
}
function requiredMove(r) {
  if (!r || r.status === 'DELIVERED' || r.status === 'ARCHIVED' || r.isOfflinePending) return null;
  var target = pickupLocation(r);
  if (!target) return null;
  return vehicleLocationKey(r) === target ? null : 'MOVE_TO_' + target;
}
function requiredMoveLabel(move) {
  return move === 'MOVE_TO_CUSTOMS' ? 'MOVE TO CUSTOMS' : move === 'MOVE_TO_HANGAR_19' ? 'MOVE TO H19' : '';
}
