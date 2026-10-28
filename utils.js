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
  if (/^\s*\+/.test(String(p)) && !/^\s*\+1/.test(String(p))) return String(p).trim();   // international: keep as typed
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

// ── KEY COPY + FLIGHT TAG (portrait, Epson page mode) ─────────────────
// Both tags print turned 90° so they read upright while the key hangs from
// the sleeve ring. Measured with owner test prints on the TM-m30II
// (2026-10-28): the sleeve takes 58 mm of paper and ~10 mm of it is the
// cutter margin, so the page area is 384 dots long (reading width) by the
// 576-dot printable width (reading height). Font A 12×24, font B 10×24.
// Every <text> carries all of its attributes: ePOS keeps the previous size
// and alignment otherwise (the old Key Copy printed its bottom half at
// double size). A field prints only when it exists — never N/A or blanks.
var TAG_READ_W = 384, TAG_READ_H = 576, TAG_TOP = 8, TAG_LS = 30;
var TAG_CELL = { A: [12, 24], B: [10, 24] };
function tagSeg(t, font, o) { o = o || {}; return { t: String(t), font: font, w: o.w || 1, h: o.h || 1, em: !!o.em, rev: !!o.rev }; }
function tagSegW(s) { return s.t.length * TAG_CELL[s.font][0] * s.w; }
function tagSegH(s) { return TAG_CELL[s.font][1] * s.h; }
function tagRowSegs(l) { return (l.L || []).concat(l.R || []); }
function tagRowMaxH(l) { return Math.max.apply(null, tagRowSegs(l).map(tagSegH)); }
function tagRowsHeight(rows) {
  return rows.reduce(function(y, l){ return y + (l.feed || Math.max(TAG_LS, tagRowMaxH(l))); }, TAG_TOP);
}
// Word wrap; a word longer than a line is split (never silently dropped).
function tagWrap(text, cols) {
  var out = [], cur = '';
  String(text || '').split(/\s+/).filter(Boolean).forEach(function(w){
    while (w.length > cols) { if (cur) { out.push(cur); cur = ''; } out.push(w.slice(0, cols)); w = w.slice(cols); }
    if (!cur) cur = w; else if ((cur + ' ' + w).length <= cols) cur += ' ' + w; else { out.push(cur); cur = w; }
  });
  if (cur) out.push(cur);
  return out;
}
function tagPadCenter(t, n) { t = String(t); var l = Math.max(0, Math.floor((n - t.length) / 2)); var s = new Array(l + 1).join(' ') + t; while (s.length < n) s += ' '; return s; }
function tagPlace(l) {
  var xs = [], x = 0, rx = TAG_READ_W;
  (l.R || []).forEach(function(s){ rx -= tagSegW(s); });
  (l.L || []).forEach(function(s){ xs.push([s, x]); x += tagSegW(s); });
  (l.R || []).forEach(function(s){ xs.push([s, rx]); rx += tagSegW(s); });
  return xs;
}
// 'HH:MM' (24 h, as saved) → '5:30 PM'; anything else → ''.
function tagTime(hhmm) {
  var m = /^(\d{1,2}):(\d{2})$/.exec(String(hhmm || '').trim());
  if (!m || +m[1] > 23) return '';
  var h = +m[1];
  return ((h % 12) || 12) + ':' + m[2] + (h < 12 ? ' AM' : ' PM');
}
// r.ret → { label: 'MON NOV 2', year: 2026 } or null.
function tagDate(ret) {
  var d = pd(ret);
  if (!d) return null;
  return { year: d.getFullYear(),
    label: (d.toLocaleDateString('en-US', { weekday: 'short' }) + ' ' + d.toLocaleDateString('en-US', { month: 'short' }) + ' ' + d.getDate()).toUpperCase() };
}
function tagStamp(now) {
  var h = now.getHours(), mm = String(now.getMinutes()); if (mm.length < 2) mm = '0' + mm;
  return 'PRINTED ' + (now.getMonth() + 1) + '/' + now.getDate() + ' ' + ((h % 12) || 12) + ':' + mm + (h < 12 ? 'A' : 'P');
}
var TAG_WASH_TEXT = { CARWASH: 'CAR WASH · CONFIRMED', SEND_PRICE: 'CAR WASH? PRICE PENDING', REQUESTED: 'CAR WASH REQUESTED', WASHED: 'CAR WASH · DONE' };

