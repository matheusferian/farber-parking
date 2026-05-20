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

// ── STRING HELPERS ─────────────────────────────────────────────
function fuzzyMatch(a, b) {
  a = a.toUpperCase().trim(); b = b.toUpperCase().trim();
  if(a===b) return true;
  var ap=a.split(' '), bp=b.split(' ');
  var matches=0;
  ap.forEach(function(p){if(p.length>1&&bp.some(function(q){return q.indexOf(p)>=0||p.indexOf(q)>=0;}))matches++;});
  return matches>=Math.min(ap.length,bp.length)&&matches>0;
}
