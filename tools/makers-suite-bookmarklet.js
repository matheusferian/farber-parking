// "AirValet ✈︎" bookmark for Makers Air Suite (owner 2026-11-06). Source of the bookmarklet that
// tools/makers.html installs (build: node tools/build-bookmarklet.mjs → tools/makers-bookmarklet.txt).
//
// On Makers Air Suite → Schedule → Flight Schedule, one tap reads every flight that lands at FXE on
// the chosen day: flight, aircraft, arrival time and the passenger names (last / first / middle /
// first origin) exactly as Makers has them. It only READS: it never opens the flight edit form,
// it calls the schedule's own "find flight" step and downloads the flight page in the background.
// Staff then tap "Copy for AirValet" and paste in AirValet → Check Makers manifest.
// Nothing is sent anywhere by this script: the data goes to the clipboard only.
(async function () {
  if (!/makerssuite\.com$/i.test(location.hostname)) { alert('Open makerssuite.com first, then tap AirValet ✈︎.'); return; }
  if (/login/i.test(location.pathname)) { alert('Log in to Makers Air Suite first, then tap AirValet ✈︎ again.'); return; }
  if (!window.dps1 || !window.dps1.events || typeof window.eventClick !== 'function') {
    // Logged in but not on the schedule: go there; staff tap the bookmark once more.
    alert('Opening the flight schedule… When it loads, tap AirValet ✈︎ again.');
    location.href = '/ViewSchedule.aspx';
    return;
  }
  var old = document.getElementById('avxBox'); if (old) old.remove();
  var box = document.createElement('div'); box.id = 'avxBox';
  box.style.cssText = 'position:fixed;inset:auto 12px 12px 12px;z-index:2147483647;background:#fff;color:#061433;border-radius:14px;box-shadow:0 10px 40px rgba(0,0,0,.35);padding:16px;font:15px/1.4 -apple-system,Helvetica,Arial,sans-serif;max-height:80vh;overflow:auto';
  document.body.appendChild(box);
  var esc = function (s) { return String(s).replace(/[&<>"']/g, function (c) { return '&#' + c.charCodeAt(0) + ';'; }); };
  var strip = function (s) { return String(s || '').replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ').trim(); };
  var btn = 'display:block;width:100%;min-height:46px;border:0;border-radius:10px;font:700 16px -apple-system,Helvetica,Arial,sans-serif;margin-top:8px;cursor:pointer;';
  var ev = window.dps1.events.list || [];
  var days = Array.from(new Set(ev.map(function (e) { return String(e.start).slice(0, 10); }))).sort();
  var t = new Date(Date.now() + 864e5), tomorrow = t.getFullYear() + '-' + String(t.getMonth() + 1).padStart(2, '0') + '-' + String(t.getDate()).padStart(2, '0');
  var label = function (d) { var p = d.split('-'); return new Date(+p[0], +p[1] - 1, +p[2], 12).toLocaleDateString('en-US', { weekday: 'short', month: 'short', day: 'numeric' }); };

  function pick() {
    box.innerHTML = '<b style="font-size:17px">AirValet ✈︎ — which day?</b>' + days.map(function (d) {
      return '<button data-d="' + d + '" style="' + btn + (d === tomorrow ? 'background:#061433;color:#fff' : 'background:#EEF1F6;color:#061433') + '">' + esc(label(d)) + (d === tomorrow ? ' (tomorrow)' : '') + '</button>';
    }).join('') + '<button data-x="1" style="' + btn + 'background:#fff;color:#5A6B8C">Close</button>';
    box.querySelectorAll('button').forEach(function (b) { b.onclick = function () { if (b.dataset.x) box.remove(); else read(b.dataset.d); }; });
  }

  async function grab(e) {
    var cap = null, orig = window.open;
    window.open = function (u) { cap = String(u); return null; };
    try {
      window.eventClick({ id: function () { return e.id; }, data: e, text: function () { return e.text; }, tag: function (k) { return e.tag && e.tag[k]; },
        start: function () { return e.start; }, end: function () { return e.end; }, resource: function () { return e.resource; } });
    } catch (x) { /* handled below */ }
    for (var i = 0; i < 40 && !cap; i++) await new Promise(function (r) { setTimeout(r, 150); });
    window.open = orig;
    if (!cap) throw new Error('flight page not found');
    var d = new DOMParser().parseFromString(await (await fetch(cap, { credentials: 'include' })).text(), 'text/html');
    var tb = Array.from(d.querySelectorAll('table')).filter(function (x) { var h = x.querySelector('tr'); return h && /Fn Des/.test(h.textContent) && /Midd/.test(h.textContent) && !x.querySelector('table'); })[0];
    var pax = [];
    if (tb) {
      var trs = Array.from(tb.querySelectorAll('tr')), hdr = Array.from(trs[0].children).map(function (c) { return c.textContent.trim(); });
      var iL = hdr.indexOf('Last'), iF = hdr.indexOf('First'), iM = hdr.indexOf('Midd'), iO = hdr.indexOf('First Origin');
      trs.slice(1).forEach(function (tr) {
        var c = Array.from(tr.children).map(function (x) { return x.textContent.trim(); });
        if (c.length === hdr.length && c[iL]) pax.push([c[iL], c[iF] || '', c[iM] || '', c[iO] || '']);
      });
    }
    var tp = (d.body.textContent.match(/Total Pax\s*:\s*(\d+)/) || [])[1];
    var cl = d.querySelector('[id*="ClientName"]');
    return { pax: pax, total: tp ? +tp : null, client: cl && cl.value ? String(cl.value).trim() : '' };
  }

  function resName(id) {
    var stack = (window.dps1.resources || []).slice();
    while (stack.length) { var r = stack.shift(); if (String(r.id) === String(id)) return strip(r.name).replace(/\s*\(.*$/, ''); if (r.children) stack = stack.concat(r.children); }
    return '';
  }

  async function read(day) {
    var seen = {}, list = ev.filter(function (e) {
      var tx = strip(e.text), m = tx.match(/^(\S+)\s+([A-Z0-9]{3})-FXE\b.*?(\d+)\s*\/\s*\d+/);
      if (String(e.start).slice(0, 10) !== day || !m || +m[3] === 0 || seen[e.id]) return false;
      seen[e.id] = 1; return true;
    });
    if (!list.length) { box.innerHTML = '<b>No flights with passengers landing at FXE on ' + esc(label(day)) + '.</b><button data-x="1" style="' + btn + 'background:#EEF1F6;color:#061433">Close</button>'; box.querySelector('button').onclick = function () { box.remove(); }; return; }
    var flights = [], fails = 0;
    for (var i = 0; i < list.length; i++) {
      box.innerHTML = '<b>Reading flight ' + (i + 1) + ' of ' + list.length + '…</b><div style="color:#5A6B8C">Keep this page open.</div>';
      var e = list[i], tx = strip(e.text).split(' ');
      try {
        var g = await grab(e);
        flights.push({ flight: tx[0], route: tx[1], tail: resName(e.resource), arrival: String(e.end).slice(11, 16), total: g.total, client: g.client, pax: g.pax });
      } catch (x) { fails++; }
    }
    var p = day.split('-'), payload = { v: 1, date: p[1] + '/' + p[2] + '/' + p[0], flights: flights };
    var n = flights.reduce(function (a, f) { return a + f.pax.length; }, 0);
    var bad = flights.filter(function (f) { return f.total != null && f.total !== f.pax.length; }).length;
    box.innerHTML = '<b style="font-size:17px">' + esc(label(day)) + ': ' + flights.length + ' flights · ' + n + ' passengers</b>' +
      (fails || bad ? '<div style="color:#8A1C1C;margin-top:4px">' + (fails ? fails + ' flight(s) could not be read. ' : '') + (bad ? bad + ' flight(s) with a different passenger total.' : '') + '</div>' : '') +
      '<div style="color:#5A6B8C;margin:6px 0">' + flights.map(function (f) { return esc(f.flight + ' ' + f.route + ' · ' + f.tail + ' · ' + f.arrival + ' · ' + f.pax.length + ' pax'); }).join('<br>') + '</div>' +
      '<button data-c="1" style="' + btn + 'background:#1A9E6A;color:#fff;min-height:56px;font-size:18px">Copy for AirValet</button>' +
      '<button data-x="1" style="' + btn + 'background:#EEF1F6;color:#061433">Close</button>' + (days.length > 1 ? '<button data-o="1" style="' + btn + 'background:#fff;color:#5A6B8C;font-weight:600">Other day</button>' : '');
    var txt = 'AIRVALET-MAKERS:' + JSON.stringify(payload);
    box.querySelector('[data-x]').onclick = function () { box.remove(); };
    var oth = box.querySelector('[data-o]'); if (oth) oth.onclick = pick;
    box.querySelector('[data-c]').onclick = async function () {
      var ok = false;
      try { await navigator.clipboard.writeText(txt); ok = true; } catch (x) {
        var ta = document.createElement('textarea'); ta.value = txt; ta.setAttribute('readonly', ''); ta.style.cssText = 'position:fixed;top:0;left:0;opacity:0';
        document.body.appendChild(ta); ta.select(); ta.setSelectionRange(0, txt.length); try { ok = document.execCommand('copy'); } catch (y) { ok = false; } ta.remove();
      }
      this.textContent = ok ? 'Copied ✓ — now open AirValet' : 'Copy failed — try again';
      if (ok) box.insertAdjacentHTML('beforeend', '<div style="margin-top:10px;font-size:16px">Now open <b>AirValet</b> → <b>Check Makers manifest</b> → <b>Paste from Makers Suite</b>.</div>');
    };
  }
  // Tomorrow is what staff need every day: read it straight away; other days only if tomorrow is not on screen.
  if (days.indexOf(tomorrow) >= 0) read(tomorrow); else pick();
})();
