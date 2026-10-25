// Makers Air Valet passenger portal — plain JS, no framework, no cookies.
// Data: POST { t } → valet-pass. Requests: POST { t, action: 'request', … }.
// Every request is a REQUEST: the team confirms; nothing changes on its own.
(function () {
  'use strict';
  var API = (document.querySelector('meta[name="airvalet-pass-api"]') || {}).content || '';
  var TOKEN = String(location.hash || '').replace(/^#/, '');
  var app = document.getElementById('app');
  var sheetBg = document.getElementById('sheetBg');
  var sheet = document.getElementById('sheet');
  var pass = null;
  var lastFocus = null;
  var form = {};           // current sheet state
  var VALET_PHONE_FALLBACK = '(954) 352-1010'; // printed on the customer ticket

  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }
  function tel(p) { return 'tel:' + String(p || '').replace(/[^0-9+]/g, ''); }
  function sms(p) { return 'sms:' + String(p || '').replace(/[^0-9+]/g, ''); }
  function clientKey() {
    var b = new Uint8Array(18); crypto.getRandomValues(b);
    return btoa(String.fromCharCode.apply(null, b)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  }
  function fmtDate(ret) {
    var m = /^(\d{1,2})\/(\d{1,2})\/(\d{4})$/.exec(String(ret || ''));
    if (!m) return null;
    var d = new Date(+m[3], +m[1] - 1, +m[2], 12);
    return d.toLocaleDateString('en-US', { weekday: 'short', month: 'short', day: 'numeric' });
  }
  function fmtIsoDate(iso) {
    var m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(String(iso || ''));
    if (!m) return null;
    return new Date(+m[1], +m[2] - 1, +m[3], 12).toLocaleDateString('en-US', { weekday: 'short', month: 'short', day: 'numeric' });
  }
  function fmtTime(t) {
    var m = /^(\d{2}):(\d{2})/.exec(String(t || ''));
    if (!m) return null;
    var h = +m[1];
    return ((h + 11) % 12 + 1) + ':' + m[2] + ' ' + (h < 12 ? 'AM' : 'PM');
  }
  function todayIso() {
    var d = new Date(); var z = function (n) { return (n < 10 ? '0' : '') + n; };
    return d.getFullYear() + '-' + z(d.getMonth() + 1) + '-' + z(d.getDate());
  }
  function hoursText(h) {
    if (!h || typeof h !== 'object') return '';
    var days = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];
    var vals = days.map(function (d) { return Array.isArray(h[d]) && h[d].length === 2 ? fmtTime(h[d][0]) + ' – ' + fmtTime(h[d][1]) : null; });
    if (vals.every(function (v) { return v === null; })) return '';
    if (vals.every(function (v) { return v === vals[0]; })) return 'Valet hours: ' + vals[0] + ', daily';
    var names = { mon: 'Mon', tue: 'Tue', wed: 'Wed', thu: 'Thu', fri: 'Fri', sat: 'Sat', sun: 'Sun' };
    return 'Valet hours: ' + days.map(function (d, i) { return names[d] + ' ' + (vals[i] || 'closed'); }).join(' · ');
  }

  async function post(body) {
    var res = await fetch(API, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body), cache: 'no-store', credentials: 'omit', referrerPolicy: 'no-referrer' });
    var data = null; try { data = await res.json(); } catch (e) { data = null; }
    return { status: res.status, data: data };
  }

  async function load() {
    try {
      var r = await post({ t: TOKEN });
      if (r.status === 429) return renderMessage('Too many attempts', 'Please wait a few minutes and try again.');
      if (!r.data || r.data.state === 'error') return renderMessage('Something went wrong', 'Please try again in a moment.', true);
      if (r.data.state !== 'ok') return renderMessage('This valet link is not active', 'Questions about your car? Call our valet team at ' + VALET_PHONE_FALLBACK + '.');
      pass = r.data.pass;
      render();
    } catch (e) {
      renderMessage('No connection', 'Check your connection and try again.', true);
    }
  }

  function renderMessage(title, text, retry) {
    app.innerHTML = '<div class="center"><img src="assets/makers-valet-badge.png" alt="Makers Air Valet" width="64" height="64">' +
      '<h2>' + esc(title) + '</h2><p class="muted">' + esc(text) + '</p>' +
      (retry ? '<button class="btn quiet" type="button" id="retry">Try again</button>' : '') + '</div>';
    var b = document.getElementById('retry'); if (b) b.addEventListener('click', load);
  }

  function statusCard(p) {
    var cls = 'status', big = 'Parked', line = 'Your car is safely parked.', extra = '';
    if (p.status === 'READY') {
      cls += ' ready'; big = 'Ready to Go'; line = 'Your car is ready for your arrival.';
      if (p.pickup === 'HANGAR_19') {
        extra = '<p class="lbl mt">Waiting for you at</p><p class="place">Hangar 19</p>' +
          (p.lockbox ? '<p class="perk">After-hours pickup confirmed by our team.</p>' : '<p class="perk">A/C running. We will help with your luggage.</p>');
      }
    } else if (p.status === 'CUSTOMS_CONFIRMED') {
      cls += ' customs'; big = 'Customs Confirmed';
      line = p.pickup === 'CUSTOMS_ASCEND'
        ? 'Your vehicle will be at Customs. An Ascend team member will hand you your key.'
        : 'As arranged, your vehicle will be at Customs. When you arrive, reply to our text or call ' + esc(contactValet(p)) + ' for your key.';
    } else if (p.status === 'DELIVERED') {
      cls += ' done'; big = 'Delivered'; line = 'Thank you for choosing Makers Air Valet. We look forward to your next trip.';
    }
    return '<section class="' + cls + '" aria-label="Vehicle status">' +
      '<p class="lbl">Your vehicle' + (p.vehicle ? ' · ' + esc(niceVehicle(p.vehicle)) : '') + '</p>' +
      '<p class="big">' + esc(big) + '</p><p class="line">' + line + '</p>' + extra + '</section>';
  }
  function contactValet(p) { return (p.contacts && p.contacts.valet_phone) || VALET_PHONE_FALLBACK; }
  // "Black MERCEDES GLE" → "Black Mercedes GLE" (short / numbered model codes stay upper case).
  function niceVehicle(v) {
    return String(v || '').split(/\s+/).map(function (w) {
      return /\d/.test(w) || w.length <= 3 ? w.toUpperCase() : w.charAt(0).toUpperCase() + w.slice(1).toLowerCase();
    }).join(' ');
  }

  function pickupBlock(p) {
    if (p.status === 'DELIVERED') return '';
    if (p.pickup === 'HANGAR_19') {
      return '<section class="card" aria-label="Getting to your car"><p class="lbl">Getting to your car</p><ol class="steps mt">' +
        '<li><span class="n">1</span>Land with Makers Air</li><li><span class="n">2</span>Complete Customs</li>' +
        '<li><span class="n">3</span>Go back to your pilots and aircraft</li><li class="last"><span class="n">4</span><strong>Hangar 19</strong></li></ol></section>';
    }
    if (p.pickup === 'TO_BE_CONFIRMED') return '<section class="card"><p class="lbl">Pickup</p><p class="ptext">Our team will confirm your pickup details before your return.</p></section>';
    if (p.pickup === 'OTHER') return '<section class="card"><p class="lbl">Pickup</p><p class="ptext">Please let our valet team know when you will arrive, and we will have your car ready.</p></section>';
    if ((p.pickup === 'CUSTOMS_EXCEPTION' || p.pickup === 'CUSTOMS_ASCEND') && p.status === 'PARKED') {
      return '<section class="card"><p class="lbl">Pickup</p><p class="ptext">Customs. Our team will confirm when your vehicle is ready.</p></section>';
    }
    return '';
  }

  function render() {
    var p = pass;
    var name = p.first_name ? 'Welcome, ' + esc(p.first_name) : 'Welcome';
    var date = fmtDate(p.return_date), time = fmtTime(p.return_time);
    var retText = date ? date + (time ? ' · ' + time : '') : 'Not set yet';
    var pend = p.pending_return;
    var html = '<header class="top"><img src="assets/makers-valet-lockup-white.png" alt="Makers Air Valet by Farber Parking" width="200" height="64">' +
      '<h1>' + name + '</h1></header><main>';
    html += statusCard(p) + pickupBlock(p);
    if (p.lockbox && p.status !== 'DELIVERED') {
      html += '<button class="btn primary green" type="button" data-open="lockbox">View after-hours pickup instructions</button>';
    }
    if (p.status !== 'DELIVERED') {
      html += '<section class="card" aria-label="Expected return"><div class="row"><div><p class="lbl">Expected return</p><p class="ret">' + esc(retText) + '</p></div>' +
        (p.requests_enabled ? '<button class="btn outline" type="button" data-open="return">Change return</button>' : '') + '</div>' +
        (pend ? '<p class="pending">Change requested: ' + esc(fmtIsoDate(pend.date) || '') + (pend.time ? ' · ' + esc(fmtTime(pend.time)) : '') +
          (pend.carrier ? ' with ' + esc(pend.carrier) : '') + '. Waiting for our team to confirm.</p>' : '') + '</section>';
    }
    var rows = '';
    var wash = { REQUEST: 'Request', CONTACT: 'Ask our team', REQUESTED: 'Requested', PRICE_PENDING: 'Price coming', SCHEDULED: 'Scheduled', DONE: 'Done' }[p.car_wash];
    if (wash && p.requests_enabled !== false) rows += '<button type="button" data-open="wash"><span>Car wash</span><small>' + wash + '</small></button>';
    if (p.gratuity_url) rows += '<button type="button" data-open="gratuity"><span>Gratuity</span><small>Optional</small></button>';
    if (rows) html += '<div class="list">' + rows + '</div>';
    var c = p.contacts || {};
    html += '<section aria-label="Contact our team"><p class="lbl sec">Contact our team</p><div class="contacts">' +
      '<a href="' + esc(tel(contactValet(p))) + '"><strong>Call valet</strong><span>' + esc(contactValet(p)) + '</span></a>' +
      (c.text_phone ? '<a href="' + esc(sms(c.text_phone)) + '"><strong>Text valet</strong><span>Or reply to our text</span></a>' : '') +
      '</div>' + (c.reservations_phone ? '<p class="muted note">Flights and reservations: <a href="' + esc(tel(c.reservations_phone)) + '">Makers Air ' + esc(c.reservations_phone) + '</a></p>' : '') +
      (hoursText(p.valet_hours) ? '<p class="muted note">' + esc(hoursText(p.valet_hours)) + '</p>' : '') + '</section>';
    html += '<footer><img src="assets/makers-valet-badge.png" alt="" width="44" height="44"><p>Complimentary valet service for Makers Air passengers' +
      (p.terms_published ? ' · <a href="terms.html">Valet Terms</a>' : '') + '</p>' +
      '<p>Makers Air Valet · Hangar 19 · 2331 NW 55th Court, Fort Lauderdale, FL 33309</p>' +
      '<p><a href="sms.html">SMS program</a> · <a href="privacy.html">Privacy</a></p></footer></main>';
    app.innerHTML = html;
    Array.prototype.forEach.call(app.querySelectorAll('[data-open]'), function (b) {
      b.addEventListener('click', function () { openSheet(b.getAttribute('data-open')); });
    });
  }

  // ── Sheets ──
  function openSheet(kind) {
    lastFocus = document.activeElement;
    form = { kind: kind, step: 1, ck: clientKey() };
    drawSheet();
    sheetBg.hidden = false;
    var f = sheet.querySelector('button, input, a'); if (f) f.focus();
  }
  function closeSheet() { sheetBg.hidden = true; sheet.innerHTML = ''; if (lastFocus && lastFocus.focus) lastFocus.focus(); }
  sheetBg.addEventListener('click', function (e) { if (e.target === sheetBg) closeSheet(); });
  document.addEventListener('keydown', function (e) { if (e.key === 'Escape' && !sheetBg.hidden) closeSheet(); });

  var REASONS = [
    ['NEW_DATE_TIME', 'New date or time'],
    ['FLIGHT_CHANGED', 'My flight changed'],
    ['OTHER_CARRIER', 'Returning with another airline or company'],
    ['AFTER_HOURS', 'Arriving after valet hours'],
  ];
  function head(title) { return '<div class="head"><h2 id="sheetTitle">' + esc(title) + '</h2><button class="x" type="button" data-close aria-label="Close">✕</button></div>'; }

  function drawSheet() {
    var p = pass, h = '';
    if (form.kind === 'return') {
      h = head('Change return');
      if (form.step === 1) {
        h += '<p class="muted">Now on file: ' + esc((fmtDate(p.return_date) || 'not set') + (fmtTime(p.return_time) ? ' · ' + fmtTime(p.return_time) : '')) + '. What changed?</p>';
        REASONS.forEach(function (r) { h += '<button class="choice" type="button" data-reason="' + r[0] + '">' + esc(r[1]) + '</button>'; });
      } else if (form.step === 2) {
        h += '<div class="two"><label class="f">New date<input type="date" id="fDate" min="' + todayIso() + '" value="' + esc(form.date || '') + '" required></label>' +
          '<label class="f">Landing time <span class="muted">(optional)</span><input type="time" id="fTime" value="' + esc(form.time || '') + '"></label></div>';
        if (form.reason === 'OTHER_CARRIER') h += '<label class="f">Airline or company<input type="text" id="fCarrier" maxlength="40" autocomplete="off" value="' + esc(form.carrier || '') + '"></label>';
        h += '<label class="f">Note <span class="muted">(optional)</span><textarea id="fNote" maxlength="280">' + esc(form.note || '') + '</textarea></label>' +
          (form.err ? '<p class="err" role="alert">' + esc(form.err) + '</p>' : '') +
          '<div class="actions"><button class="btn quiet" type="button" data-back>Back</button><button class="btn primary" type="button" data-review>Review</button></div>';
      } else if (form.step === 3) {
        var reasonText = (REASONS.filter(function (r) { return r[0] === form.reason; })[0] || [])[1] || '';
        h += '<div class="review"><strong>Please review</strong><br>' + esc(reasonText) + '<br>New return: ' + esc(fmtIsoDate(form.date)) + (form.time ? ' · ' + esc(fmtTime(form.time)) : '') +
          (form.carrier ? '<br>With: ' + esc(form.carrier) : '') + (form.note ? '<br>Note: ' + esc(form.note) : '') + '</div>' +
          '<p class="muted">This does not change your Makers Air flight. Our valet team will confirm.</p>' +
          (form.err ? '<p class="err" role="alert">' + esc(form.err) + '</p>' : '') +
          '<div class="actions"><button class="btn quiet" type="button" data-edit>Edit</button><button class="btn primary" type="button" data-send' + (form.busy ? ' disabled' : '') + '>' + (form.busy ? 'Sending…' : 'Send request') + '</button></div>';
      } else {
        h += '<div class="okbox"><strong>Request sent</strong><br>Our valet team has your update and will confirm shortly. Your current return stays on file until then.</div>' +
          '<button class="btn primary" type="button" data-close>Done</button>';
      }
    } else if (form.kind === 'wash') {
      h = head('Car wash');
      var lead = p.car_wash_lead_hours || 48;
      if (form.step === 9) {
        h += '<div class="okbox"><strong>Request sent</strong><br>Our team will confirm the price and availability by text. Nothing is charged now.</div><button class="btn primary" type="button" data-close>Done</button>';
      } else if (p.car_wash === 'REQUEST') {
        h += '<p class="p0">Washed and ready before you return?</p><div class="okbox">Car wash requests made at least ' + lead + ' hours before your return can be scheduled, subject to confirmation.</div>' +
          '<p class="muted">Our team confirms the price and availability before washing. Nothing is charged now.</p>' +
          (form.err ? '<p class="err" role="alert">' + esc(form.err) + '</p>' : '') +
          '<button class="btn primary" type="button" data-wash' + (form.busy ? ' disabled' : '') + '>' + (form.busy ? 'Sending…' : 'Request car wash') + '</button>';
      } else if (p.car_wash === 'CONTACT') {
        h += '<div class="warnbox">Your return is less than ' + lead + ' hours away. Please contact our valet team to check availability.</div>' +
          '<a class="btn primary" href="' + esc(tel(contactValet(p))) + '">Call valet ' + esc(contactValet(p)) + '</a>';
      } else {
        var t = { REQUESTED: 'Request received. Our team will confirm the price and availability by text.', PRICE_PENDING: 'Our team will text you the price shortly.',
          SCHEDULED: 'Your car wash is scheduled before your return.', DONE: 'Your car has been washed.' }[p.car_wash] || '';
        h += '<div class="okbox">' + esc(t) + '</div><button class="btn primary" type="button" data-close>Done</button>';
      }
    } else if (form.kind === 'gratuity') {
      h = head('Gratuity') + '<p class="p0">For the valet team. Always optional, and appreciated either way.</p>' +
        '<a class="btn primary" href="' + esc(p.gratuity_url) + '" target="_blank" rel="noopener noreferrer">Continue to secure payment</a>' +
        '<p class="muted">Secure payment by Stripe · Matt Solutions &amp; Services. You choose the amount.</p>';
    } else if (form.kind === 'lockbox') {
      var lb = p.lockbox || {};
      h = head('After-hours pickup') + '<ol class="steps"><li><span class="n">1</span>After Customs, go back to your pilots</li><li><span class="n">2</span>Walk to Hangar 19</li><li class="last"><span class="n">3</span>Open the lockbox with your code</li></ol>' +
        (lb.code ? '<div class="review">Lockbox code<br><span class="code">' + esc(lb.code) + '</span></div>'
                 : '<div class="review">Your lockbox code appears here on your return day' + (lb.reveal_on ? ' (' + esc(fmtIsoDate(lb.reveal_on)) + ')' : '') + '.</div>') +
        '<p class="muted">Questions? Call ' + esc(contactValet(p)) + '.</p>';
    }
    sheet.innerHTML = h;
    wire();
  }

  function wire() {
    function on(sel, fn) { Array.prototype.forEach.call(sheet.querySelectorAll(sel), function (el) { el.addEventListener('click', fn); }); }
    on('[data-close]', closeSheet);
    on('[data-reason]', function (e) { form.reason = e.currentTarget.getAttribute('data-reason'); form.step = 2; form.err = null; drawSheet(); });
    on('[data-back]', function () { keep(); form.step = 1; form.err = null; drawSheet(); });
    on('[data-edit]', function () { form.step = 2; form.err = null; drawSheet(); });
    on('[data-review]', function () {
      keep();
      if (!form.date || form.date < todayIso()) { form.err = 'Please choose your new return date.'; return drawSheet(); }
      if (form.reason === 'OTHER_CARRIER' && (!form.carrier || form.carrier.trim().length < 2)) { form.err = 'Please enter the airline or company.'; return drawSheet(); }
      form.err = null; form.step = 3; drawSheet();
    });
    on('[data-send]', function () { sendRequest({ kind: 'RETURN_CHANGE', reason: form.reason, date: form.date, time: form.time || null, carrier: form.carrier || null, note: form.note || null }, 4); });
    on('[data-wash]', function () { sendRequest({ kind: 'CAR_WASH' }, 9); });
  }
  function keep() {
    var d = document.getElementById('fDate'), t = document.getElementById('fTime'), c = document.getElementById('fCarrier'), n = document.getElementById('fNote');
    if (d) form.date = d.value; if (t) form.time = t.value; if (c) form.carrier = c.value; if (n) form.note = n.value;
  }

  async function sendRequest(body, doneStep) {
    if (form.busy) return;
    form.busy = true; form.err = null; drawSheet();
    try {
      // Same client key on every retry of this sheet → never two requests.
      var r = await post(Object.assign({ t: TOKEN, action: 'request', ck: form.ck }, body));
      form.busy = false;
      var res = r.data && r.data.result;
      if (r.status === 429) { form.err = 'Too many attempts. Please try again in a few minutes.'; return drawSheet(); }
      if (!r.data || r.data.state === 'error') { form.err = 'Could not send. Please try again.'; return drawSheet(); }
      if (r.data.state !== 'ok') { closeSheet(); return load(); }
      if (res === 'OK') { form.step = doneStep; drawSheet(); load(); return; }
      if (res === 'CONTACT_TEAM') { await load(); form.step = 1; return drawSheet(); }
      form.err = { INVALID: 'Please check the details and try again.', LIMITED: 'Too many requests today. Please call our valet team.',
        NOT_AVAILABLE: 'This is not available right now. Please contact our valet team.', NOT_IN_CUSTODY: 'This pass is read-only now.',
        UNAVAILABLE: 'Requests are not available right now. Please contact our valet team.' }[res] || 'Could not send. Please try again.';
      drawSheet();
    } catch (e) {
      form.busy = false; form.err = 'No connection. Your request was not sent yet; please try again.'; drawSheet();
    }
  }

  // A different link opened in the same tab: show that pass, never the previous one.
  window.addEventListener('hashchange', function () {
    TOKEN = String(location.hash || '').replace(/^#/, ''); pass = null;
    if (!sheetBg.hidden) closeSheet();
    app.innerHTML = '<div class="center"><p class="muted">Loading your valet pass…</p></div>';
    load();
  });
  document.addEventListener('visibilitychange', function () { if (!document.hidden && pass && sheetBg.hidden) load(); });
  setInterval(function () { if (!document.hidden && pass && sheetBg.hidden) load(); }, 60000);
  load();
})();