// o = { ascend, pickupAuth, approx, wash: 'CARWASH'|'SEND_PRICE'|'WASHED'|'REQUESTED'|'', now: Date }
function keyCopyRows(r, o, fit) {
  var cols = Math.floor(TAG_READ_W / 12), half = Math.floor(cols / 2), out = [];
  var A = function(t, x){ return tagSeg(t, 'A', x); }, B = function(t, x){ return tagSeg(t, 'B', x); };
  var lines = function(t, x){ return tagWrap(t, cols).map(function(l){ return { L: [A(l, x)] }; }); };
  // fit.dense (last resort): single-height name, ticket and bars, tighter gaps,
  // stamp on the top line. Hangar and return stay big; nothing is dropped.
  var gap = function(n){ return { feed: fit.dense ? Math.round(n / 3) : n }; }, bigH = fit.dense ? 1 : 2;
  out.push({ L: [B(o.ascend ? 'ASCEND · PRIVATE FLIGHT' : 'MAKERS AIR VALET', { em: 1 })], R: fit.dense ? [B(tagStamp(o.now))] : [] }, gap(8));
  var n = ((o.ascend ? '[A] ' : '') + String(r.name || '')).trim().toUpperCase();
  if (n.length <= half) out.push({ L: [A(n, { w: 2, h: bigH, em: 1 })] }); else out = out.concat(lines(n, { h: bigH, em: 1 }));
  out.push(gap(8));
  var loc = String(r.loc || '').trim().toUpperCase();
  if (!loc) out.push({ L: [A('NO HANGAR', { w: 2, h: 2, em: 1 })] });
  else if (loc.length <= half) out.push({ L: [A(tagPadCenter(loc, half), { w: 2, h: fit.hangH, em: 1, rev: 1 })] });
  else out.push({ L: [A(tagPadCenter(loc, cols), { h: fit.hangH, em: 1, rev: 1 })] });
  if (pickupLocation(r) === 'CUSTOMS') {
    out.push(gap(4), { L: [A(tagPadCenter('DELIVER TO CUSTOMS', cols), { h: bigH, em: 1, rev: 1 })] });
    if (isCustomsException(r)) out = out.concat(lines('MAKERS EXCEPTION - APPROVED', { em: 1 }));
  }
  if (isCustomsRequestPending(r)) out = out.concat(lines('CUSTOMS REQUESTED - PENDING · HANGAR 19 UNTIL APPROVED', { em: 1 }));
  out.push(gap(8));
  if (r.ticket) out.push({ L: [B('TICKET '), A(r.ticket, { w: 2, h: bigH })] });
  var d = tagDate(r.ret), tm = tagTime(r.departure_time);
  var retL = [A('RETURN ', { h: 2 }), A(d ? d.label : 'NO DATE', { w: 2, h: 2, em: 1 })];
  var extra = [d && d.year !== o.now.getFullYear() ? String(d.year) : '', tm, d && !tm && o.approx ? 'APPROX' : '', d ? '' : 'CONFIRM'].filter(Boolean).join(' ');
  var retW = retL.reduce(function(a, s){ return a + tagSegW(s); }, 0);
  if (extra && retW + (extra.length + 1) * 12 <= TAG_READ_W) out.push({ L: retL, R: [A(extra, { h: 2 })] });
  else { out.push({ L: retL }); if (extra) out.push({ L: [A(extra, { em: 1 })] }); }
  if (o.wash === 'CARWASH') out.push(gap(6), { L: [A(tagPadCenter(TAG_WASH_TEXT.CARWASH, cols), { h: bigH, em: 1, rev: 1 })] });
  else if (TAG_WASH_TEXT[o.wash]) out.push(gap(6), { L: [A(TAG_WASH_TEXT[o.wash], { em: o.wash !== 'REQUESTED' })] });
  out.push(gap(14));
  var veh = [r.car, r.color].map(function(v){ return String(v || '').trim(); }).filter(Boolean).join(' · ').toUpperCase();
  if (veh) out = out.concat(lines(veh, { em: 1 }));
  if (String(r.phone || '').trim()) out.push({ L: [B(fmtP(r.phone))] });
  if (o.pickupAuth) out = out.concat(lines('AUTH PICKUP: ' + String(r.pickup_auth_name).trim().toUpperCase() + (r.pickup_auth_phone ? ' ' + fmtP(r.pickup_auth_phone) : '') + ' · CHECK ID', { em: 1 }));
  if (returnOperator(r) === 'OTHER') out = out.concat(lines('RETURNING WITH OTHER · CONFIRM BEFORE STAGING', { em: 1 }));
  out = out.concat(tagObsRows(r, cols, fit.obs, A, B));
  if (!fit.dense) out.push({ feed: 8 }, { L: [B(tagStamp(o.now))] });
  return out;
}

