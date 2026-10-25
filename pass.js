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
  // Intro film (cine/cinematic-v1.js): one switch; false = never plays.
  var CINEMATIC_ON = true, CINEMATIC_VERSION = 'p3', cineTried = false;

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
    var m = /^(\d{1,2}):(\d{2})/.exec(String(t || ''));
    if (!m) return null;
    var h = +m[1];
    return ((h + 11) % 12 + 1) + ':' + m[2] + ' ' + (h < 12 ? 'AM' : 'PM');
  }
  // The valet works on Florida time: "today" is the ET date, whatever the phone's zone.
  function todayIso() {
    try { return new Intl.DateTimeFormat('en-CA', { timeZone: 'America/New_York', year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date()); }
    catch (e) {
      var d = new Date(); var z = function (n) { return (n < 10 ? '0' : '') + n; };
      return d.getFullYear() + '-' + z(d.getMonth() + 1) + '-' + z(d.getDate());
    }
  }
  function hoursText(h) {
    if (!h || typeof h !== 'object') return '';
    var days = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];
    var vals = days.map(function (d) { return Array.isArray(h[d]) && h[d].length === 2 ? fmtTime(h[d][0]) + ' – ' + fmtTime(h[d][1]) : null; });
    if (vals.every(function (v) { return v === null; })) return '';
    // Times never break inside ("5:30 PM" stays on one line).
    if (vals.every(function (v) { return v === vals[0]; })) return 'Open every day, ' + vals[0].replace(' – ', ' to ').replace(/ (AM|PM)/g, '\u00a0$1');
    var names = { mon: 'Mon', tue: 'Tue', wed: 'Wed', thu: 'Thu', fri: 'Fri', sat: 'Sat', sun: 'Sun' };
    return 'Valet hours: ' + days.map(function (d, i) { return names[d] + ' ' + (vals[i] || 'closed'); }).join(' · ');
  }

  async function post(body) {
    var res = await fetch(API, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body), cache: 'no-store', credentials: 'omit', referrerPolicy: 'no-referrer' });
    var data = null; try { data = await res.json(); } catch (e) { data = null; }
    return { status: res.status, data: data };
  }

  async function load() {
    var r;
    try { r = await post({ t: TOKEN }); } catch (e) { r = null; }
    if (r && r.data && r.data.state === 'ok') {
      pass = r.data.pass; lastOk = new Date();
      render();
      startIntro();
      return;
    }
    if (r && r.data && r.data.state && r.data.state !== 'error' && r.status !== 429 && r.data.state !== 'limited') {
      // Link revoked or expired: stop refreshing (a forgotten tab must not count failures).
      pass = null;
      return renderMessage('This valet link is not active', 'Questions about your car? Call our valet team at ' + VALET_PHONE_FALLBACK + '.');
    }
    // Temporary problem: an open pass stays on screen with a quiet note.
    if (pass) return showStale(!r ? 'Offline' : 'Could not refresh');
    if (!r) return renderMessage('No connection', 'Check your connection and try again.', true);
    if (r.status === 429 || (r.data && r.data.state === 'limited')) return renderMessage('Too many attempts', 'Please wait a few minutes and try again.', true);
    renderMessage('Something went wrong', 'Please try again in a moment.', true);
  }
  var lastOk = null;
  function showStale(what) {
    var el = document.getElementById('stale');
    if (!el) { el = document.createElement('p'); el.id = 'stale'; el.className = 'stale'; el.setAttribute('role', 'status'); var host = app.querySelector('main') || app; host.insertBefore(el, host.firstChild); }
    el.textContent = what + (lastOk ? ' \u2014 last updated ' + lastOk.toLocaleTimeString('en-US', { hour: 'numeric', minute: '2-digit' }) : '') + '.';
  }

  // At most once per page load (the 30 s refresh never replays it); the film
  // itself plays only the first time this link is opened on the device.
  function startIntro() {
    if (cineTried || !CINEMATIC_ON || !window.MAVCinematic || !pass) return;
    cineTried = true;
    var kind = pass.status === 'DELIVERED' ? null
      : (pass.status === 'READY' || pass.status === 'CUSTOMS_CONFIRMED' || isReturning(pass)) ? 'RETURN' : 'DEPARTURE';
    if (kind) window.MAVCinematic.start({ kind: kind, v: CINEMATIC_VERSION }, TOKEN, 'cine/');
  }

  function renderMessage(title, text, retry) {
    app.innerHTML = '<div class="center"><img src="assets/makers-valet-badge.png" alt="Makers Air Valet" width="64" height="64">' +
      '<h2>' + esc(title) + '</h2><p class="muted">' + esc(text) + '</p>' +
      (retry ? '<button class="btn quiet" type="button" id="retry">Try again</button>' : '') + '</div>';
    var b = document.getElementById('retry'); if (b) b.addEventListener('click', load);
  }

  // ── Valet pass (boarding-pass layout, 2026-10-25) ──
  function statusInfo(p) {
    if (p.status === 'READY') {
      return { tone: 'ready', word: 'Ready',
        line: p.pickup === 'HANGAR_19'
          ? (p.lockbox ? 'After-hours pickup confirmed by our team.'
            : p.ready_by_staff === false ? 'Your car is at Hangar\u00a019 for your return today.'
            : 'A/C running. We will help with your luggage.')
          : 'Your car is ready for your arrival.' };
    }
    if (p.status === 'CUSTOMS_CONFIRMED') {
      return { tone: 'customs', word: 'At Customs',
        line: p.pickup === 'CUSTOMS_ASCEND'
          ? 'An Ascend team member will hand you your key.'
          : 'As arranged, your car will be at Customs. When you arrive, reply to our text or call ' + esc(contactValet(p)) + ' for your key.' };
    }
    if (p.status === 'DELIVERED') return { tone: 'done', word: 'Delivered', line: 'Thank you for choosing Makers Air Valet.' };
    // Staff filled the return flight / arrival time: the guest is on the way back
    // (owner 2026-10-25). "Ready" is still set by staff only.
    if (isReturning(p)) {
      return { tone: 'returning', word: 'Flying back',
        line: p.pickup === 'HANGAR_19' ? 'Fly safe. We\u2019ll be waiting at Hangar\u00a019 and help with your luggage.' : 'Fly safe. We\u2019ll be waiting for you and help with your luggage.' };
    }
    return { tone: 'parked', word: 'Parked', line: 'Your car is safely parked.' };
  }
  function contactValet(p) { return (p.contacts && p.contacts.valet_phone) || VALET_PHONE_FALLBACK; }
  function isReturning(p) { return (p.status === 'PARKED' || !p.status) && !!(p.return_flight || p.arrival_time); }
  // "Black MERCEDES GLE" → "Black Mercedes GLE" (short / numbered model codes stay upper case).
  function niceVehicle(v) {
    return String(v || '').split(/\s+/).map(function (w) {
      return /\d/.test(w) || w.length <= 3 ? w.toUpperCase() : w.charAt(0).toUpperCase() + w.slice(1).toLowerCase();
    }).join(' ');
  }
  function pickupText(p) {
    if (p.status === 'CUSTOMS_CONFIRMED') return 'Customs';
    if (p.pickup === 'HANGAR_19') return 'Hangar 19';
    if (p.pickup === 'CUSTOMS_EXCEPTION' || p.pickup === 'CUSTOMS_ASCEND') return 'Customs';
    return '';
  }

  function passCard(p) {
    var st = statusInfo(p), done = p.status === 'DELIVERED';
    var html = '<section class="pass tone-' + st.tone + '" aria-label="Your valet pass">' +
      '<div class="pass-top">' +
        '<p class="pass-car">' + (p.vehicle ? esc(niceVehicle(p.vehicle)) : 'Vehicle details will be updated soon.') + '</p>' +
        '<p class="pass-status">' + esc(st.word) + '</p>' +
        '<p class="pass-line">' + st.line + '</p>' +
      '</div><div class="pass-tear" aria-hidden="true"></div><div class="pass-bottom">';
    if (done) {
      html += '<p class="k">A note from your valet team</p>' +
        '<p class="note-text">Thank you for trusting us with your car' + (p.first_name ? ', ' + esc(p.first_name) : '') + '. It was a pleasure taking care of it. Safe travels, and see you on your next trip!</p>' +
        (p.gratuity_url ? '<button class="btn brass" type="button" data-open="gratuity">Leave a gratuity for the team</button><p class="fine">Always optional.</p>' : '');
      return html + '</div></section>';
    }
    var date = fmtDate(p.return_date), time = fmtTime(p.return_time), place = pickupText(p);
    var steps = p.pickup === 'HANGAR_19' && p.status === 'PARKED';
    html += '<div class="pass-grid">' +
      '<div><p class="k">Pickup</p><p class="v' + (place ? '' : ' v-soft') + '">' + (place ? esc(place) : 'To be confirmed by our valet team.') + '</p>' +
        (steps ? '<button class="link" type="button" id="howBtn" aria-expanded="false" aria-controls="howSteps">How to get there</button>' : '') + '</div>' +
      '<div><p class="k">Return</p><p class="v' + (date ? '' : ' v-soft') + '">' + (date ? esc(date) : 'Not available yet.') + '</p>' +
        (date && time && !p.arrival_time ? '<p class="v2">' + esc(time) + '</p>' : '') +
        (p.requests_enabled ? '<button class="link" type="button" data-open="return">Change return</button>' : '') + '</div>' +
      '</div>';
    // Return flight + arrival time, once staff fill them on the car card.
    var arr = fmtTime(p.arrival_time);
    if (p.return_flight || arr) {
      html += '<div class="pass-grid flight">' +
        '<div><p class="k">Flight</p><p class="v">' + (p.return_flight ? esc(p.return_flight) : '<span class="v-soft">To be confirmed</span>') + '</p></div>' +
        '<div><p class="k">Arrives</p><p class="v">' + (arr ? esc(arr) : '<span class="v-soft">To be confirmed</span>') + '</p></div></div>';
    }
    if (steps) {
      html += '<ol class="steps howto" id="howSteps" hidden>' +
        '<li>Land with Makers Air</li><li>Complete Customs</li><li>Go back to your pilots and aircraft</li><li><strong>Walk to Hangar 19</strong></li></ol>';
    }
    var pend = p.pending_return;
    if (pend) html += '<p class="pending">Change requested: ' + esc(fmtIsoDate(pend.date) || '') + (pend.time ? ', ' + esc(fmtTime(pend.time)) : '') +
      (pend.carrier ? ' with ' + esc(pend.carrier) : '') + '. Waiting for our team to confirm.</p>';
    return html + '</div></section>';
  }

  function render() {
    var p = pass, done = p.status === 'DELIVERED';
    var html = '<header class="top"><img src="assets/makers-air-valet-lockup-white.png" alt="Makers Air Valet" width="200" height="52">' +
      '<h1>' + (p.first_name ? 'Welcome, ' + esc(p.first_name) : 'Welcome') + '</h1></header><main>';
    html += passCard(p);
    if (p.lockbox && !done && p.status !== 'CUSTOMS_CONFIRMED') html += '<button class="btn primary green" type="button" data-open="lockbox">View after-hours pickup instructions</button>';
    if (p.chat_enabled) html += '<button class="btn primary" type="button" data-open="chat">Message our valet team</button>';
    // Gratuity as a full button too (owner 2026-10-25); after delivery it lives in the pass card.
    if (!done && p.gratuity_url) html += '<button class="btn brass solo" type="button" data-open="gratuity">Leave a gratuity</button>';
    var rows = '';
    var wash = { REQUEST: 'Request', CONTACT: 'Ask our team', REQUESTED: 'Requested', PRICE_PENDING: 'Price coming', SCHEDULED: 'Scheduled', DONE: 'Done' }[p.car_wash];
    if (!done && wash && p.requests_enabled !== false) rows += '<button type="button" data-open="wash"><span>Car wash</span><small>' + wash + '</small></button>';
    if (rows) html += '<div class="list">' + rows + '</div>';
    var c = p.contacts || {};
    // Valet hours + the after-hours rule (owner 2026-10-25).
    var hrs = hoursText(p.valet_hours);
    if (hrs && !done) html += '<section class="hours" aria-label="Valet hours"><p class="k">Valet hours</p><p class="hours-t">' + esc(hrs) + '</p>' +
      '<p class="fine">Flying back with Makers Air? Don\u2019t worry, we\u2019ll be here to meet you.</p>' +
      '<p class="fine">Arriving after hours without letting us know? We can\u2019t guarantee your car will be ready.</p></section>';
    html += '<p class="contact-line">Questions? <a href="' + esc(tel(contactValet(p))) + '">Call ' + esc(contactValet(p)) + '</a></p>' +
      (c.reservations_phone ? '<p class="fine">Flights: <a href="' + esc(tel(c.reservations_phone)) + '">Makers Air ' + esc(c.reservations_phone) + '</a></p>' : '');
    // Operator credit (owner 2026-10-25): Farber Parking badge + office phone in the footer only.
    html += '<footer><div class="operator"><img src="assets/farber-parking-badge.png" alt="Farber Parking" width="44" height="44">' +
      '<div><p>Operated by Farber Parking</p><p><a href="tel:+15617740494">(561) 774-0494</a></p></div></div>' +
      '<p>Makers Air Valet, Hangar 19, Fort Lauderdale' + (p.terms_published ? ' · <a href="terms.html">Valet Terms</a>' : '') + '</p>' +
      '<p><a href="sms.html">SMS program</a> · <a href="privacy.html">Privacy</a></p></footer></main>';
    app.innerHTML = html;
    Array.prototype.forEach.call(app.querySelectorAll('[data-open]'), function (b) {
      b.addEventListener('click', function () { openSheet(b.getAttribute('data-open')); });
    });
    var how = document.getElementById('howBtn'), list = document.getElementById('howSteps');
    if (how && list) how.addEventListener('click', function () {
      var open = list.hidden; list.hidden = !open; how.setAttribute('aria-expanded', String(open));
      how.textContent = open ? 'Hide directions' : 'How to get there';
    });
  }

  // ── Sheets ──
  function openSheet(kind) {
    lastFocus = document.activeElement;
    form = { kind: kind, step: 1, ck: clientKey() };
    drawSheet();
    if (kind === 'chat') { loadChat(); chatTimer = setInterval(function () { if (!document.hidden) loadChat(); }, 15000); }  // ~40 calls/10 min, well under the server brake
    sheetBg.hidden = false;
    var f = sheet.querySelector('button, input, a'); if (f) f.focus();
  }
  function closeSheet() {
    if (chatTimer) { clearInterval(chatTimer); chatTimer = null; }
    sheetBg.hidden = true; sheet.innerHTML = ''; if (lastFocus && lastFocus.focus) lastFocus.focus();
  }
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
    } else if (form.kind === 'chat') {
      h = head('Valet team') + '<div class="chat" id="chatList" aria-live="polite">' + chatHtml() + '</div>' +
        '<label class="f"><span class="sr">Message</span><textarea id="chatText" maxlength="600" placeholder="Write a message">' + esc(form.draft || '') + '</textarea></label>' +
        (form.err ? '<p class="err" role="alert">' + esc(form.err) + '</p>' : '') +
        '<button class="btn primary" type="button" data-chatsend' + (form.busy ? ' disabled' : '') + '>' + (form.busy ? 'Sending…' : 'Send') + '</button>' +
        '<p class="muted">Our replies also arrive by text message. You can reply to our texts too.</p>';
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
    on('[data-chatsend]', sendChat);
    var ta = document.getElementById('chatText');
    if (ta) ta.addEventListener('input', function () { form.draft = ta.value; });
    var cl = document.getElementById('chatList'); if (cl) cl.scrollTop = cl.scrollHeight;
  }
  function keep() {
    var d = document.getElementById('fDate'), t = document.getElementById('fTime'), c = document.getElementById('fCarrier'), n = document.getElementById('fNote');
    if (d) form.date = d.value; if (t) form.time = t.value; if (c) form.carrier = c.value; if (n) form.note = n.value;
  }

  // ── Valet chat (no SMS for the passenger's messages) ──
  var chatMsgs = [], chatTimer = null;
  function chatHtml() {
    if (!chatMsgs.length) return '<p class="muted">Send us a message about your car or your return. We usually reply quickly during valet hours.</p>';
    return chatMsgs.map(function (m) {
      var t = new Date(m.at), when = isNaN(t) ? '' : t.toLocaleString('en-US', { month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' });
      return '<div class="msg ' + (m.from === 'guest' ? 'me' : 'them') + '"><p>' + esc(m.body) + '</p><span>' + (m.from === 'guest' ? 'You' : 'Makers Air Valet') + ' · ' + esc(when) + '</span></div>';
    }).join('');
  }
  async function loadChat() {
    try {
      var r = await post({ t: TOKEN, action: 'messages' });
      if (r.data && r.data.state === 'expired') { closeSheet(); return load(); }
      if (r.data && r.data.state === 'ok') {
        var changed = JSON.stringify(r.data.messages) !== JSON.stringify(chatMsgs);
        chatMsgs = r.data.messages || [];
        var cl = document.getElementById('chatList');
        if (cl && changed) { cl.innerHTML = chatHtml(); cl.scrollTop = cl.scrollHeight; }
      }
    } catch (e) { /* keep the thread on screen */ }
  }
  async function sendChat() {
    var ta = document.getElementById('chatText'); if (!ta || form.busy) return;
    var text = ta.value.trim(); if (!text) return;
    form.draft = ta.value; form.busy = true; form.err = null; drawSheet();
    try {
      // Same key on retries of this draft → the message is stored once.
      var r = await post({ t: TOKEN, action: 'send', body: text, ck: form.ck });
      form.busy = false;
      var res = r.data && r.data.result;
      if (r.data && r.data.state === 'expired') { closeSheet(); return load(); }
      if (r.status === 429 || res === 'LIMITED') form.err = 'Too many messages. Please wait a little or call our valet team.';
      else if (res === 'OK') { form.draft = ''; form.ck = clientKey(); await loadChat(); }
      else if (res === 'UNAVAILABLE') form.err = 'Chat is not available right now. Please call our valet team.';
      else form.err = 'Could not send. Please try again.';
    } catch (e) { form.busy = false; form.err = 'No connection. Your message was not sent yet; please try again.'; }
    drawSheet();
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
    TOKEN = String(location.hash || '').replace(/^#/, ''); pass = null; chatMsgs = []; lastOk = null;
    if (!sheetBg.hidden) closeSheet();
    app.innerHTML = '<div class="center"><p class="muted">Loading your valet pass…</p></div>';
    load();
  });
  document.addEventListener('visibilitychange', function () { if (!document.hidden && pass && sheetBg.hidden) load(); });
  // Latest data on every open/return to the page, and every 30 s while open.
  setInterval(function () { if (!document.hidden && pass && sheetBg.hidden) load(); }, 30000);
  load();
})();
