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
  var hero = document.getElementById('hero');
  var pass = null;
  var lastFocus = null;
  var form = {};           // current sheet state
  var VALET_PHONE_FALLBACK = '(954) 352-1010'; // printed on the customer ticket
  // Intro film (cine/cinematic-v1.js): one switch; false = never plays.
  // OFF 2026-10-26 (owner): p3 films carry a 'PROVISIONAL MEDIA · NOT FINAL' badge.
  var CINEMATIC_ON = false, CINEMATIC_VERSION = 'p3', cineTried = false;
  // Valet Terms (owner 2026-10-27, decision 10): no page exists until the attorney
  // approves the text. terms.html is the SMS terms — never link it as Valet Terms.
  var VALET_TERMS_URL = '';
  var GRATUITY_COPY = 'Valet service is complimentary. If you want to thank the team, you can leave a gratuity.';

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
    if (vals.every(function (v) { return v === vals[0]; })) return 'Valet hours: every day, ' + vals[0].replace(' – ', ' to ').replace(/ (AM|PM)/g, '\u00a0$1');
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
      // Audit 2026-11-06 (#34): nothing changed → keep the page as it is (screen readers keep their place,
      // open "How to get there" steps stay open). Only the quiet "could not refresh" note goes away.
      var sig = JSON.stringify(pass);
      if (sig === lastSig && app.querySelector('main')) { var st0 = document.getElementById('stale'); if (st0) st0.remove(); return; }
      lastSig = sig;
      render();
      loadPhoto();
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
  var lastOk = null, lastSig = null;
  // Car photo (2026-11-06): fetched once per page through valet-pass (token-checked), shown from a blob URL.
  var photoUrl = null, photoTried = false;
  async function loadPhoto() {
    if (photoTried || !pass || !pass.has_photo) return;
    photoTried = true;
    try {
      var r = await post({ t: TOKEN, action: 'photo' });
      var b64 = r && r.data && r.data.state === 'ok' ? r.data.image : null;
      if (!b64) return;
      var bin = atob(b64), arr = new Uint8Array(bin.length);
      for (var i = 0; i < bin.length; i++) arr[i] = bin.charCodeAt(i);
      photoUrl = URL.createObjectURL(new Blob([arr], { type: 'image/jpeg' }));
      render();
    } catch (e) { /* the pass works without the photo */ }
  }
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
      : ((pass.status === 'READY' && !dayTripEarly(pass)) || pass.status === 'CUSTOMS_CONFIRMED' || isReturning(pass)) ? 'RETURN' : 'DEPARTURE';
    if (kind) window.MAVCinematic.start({ kind: kind, v: CINEMATIC_VERSION }, TOKEN, 'cine/');
  }

  function renderMessage(title, text, retry) {
    setHero(null);
    app.innerHTML = '<div class="center"><img src="assets/makers-valet-badge.png" alt="Makers Air Valet" width="64" height="64">' +
      '<h2>' + esc(title) + '</h2><p class="muted">' + esc(text) + '</p>' +
      (retry ? '<button class="btn quiet" type="button" id="retry">Try again</button>' : '') + '</div>';
    var b = document.getElementById('retry'); if (b) b.addEventListener('click', load);
  }

  // ── Hero (Concept C, approved 2026-10-11) ──
  // Static markup in pass.html: never re-created, so the flight plays once per
  // page load. Only its text and state classes change; a class that is already
  // set never restarts an animation. The flight starts with the first pass
  // (state known); DELIVERED (first load or a real change) departs once.
  function setHero(p) {
    var h1 = document.getElementById('hello'), sub = document.getElementById('helloSub');
    if (!p) { h1.hidden = true; sub.hidden = true; return; }
    var done = p.status === 'DELIVERED';
    var t = done ? (p.first_name ? 'Thank you, ' + p.first_name + '.' : 'Thank you.') : (p.first_name ? 'Welcome, ' + p.first_name + '.' : 'Welcome.');
    var st = done ? 'Your car has been delivered.' : 'Your Makers Air Valet pass';
    if (h1.textContent !== t) h1.textContent = t;
    if (sub.textContent !== st) sub.textContent = st;
    h1.hidden = false; sub.hidden = false;
    // Owner preview 2026-11-10: the Makers Caravan 3D (no tail number) instead of the drawing,
    // only on the owner's test ticket until approved. Swapped before the flight starts.
    if (p.ticket === '1110-10' && !hero.querySelector('.plane .p3d')) {
      var pl = hero.querySelector('.plane');
      if (pl) { pl.classList.add('plane3d'); pl.insertAdjacentHTML('beforeend', '<img class="p3d" src="assets/makers-caravan-3d.webp" alt="" width="900" height="393">'); }
    }
    if (!hero.classList.contains('go')) hero.classList.add('go');
    if (hero.classList.contains('done') !== done) hero.classList.toggle('done', done);
  }
  // Progress line: Checked in → Parked → Ready → Delivered (Customs counts as Ready).
  // Day trip at Hangar 19 is READY automatically from check-in (same day); only the team's Ready counts here.
  function dayTripEarly(p) { return !!p.day_trip && p.status === 'READY' && !p.ready_by_staff && !p.key_with_guest; }
  function progress(p) {
    var at = p.status === 'DELIVERED' ? 3 : ((p.status === 'READY' && !dayTripEarly(p)) || p.status === 'CUSTOMS_CONFIRMED') ? 2 : 1;
    var names = ['Checked in', 'Parked', 'Ready', 'Delivered'];
    // Day trip, key handed to the guest at drop-off (owner 2026-11-06): no Ready / Delivered steps.
    if (p.day_trip && p.key_with_guest && p.status !== 'DELIVERED') { names = ['Checked in', 'Parked', 'Key handed over']; at = 3; }
    return '<ol class="tl tl-' + at + (names.length === 3 ? ' tl-n3' : '') + '" aria-label="Progress">' + names.map(function (n, i) {
      var c = i < at || (at === 3) ? 'done' : i === at ? 'now' : '';
      return '<li class="' + c + '"' + (i === at ? ' aria-current="step"' : '') + '><span class="dot" aria-hidden="true"></span>' + n + '</li>';
    }).join('') + '</ol>';
  }

  // ── Valet pass (boarding-pass layout, 2026-10-25; Concept C cards 2026-10-27) ──
  // Day trip (owner 2026-11-06): back the same day; tell the guest which hangar to come back to.
  function dayTripLine(p, lead) {
    // Owner 2026-11-06: same wording as the team's standard Welcome Back message.
    var h = esc(p.day_trip_hangar || 'Hangar 19');
    return 'After clearing U.S. Customs, please remain with your pilots and return to Makers Air at ' + h + ', where your vehicle will be ready and waiting for you.' +
      '';
  }
  function statusInfo(p) {
    // Day trip (owner 2026-11-06): never "A/C running / luggage" — no luggage, and the
    // passenger may already have the key. Staff Ready still shows "Ready" when the team has the key.
    if (p.status === 'READY' && p.day_trip && !p.lockbox) {
      return { tone: 'ready', word: p.ready_by_staff && !p.key_with_guest ? 'Ready' : 'Day trip', line: dayTripLine(p, 'When you land today, ') };
    }
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
        line: (p.day_trip && p.key_with_guest) ? 'Your car is waiting for you at U.S. Customs. You already have your key.'
          : p.pickup === 'CUSTOMS_ASCEND'
          ? 'An Ascend team member will hand you your key.'
          : 'As arranged, your car will be at Customs. When you arrive, reply to our text or call ' + esc(contactValet(p)) + ' for your key.' };
    }
    if (p.status === 'DELIVERED') return { tone: 'done', word: 'Delivered', line: 'Thank you for choosing Makers Air Valet.' };
    // Staff filled the return flight / arrival time: the guest is on the way back
    // (owner 2026-10-25). "Ready" is still set by staff only.
    if (isReturning(p) && p.day_trip) return { tone: 'returning', word: 'Day trip', line: dayTripLine(p, 'Fly safe. When you land, ') };
    if (isReturning(p)) {
      return { tone: 'returning', word: 'Flying back',
        line: p.pickup === 'HANGAR_19' ? 'Fly safe. We\u2019ll be waiting at Hangar\u00a019 and help with your luggage.' : 'Fly safe. We\u2019ll be waiting for you and help with your luggage.' };
    }
    if (p.day_trip) return { tone: 'parked', word: 'Day trip', line: dayTripLine(p, 'When you land today, ') };
    return { tone: 'parked', word: 'Parked', line: 'Your car is parked with us.' };
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
    if (p.day_trip && p.pickup === 'HANGAR_19') return p.day_trip_hangar || 'Hangar 19';
    if (p.pickup === 'HANGAR_19') return 'Hangar 19';
    if (p.pickup === 'CUSTOMS_EXCEPTION' || p.pickup === 'CUSTOMS_ASCEND') return 'Customs';
    return '';
  }

  // The guest's own ticket number, small, at the foot of the pass (owner 2026-10-26).
  function ticketLine(p) {
    return p.ticket ? '<p class="pass-ticket">Ticket number for your reference: <strong>' + esc(p.ticket) + '</strong></p>' : '';
  }

  // ── Valet pass v3 (mockup 2026-11-06): one boarding pass — status on top, a perforation,
  // and the stub with Pickup / Return / Key / Ticket. Day trip = the three return steps.
  function stubField(k, v, soft, extra) {
    return '<div class="sf"><p class="k">' + k + '</p><p class="v' + (soft ? ' v-soft' : '') + '">' + v + '</p>' + (extra || '') + '</div>';
  }
  function passCard(p) {
    var st = statusInfo(p), done = p.status === 'DELIVERED', day = !!p.day_trip && !done && !p.lockbox;   // audit #38: lockbox wins
    var dayToday = day && fmtDate(p.return_date) === fmtIsoDate(todayIso());
    // 2026-11-06: a day trip back with Ascend / through Customs (rare) never gets the Hangar 19 steps.
    var dayH19 = day && p.pickup === 'HANGAR_19';
    var dayCustoms = day && !dayH19;
    var hangar = esc(p.day_trip_hangar || 'Hangar 19');
    var html = '<section class="bp tone-' + st.tone + (day ? ' is-day' : '') + '" aria-label="Your valet pass">';
    if (p.has_photo && photoUrl && !done) html += '<figure class="bp-photo"><img src="' + photoUrl + '" alt="Your ' + (p.vehicle ? esc(niceVehicle(p.vehicle)) : 'car') + ', parked by our valet team" width="1200" height="672"><figcaption>Your car today, photographed by our valet team.</figcaption></figure>';
    html += '<div class="bp-top">' +
      '<p class="bp-status">' + esc(st.word) + '</p>' +
      '<h2 class="bp-car">' + (p.vehicle ? esc(niceVehicle(p.vehicle)) : 'Vehicle details coming soon') + '</h2>';
    if (done) {
      html += (p.tip_thanks
        ? '<p class="bp-line">Thank you for the gratuity' + (p.first_name ? ', ' + esc(p.first_name) : '') + '. The team appreciates it. See you on your next trip.</p>'
        : '<p class="bp-line">Thank you for choosing us' + (p.first_name ? ', ' + esc(p.first_name) : '') + '. See you on your next trip.</p>') +
        '<p class="bp-sign">Your Makers Air Valet team</p>';
    } else if (dayCustoms && p.status !== 'CUSTOMS_CONFIRMED') {
      html += '<p class="bp-line">' + (p.pickup === 'CUSTOMS_ASCEND' || p.pickup === 'CUSTOMS_EXCEPTION'
        ? 'When you land' + (dayToday ? ' today' : '') + ', your car will be waiting for you at U.S. Customs.' + (p.key_with_guest ? ' You already have your key.' : '')
        : st.line) + '</p>';
    } else if (dayH19 && p.status !== 'CUSTOMS_CONFIRMED') {
      html += '<p class="bp-line">' + (dayToday ? 'When you land today:' : 'When you land:') + '</p>' +
        '<ol class="bp-steps"><li>Clear U.S. Customs.</li><li>Remain with your pilots.</li><li>Return with them to Makers Air at ' + hangar + '.</li></ol>' +
        '<p class="bp-warn">Please do not exit through the U.S. Customs terminal. Transportation back to Makers Air is not available from that location.</p>';
    } else {
      html += '<p class="bp-line">' + st.line + '</p>';
    }
    html += progress(p) + '</div>';
    html += '<div class="bp-perf" aria-hidden="true"></div><div class="bp-stub">';
    if (done) {
      html += '<div class="bp-grid">' + stubField('Ticket', esc(p.ticket || '')) + '</div>';
      return html + '</div></section>';
    }
    var date = fmtDate(p.return_date), time = fmtTime(p.return_time), place = dayH19 ? hangar : pickupText(p);
    var steps = p.pickup === 'HANGAR_19' && p.status === 'PARKED' && !day;
    html += '<div class="bp-grid">' +
      stubField('Pickup', place ? esc(place) : 'To be confirmed', !place,
        steps ? '<button class="link" type="button" id="howBtn" aria-expanded="false" aria-controls="howSteps">How to get there</button>' : '') +
      stubField('Return', dayToday ? 'Today' : (date ? esc(date) : 'Not set yet'), !dayToday && !date,
        (date && time && !p.arrival_time ? '<p class="v2">' + esc(time) + '</p>' : '') +
        (p.requests_enabled ? '<button class="link" type="button" data-open="return">Change return</button>' : ''));
    var arr = fmtTime(p.arrival_time);
    if (p.return_flight || arr) html += stubField('Flight', p.return_flight ? esc(p.return_flight) : 'To be confirmed', !p.return_flight) + stubField('Arrives', arr ? esc(arr) : 'To be confirmed', !arr);
    if (day) html += stubField('Key', p.key_with_guest ? 'With you' : 'With our team');
    html += stubField('Ticket', esc(p.ticket || '')) + '</div>';
    if (steps) {
      html += '<ol class="steps howto" id="howSteps" hidden>' +
        '<li>Land with Makers Air</li><li>Complete Customs</li><li>Go back to your pilots and aircraft</li><li><strong>Walk to Hangar 19</strong></li></ol>';
    }
    var pend = p.pending_return;
    if (pend) html += '<p class="pending">Change requested: ' + esc(fmtIsoDate(pend.date) || '') + (pend.time ? ', ' + esc(fmtTime(pend.time)) : '') +
      (pend.carrier ? ' with ' + esc(pend.carrier) : '') + '. Waiting for our team to confirm.</p>';
    return html + '</div></section>';
  }
  // The farewell card reuses the hero aircraft drawing (one source of truth).
  function planeSvg() { var s = hero.querySelector('.plane svg'); return s ? s.outerHTML : ''; }

  // Gratuity (owner 2026-10-27): never mandatory, nothing pre-selected, no
  // percentages. With gratuity_checkout ($5 $10 $20 / $40 $50 Other) every tap
  // asks valet-pass for a Stripe Checkout Session tied to this ticket by the
  // server. Otherwise one action that opens the current Payment Link (the same
  // link as the printed QR codes), where the guest picks the amount.
  function money(v) { return '$' + (Math.round(v * 100) % 100 ? Number(v).toFixed(2) : String(Math.round(v))); }
  function gratuityLinks(p, cls) {
    var gc = p.gratuity_checkout;
    if (gc && Array.isArray(gc.amounts) && gc.amounts.length) {
      return '<div class="grat-chips" role="group" aria-label="Choose a gratuity amount">' + gc.amounts.map(function (a) {
        return '<button class="chip" type="button" data-tip="' + Math.round(a * 100) + '">' + esc(money(a)) + '</button>';
      }).join('') + '<button class="chip" type="button" data-open="other">Other</button></div><p class="err grat-err" role="alert" hidden></p>';
    }
    return '<a class="btn ' + cls + '" href="' + esc(p.gratuity_url) + '" target="_blank" rel="noopener noreferrer" data-grat>Leave a gratuity</a>';
  }
  function hasGratuity(p) { return !!(p.gratuity_url || p.gratuity_checkout); }
  // After delivery: an elegant, more visible card (still optional, no prompt).
  function gratuityCard(p) {
    return '<section class="grat" aria-label="Gratuity"><p class="grat-t">Gratuity</p><p class="grat-copy">' + esc(GRATUITY_COPY) + '</p>' +
      gratuityLinks(p, 'grat-btn') + '<p class="fine">Secure payment by Stripe \u00b7 Matt Solutions &amp; Services.</p></section>';
  }
  // Privacy-safe count of gratuity taps: the token only (no amount); never delays the link.
  function gratuityClick() {
    try { fetch(API, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ t: TOKEN, action: 'gratuity_click' }), cache: 'no-store', credentials: 'omit', referrerPolicy: 'no-referrer', keepalive: true }).catch(function () {}); }
    catch (e) { /* the payment link still opens */ }
  }
  document.addEventListener('click', function (e) {
    var a = e.target && e.target.closest ? e.target.closest('a[data-grat]') : null;
    if (a) gratuityClick();
    var t = e.target && e.target.closest ? e.target.closest('button[data-tip]') : null;
    if (t) startCheckout(parseInt(t.getAttribute('data-tip'), 10), t);
  });
  // Same tab to Stripe Checkout; the return URL carries no token, so the pass
  // comes back from this tab's sessionStorage (see RETURN below).
  var tipBusy = false;
  async function startCheckout(cents, btn) {
    if (tipBusy || !pass) return;
    var host = (btn && btn.closest('.grat, .tip, .sheet')) || document, err = host.querySelector('.grat-err');
    var label = btn ? btn.textContent : '';
    tipBusy = true; if (err) err.hidden = true;
    if (btn) { btn.disabled = true; btn.setAttribute('aria-busy', 'true'); btn.textContent = '\u2026'; }
    var r = null;
    try { r = await post({ t: TOKEN, action: 'gratuity_checkout', amount_cents: cents, ck: clientKey() }); } catch (e) { r = null; }
    var d = r && r.data;
    if (d && d.state === 'ok' && d.result === 'OK' && /^https:\/\/checkout\.stripe\.com\//.test(String(d.url || ''))) {
      try { sessionStorage.setItem('mav-pass-return', TOKEN); } catch (e) { /* the guest still has the link in the text */ }
      location.assign(d.url);
      return;   // tipBusy stays on: no second session while the page leaves
    }
    tipBusy = false;
    if (btn) { btn.disabled = false; btn.removeAttribute('aria-busy'); btn.textContent = label; }
    if (d && d.state === 'expired') return load();
    var gc = pass.gratuity_checkout || {};
    var msg = !r ? 'No connection. Nothing was charged; please try again.'
      : (r.status === 429 || (d && d.result === 'LIMITED')) ? 'Please wait a few minutes and try again.'
      : (d && d.result === 'INVALID') ? 'Please enter an amount from ' + money(gc.min || 1) + ' to ' + money(gc.max || 500) + '.'
      : 'Secure payment is not available right now. Nothing was charged.';
    if (err) {
      err.textContent = msg; err.hidden = false;
      if (pass.gratuity_url && d && d.result === 'UNAVAILABLE') {
        var a = document.createElement('a'); a.href = pass.gratuity_url; a.target = '_blank'; a.rel = 'noopener noreferrer';
        a.setAttribute('data-grat', ''); a.className = 'grat-alt'; a.textContent = 'Use our secure payment page';
        err.appendChild(document.createTextNode(' ')); err.appendChild(a);
      }
    }
  }
  // "Other": any amount within the configured bounds, cents at most.
  function parseAmount(v, gc) {
    var m = /^\$?\s*(\d{1,4})(?:\.(\d{1,2}))?$/.exec(String(v || '').trim());
    if (!m) return null;
    var cents = parseInt(m[1], 10) * 100 + (m[2] ? parseInt((m[2] + '0').slice(0, 2), 10) : 0);
    return cents >= Math.round((gc.min || 1) * 100) && cents <= Math.round((gc.max || 500) * 100) ? cents : null;
  }

  function render() {
    var p = pass, done = p.status === 'DELIVERED';
    setHero(p);
    var html = '<main>';
    html += passCard(p);
    if (p.lockbox && !done && p.status !== 'CUSTOMS_CONFIRMED') html += '<button class="btn primary green" type="button" data-open="lockbox">View after-hours pickup instructions</button>';
    // Gratuity (owner 2026-11-06): visible in every state, calm. Amounts only after delivery.
    if (hasGratuity(p) && !p.tip_thanks) {
      html += '<section class="tip" aria-label="Gratuity"><h2 class="tip-t">Gratuity <span>(optional)</span></h2><p class="tip-c">' + esc(GRATUITY_COPY) + '</p>' +
        (done ? gratuityLinks(p, 'tip-btn') : '<button class="btn tip-btn" type="button" data-open="gratuity">Leave a gratuity</button>') +
        '<p class="tip-fine">Secure payment by Stripe.</p></section>';
    }
    if (p.tip_thanks && hasGratuity(p)) html += '<div class="list"><button type="button" data-open="gratuity"><span>Gratuity</span><small>Optional</small></button></div>';
    if (p.chat_enabled) html += '<button class="btn primary" type="button" data-open="chat">Message our valet team</button>';
    var wash = { REQUEST: 'Request', CONTACT: 'Ask our team', REQUESTED: 'Requested', PRICE_PENDING: 'Price coming', SCHEDULED: 'Scheduled', DONE: 'Done' }[p.car_wash];
    if (!done && wash && p.requests_enabled !== false && !p.day_trip) html += '<div class="list"><button type="button" data-open="wash"><span>Car wash</span><small>' + wash + '</small></button></div>';
    var c = p.contacts || {};
    var hrs = hoursText(p.valet_hours);
    html += '<section class="info">' +
      (hrs && !done ? '<p class="info-h">' + esc(hrs) + '</p><p class="fine">Landing after hours? Text us before you land, or your car may not be ready.</p>' : '') +
      '<p class="contact-line">Valet team: <a href="' + esc(tel(contactValet(p))) + '">' + esc(contactValet(p)) + '</a></p>' +
      (c.reservations_phone ? '<p class="fine">Flights: <a href="' + esc(tel(c.reservations_phone)) + '">Makers Air ' + esc(c.reservations_phone) + '</a></p>' : '') + '</section>';
    html += '<footer>' +
      '<div class="operator"><img src="assets/farber-parking-badge.png" alt="Farber Parking" width="44" height="44">' +
      '<div><p>Operated by Farber Parking</p><p><a href="tel:+15617740494">(561) 774-0494</a></p></div></div>' +
      '<p>Makers Air Valet, Hangar 19, Fort Lauderdale</p>' +
      '<p class="foot-links"><button class="flink" type="button" data-open="info">Valet information</button>' +
      (p.terms_published && VALET_TERMS_URL ? '<a href="' + esc(VALET_TERMS_URL) + '">Valet Terms</a>' : '') +
      '<a href="sms.html">SMS program</a><a href="privacy.html">Privacy</a></p></footer></main>';
    app.innerHTML = html;
    if (RETURN) {   // once, on the first pass after coming back from Stripe
      var note = document.createElement('p'); note.className = RETURN === 'thanks' ? 'okbox return-note' : 'review return-note'; note.setAttribute('role', 'status');
      note.textContent = RETURN === 'thanks' ? 'Thank you for your gratuity.' : 'No gratuity was charged.';
      var m0 = app.querySelector('main'); if (m0) m0.insertBefore(note, m0.firstChild); RETURN = null;
    }
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
      var chips = !!p.gratuity_checkout;
      h = head('Gratuity') + '<p class="p0">' + esc(GRATUITY_COPY) + '</p>' +
        (chips ? gratuityLinks(p, '')
               : '<a class="btn primary" href="' + esc(p.gratuity_url) + '" target="_blank" rel="noopener noreferrer" data-grat>Continue to secure payment</a>') +
        '<p class="muted">Secure payment by Stripe · Matt Solutions &amp; Services.' + (chips ? '' : ' You choose the amount.') + '</p>';
    } else if (form.kind === 'other') {
      var gco = p.gratuity_checkout || {};
      h = head('Other amount') + '<p class="p0">Enter any amount from ' + esc(money(gco.min || 1)) + ' to ' + esc(money(gco.max || 500)) + '.</p>' +
        '<label class="f">Amount (USD)<input type="text" id="tipAmt" inputmode="decimal" autocomplete="off" maxlength="8" placeholder="0.00" value="' + esc(form.amt || '') + '"></label>' +
        '<p class="err grat-err" role="alert"' + (form.err ? '' : ' hidden') + '>' + esc(form.err || '') + '</p>' +
        '<button class="btn primary" type="button" data-tipother>Continue to secure payment</button>' +
        '<p class="muted">Secure payment by Stripe · Matt Solutions &amp; Services. Always optional.</p>';
    } else if (form.kind === 'info') {
      // Facts only, from the existing settings (decision 10). No legal terms here.
      var ci = p.contacts || {}, hi = hoursText(p.valet_hours);
      h = head('Valet information') + '<p class="p0">Our valet service is complimentary.</p>' +
        (hi ? '<div class="info-row"><p class="k">Valet hours</p><p class="info-v">' + esc(hi) + '</p></div>' : '') +
        '<div class="info-row"><p class="k">Where</p><p class="info-v">Makers Air, Hangar 19, Fort Lauderdale</p></div>' +
        '<div class="info-row"><p class="k">Contact</p><p class="info-v"><a href="' + esc(tel(contactValet(p))) + '">Call valet ' + esc(contactValet(p)) + '</a></p>' +
          (ci.text_phone ? '<p class="info-v"><a href="' + esc(sms(ci.text_phone)) + '">Text ' + esc(ci.text_phone) + '</a></p>' : '') +
          (ci.reservations_phone ? '<p class="info-v"><a href="' + esc(tel(ci.reservations_phone)) + '">Makers Air flights ' + esc(ci.reservations_phone) + '</a></p>' : '') + '</div>' +
        '<div class="info-row"><p class="k">Operated by</p><p class="info-v">Farber Parking \u00b7 <a href="tel:+15617740494">(561) 774-0494</a></p></div>' +
        '<button class="btn quiet" type="button" data-close>Close</button>';
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
    // Other amount lives in a sheet: the 30 s refresh never wipes what the guest types.
    on('[data-tipother]', function (e) {
      var inp = document.getElementById('tipAmt'), gc = (pass && pass.gratuity_checkout) || {};
      form.amt = inp ? inp.value : ''; var cents = parseAmount(form.amt, gc);
      if (cents === null) { form.err = 'Please enter an amount from ' + money(gc.min || 1) + ' to ' + money(gc.max || 500) + '.'; drawSheet(); var i2 = document.getElementById('tipAmt'); if (i2) i2.focus(); return; }
      form.err = null; startCheckout(cents, e.currentTarget);
    });
    on('.sheet [data-open="other"]', function () { form = { kind: 'other', step: 1, ck: clientKey() }; drawSheet(); var i = document.getElementById('tipAmt'); if (i) i.focus(); });
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
    // Same key on retries of this exact text → stored once. Edited after a
    // failed try → new key, or the server would keep only the first text.
    if (form.ckText != null && form.ckText !== text) form.ck = clientKey();
    form.ckText = text;
    form.draft = ta.value; form.busy = true; form.err = null; drawSheet();
    try {
      var r = await post({ t: TOKEN, action: 'send', body: text, ck: form.ck });
      form.busy = false;
      var res = r.data && r.data.result;
      if (r.data && r.data.state === 'expired') { closeSheet(); return load(); }
      if (r.status === 429 || res === 'LIMITED') form.err = 'Too many messages. Please wait a little or call our valet team.';
      else if (res === 'OK') { form.draft = ''; form.ck = clientKey(); form.ckText = null; await loadChat(); }
      else if (res === 'UNAVAILABLE') form.err = 'Chat is not available right now. Please call our valet team.';
      else form.err = 'Could not send. Please try again.';
    } catch (e) { form.busy = false; form.err = 'No connection. Your message was not sent yet; please try again.'; }
    drawSheet();
  }

  async function sendRequest(body, doneStep) {
    if (form.busy) return;
    form.busy = true; form.err = null; drawSheet();
    try {
      // Same client key on every retry of the SAME request → never two requests. A changed request
      // (the guest edited it after a lost answer) gets a new key, so staff see the new one (audit #10).
      var sig = JSON.stringify(body);
      if (form.ckBody != null && form.ckBody !== sig) form.ck = clientKey();
      form.ckBody = sig;
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
    setHero(null);  // never keep the previous guest's name on screen
    app.innerHTML = '<div class="center"><p class="muted">Loading your valet pass…</p></div>';
    load();
  });
  document.addEventListener('visibilitychange', function () { if (!document.hidden && pass && sheetBg.hidden && !tipBusy) load(); });
  // Audit 2026-11-06 (#12): back from Stripe with the browser's Back button, Safari restores this page from
  // its cache with the tapped amount still busy. Reset and refresh so the pass keeps updating.
  window.addEventListener('pageshow', function (e) {
    if (!e.persisted) return;
    tipBusy = false;
    Array.prototype.forEach.call(document.querySelectorAll('button[data-tip]'), function (b) { b.disabled = false; });
    lastSig = null;   // redraw the buttons even when the pass did not change
    if (pass) load();
  });
  // Latest data on every open/return to the page, and every 30 s while open.
  setInterval(function () { if (!document.hidden && pass && sheetBg.hidden && !tipBusy) load(); }, 30000);
  // Back from Stripe Checkout (?gratuity=thanks|cancel, no token in that URL):
  // this tab's pass comes back from sessionStorage, with a quiet note.
  var RETURN = (/[?&]gratuity=(thanks|cancel)(?:&|$)/.exec(location.search) || [])[1] || null;
  if (RETURN) {
    if (!TOKEN) { try { TOKEN = sessionStorage.getItem('mav-pass-return') || ''; } catch (e) { TOKEN = ''; } }
    try { history.replaceState(null, '', location.pathname + (TOKEN ? '#' + TOKEN : '')); } catch (e) { /* keep the URL */ }
  }
  if (RETURN && !TOKEN) {
    renderMessage(RETURN === 'thanks' ? 'Thank you' : 'No gratuity was charged', RETURN === 'thanks' ? 'Thank you for your gratuity. You can close this page.' : 'You can close this page.');
  } else load();
})();