// Afternoon flight update: same model, tail number and return time are the
// big items; hangar, ticket and car wash become plain lines.
function flightTagRows(r, o, fit) {
  var cols = Math.floor(TAG_READ_W / 12), half = Math.floor(cols / 2), out = [];
  var A = function(t, x){ return tagSeg(t, 'A', x); }, B = function(t, x){ return tagSeg(t, 'B', x); };
  var lines = function(t, x){ return tagWrap(t, cols).map(function(l){ return { L: [A(l, x)] }; }); };
  // fit.dense (last resort): single-height name, tighter gaps, stamp on the
  // top line. Tail and return time stay big; nothing is dropped.
  var gap = function(n){ return { feed: fit.dense ? Math.round(n / 3) : n }; };
  out.push({ L: [B(o.ascend ? 'ASCEND · FLIGHT' : 'MAKERS AIR VALET · FLIGHT', { em: 1 })], R: fit.dense ? [B(tagStamp(o.now))] : [] }, gap(8), { L: [B('TAIL')] });
  var tail = String(r.return_flight || '').trim().toUpperCase();
  if (!tail) out.push({ L: [A('NO FLIGHT YET', { w: 2, h: 2, em: 1 })] });
  else if (tail.length <= half) out.push({ L: [A(tagPadCenter(tail, half), { w: 2, h: fit.big, em: 1, rev: 1 })] });
  else out = out.concat(tagWrap(tail, cols).map(function(l){ return { L: [A(tagPadCenter(l, cols), { h: fit.big, em: 1, rev: 1 })] }; }));
  out.push(gap(8), { L: [B('RETURN')] });
  var tm = tagTime(r.departure_time), d = tagDate(r.ret);
  var dl = d ? d.label + (d.year !== o.now.getFullYear() ? ' ' + d.year : '') : 'NO DATE';
  out.push({ L: [A(tm || 'TIME TBD', { w: 2, h: fit.big, em: 1 })], R: [A(dl, { h: 2 })] });
  out.push(gap(12));
  out = out.concat(lines(((o.ascend ? '[A] ' : '') + String(r.name || '')).trim().toUpperCase(), { h: fit.dense ? 1 : 2, em: 1 }));
  var where = [String(r.loc || '').trim().toUpperCase(), r.ticket ? 'TICKET ' + r.ticket : ''].filter(Boolean).join(' · ');
  if (where) out.push({ L: [A(where)] });
  if (pickupLocation(r) === 'CUSTOMS') out.push({ L: [A('DELIVER TO CUSTOMS', { em: 1 })] });
  if (isCustomsRequestPending(r)) out = out.concat(lines('CUSTOMS REQUESTED - PENDING', { em: 1 }));
  if (TAG_WASH_TEXT[o.wash]) out.push({ L: [A('[ ' + TAG_WASH_TEXT[o.wash] + ' ]', { em: 1 })] });
  out.push(gap(8));
  var veh = [r.car, r.color].map(function(v){ return String(v || '').trim(); }).filter(Boolean).join(' · ').toUpperCase();
  if (veh) out = out.concat(lines(veh));
  if (String(r.phone || '').trim()) out.push({ L: [B(fmtP(r.phone))] });
  if (o.pickupAuth) out = out.concat(lines('AUTH PICKUP: ' + String(r.pickup_auth_name).trim().toUpperCase() + ' · CHECK ID', { em: 1 }));
  if (returnOperator(r) === 'OTHER') out = out.concat(lines('RETURNING WITH OTHER · CONFIRM', { em: 1 }));
  out = out.concat(tagObsRows(r, cols, fit.obs, A, B));
  if (!fit.dense) out.push({ feed: 8 }, { L: [B(tagStamp(o.now))] });
  return out;
}
// Notes only when there are any; past the limit say so on paper.
function tagObsRows(r, cols, max, A, B) {
  var obs = String(r.obs || '').trim().toUpperCase();
  if (!obs) return [];
  var ls = tagWrap('OBS: ' + obs, cols), out = ls.slice(0, max).map(function(l, i){ return { L: i === 0 ? [A('OBS:', { em: 1 }), A(l.slice(4))] : [A(l)] }; });
  if (ls.length > max) out.push({ L: [B('>> MORE NOTES IN AIRVALET', { em: 1 })] });
  return out;
}
// Biggest layout that fits the reading height; the last step is used anyway
// (fits:false) — nothing is ever dropped.
var KEY_COPY_FITS = [{ hangH: 3, obs: 2 }, { hangH: 2, obs: 2 }, { hangH: 2, obs: 1 }, { hangH: 2, obs: 1, dense: 1 }];
var FLIGHT_TAG_FITS = [{ big: 3, obs: 2 }, { big: 3, obs: 1 }, { big: 2, obs: 1 }, { big: 2, obs: 1, dense: 1 }];
function tagLayout(kind, r, o) {
  var steps = kind === 'flight' ? FLIGHT_TAG_FITS : KEY_COPY_FITS, rows = null;
  for (var i = 0; i < steps.length; i++) {
    rows = kind === 'flight' ? flightTagRows(r, o, steps[i]) : keyCopyRows(r, o, steps[i]);
    if (tagRowsHeight(rows) <= TAG_READ_H) return { rows: rows, fits: true };
  }
  return { rows: rows, fits: false };
}
// rows → ePOS-Print SOAP envelope (page mode, text running top_to_bottom).
function tagPageXml(rows) {
  var x = '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body>'
    + '<epos-print xmlns="http://www.epson-pos.com/schemas/2011/03/epos-print"><page>'
    + '<area x="0" y="0" width="' + TAG_READ_H + '" height="' + TAG_READ_W + '"/><direction dir="top_to_bottom"/>';
  var y = TAG_TOP;
  rows.forEach(function(l){
    if (l.feed) { y += l.feed; return; }
    var maxH = tagRowMaxH(l);
    tagPlace(l).forEach(function(p){
      var s = p[0];
      x += '<position x="' + p[1] + '" y="' + (y + maxH) + '"/>'
        + '<text font="font_' + s.font.toLowerCase() + '" width="' + s.w + '" height="' + s.h + '" em="' + s.em + '" reverse="' + s.rev + '">' + escapeHTML(s.t) + '</text>';
    });
    y += Math.max(TAG_LS, maxH);
  });
  return x + '</page><cut type="feed"/></epos-print></s:Body></s:Envelope>';
}
