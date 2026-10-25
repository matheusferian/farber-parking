/* Makers Air Valet — cinematic opening for the passenger link (pass.html).
 *
 * pass.js calls MAVCinematic.start() once per page load, after the pass is
 * rendered: DEPARTURE while the car is parked, RETURN once it is ready or at
 * Customs, nothing after delivery (2026-10-25, version p3 = drawings only).
 * Styles live in pass.css (the page CSP allows no inline styles).
 * This file never reads or changes ticket, payment, pickup or SMS data:
 * it only draws a muted video over the page, which is already rendered and
 * usable underneath, and removes itself.
 *
 * Plays at most once per ticket, trip leg and device: the localStorage key is
 * mav.cine.<16 hex of SHA-256(token + leg)> — no name, ticket or phone, not
 * guessable, nothing sent anywhere. Without storage it simply plays once per
 * page load. Never plays with reduced motion or Save-Data. Gives up (and shows
 * the page) if the video has not started within 2.5 s, on any error, when the
 * tab is hidden, or after 13 s no matter what. SKIP, a tap anywhere or Esc
 * close it immediately.
 */
(function () {
  'use strict';
  var FILES = { DEPARTURE: 'makers-air-departure', RETURN: 'makers-air-return' };
  var COPY = {
    DEPARTURE: ['ENJOY PARADISE', 'Your vehicle is in good hands.'],
    RETURN: ['WELCOME BACK', 'Your journey continues with Makers Air Valet.']
  };
  var START_TIMEOUT_MS = 4000, HARD_CAP_MS = 14500, MAX_FAILED_TRIES = 2;

  function hex(buf) {
    return Array.prototype.map.call(new Uint8Array(buf), function (b) { return ('0' + b.toString(16)).slice(-2); }).join('');
  }
  // Non-crypto fallback (cyrb53) for browsers without crypto.subtle, e.g. a
  // plain-http local demo. Production is https, where SHA-256 is always used.
  function cyrb53(str) {
    var h1 = 0xdeadbeef, h2 = 0x41c6ce57;
    for (var i = 0; i < str.length; i++) {
      var ch = str.charCodeAt(i);
      h1 = Math.imul(h1 ^ ch, 2654435761); h2 = Math.imul(h2 ^ ch, 1597334677);
    }
    h1 = Math.imul(h1 ^ (h1 >>> 16), 2246822507) ^ Math.imul(h2 ^ (h2 >>> 13), 3266489909);
    h2 = Math.imul(h2 ^ (h2 >>> 16), 2246822507) ^ Math.imul(h1 ^ (h1 >>> 13), 3266489909);
    return ('00000000' + (h2 >>> 0).toString(16)).slice(-8) + ('00000000' + (h1 >>> 0).toString(16)).slice(-8);
  }
  function storageKey(token, leg) {
    var input = token + ':' + leg;
    try {
      if (window.crypto && crypto.subtle && window.TextEncoder) {
        return crypto.subtle.digest('SHA-256', new TextEncoder().encode(input))
          .then(function (d) { return 'mav.cine.' + hex(d).slice(0, 16); }, function () { return 'mav.cine.' + cyrb53(input); });
      }
    } catch (e) { /* fall through */ }
    return Promise.resolve('mav.cine.' + cyrb53(input));
  }
  function seen(key) { try { return !!(key && localStorage.getItem(key)); } catch (e) { return false; } }
  function remember(key) { try { if (key) localStorage.setItem(key, '1'); } catch (e) { /* private mode: fine */ } }
  // A film that never started does not count as seen, but a device that fails
  // MAX_FAILED_TRIES times stops trying (so a bad network never delays the page every time).
  function failedTry(key) {
    try {
      var n = (parseInt(localStorage.getItem(key + '.f'), 10) || 0) + 1;
      localStorage.setItem(key + '.f', String(n));
      if (n >= MAX_FAILED_TRIES) remember(key);
    } catch (e) { /* noop */ }
  }
  function prefersReducedMotion() {
    try { return window.matchMedia && matchMedia('(prefers-reduced-motion: reduce)').matches; } catch (e) { return false; }
  }
  function connection() { return navigator.connection || navigator.mozConnection || navigator.webkitConnection || null; }
  function saveData() { var c = connection(); return !!(c && c.saveData); }
  function slowNetwork() {
    var c = connection(); if (!c) return false;
    return /(^|-)2g$|^3g$/.test(c.effectiveType || '') || (typeof c.downlink === 'number' && c.downlink > 0 && c.downlink < 1.5);
  }

  // Styles: pass.css (.mavc …).


  function play(cfg, base, key) {
    var name = FILES[cfg.kind]; if (!name) return;
    var lite = slowNetwork();
    var stem = base + name + '-' + cfg.v + (lite ? '-lite' : '-portrait');
    var root = document.createElement('div');
    root.className = 'mavc';
    root.setAttribute('role', 'dialog');
    root.setAttribute('aria-label', 'Makers Air Valet intro video');
    var video = document.createElement('video');
    video.muted = true; video.defaultMuted = true; video.playsInline = true; video.autoplay = true;
    video.setAttribute('muted', ''); video.setAttribute('playsinline', ''); video.setAttribute('webkit-playsinline', '');
    video.setAttribute('preload', 'auto'); video.setAttribute('disablepictureinpicture', ''); video.setAttribute('aria-hidden', 'true');
    video.poster = base + name + '-' + cfg.v + '-poster.jpg';
    var s1 = document.createElement('source'); s1.src = stem + '-hevc.mp4'; s1.type = 'video/mp4; codecs="hvc1"';
    var s2 = document.createElement('source'); s2.src = stem + '.mp4'; s2.type = 'video/mp4';
    video.appendChild(s1); video.appendChild(s2);
    var shade = document.createElement('div'); shade.className = 'sh';
    var end = document.createElement('div'); end.className = 'end';
    var logo = document.createElement('img'); logo.alt = 'Makers Air Valet'; logo.src = base + 'makers-air-valet-white.png';
    var h2 = document.createElement('h2'); h2.textContent = COPY[cfg.kind][0];
    var p = document.createElement('p'); p.textContent = COPY[cfg.kind][1];
    end.appendChild(logo); end.appendChild(h2); end.appendChild(p);
    var skip = document.createElement('button'); skip.type = 'button'; skip.className = 'skip'; skip.textContent = 'SKIP';
    skip.setAttribute('aria-label', 'Skip intro');
    root.appendChild(video); root.appendChild(shade); root.appendChild(end); root.appendChild(skip);

    var closed = false, started = false, timers = [];
    function later(fn, ms) { timers.push(setTimeout(fn, ms)); }
    function close(reason) {
      if (closed) return; closed = true;
      if (started) remember(key); else failedTry(key);
      timers.forEach(clearTimeout);
      document.removeEventListener('visibilitychange', onHidden);
      document.removeEventListener('keydown', onKey);
      window.removeEventListener('pagehide', onHide);
      root.classList.add('out');
      try { root.setAttribute('data-closed', reason); } catch (e) { /* noop */ }
      setTimeout(function () {
        try { video.pause(); } catch (e) { /* noop */ }
        // Release the network connection and decoder.
        while (video.firstChild) video.removeChild(video.firstChild);
        video.removeAttribute('src'); video.removeAttribute('poster');
        try { video.load(); } catch (e) { /* noop */ }
        if (root.parentNode) root.parentNode.removeChild(root);
      }, 620);
    }
    function onHidden() { if (document.hidden) close('hidden'); }
    function onHide() { close('pagehide'); }
    function onKey(e) { if (e.key === 'Escape') close('escape'); }

    root.addEventListener('click', function () { close(started ? 'skip' : 'skip-early'); });
    video.addEventListener('playing', function () { if (!started) { started = true; remember(key); } });
    video.addEventListener('timeupdate', function () {
      var d = video.duration;
      if (d && isFinite(d) && video.currentTime >= Math.max(d - (lite ? 1.3 : 2.1), d * 0.55)) root.classList.add('endon');
    });
    video.addEventListener('ended', function () { later(function () { close('ended'); }, 350); });
    video.addEventListener('error', function () { close('error'); });
    s2.addEventListener('error', function () { close('error'); });
    document.addEventListener('visibilitychange', onHidden);
    document.addEventListener('keydown', onKey);
    window.addEventListener('pagehide', onHide);
    later(function () { if (!started) close('timeout'); }, START_TIMEOUT_MS);
    later(function () { close('cap'); }, HARD_CAP_MS);

    document.body.appendChild(root);
    requestAnimationFrame(function () { root.classList.add('in'); });
    try { skip.focus({ preventScroll: true }); } catch (e) { /* noop */ }
    var pr = video.play && video.play();
    if (pr && pr.catch) pr.catch(function () { close('autoplay-blocked'); });
  }

  window.MAVCinematic = {
    start: function (cfg, token, base) {
      try {
        if (!cfg || !FILES[cfg.kind] || !/^[a-z0-9-]{1,40}$/.test(cfg.v || '')) return;
        if (prefersReducedMotion() || saveData()) return;
        var leg = cfg.kind === 'RETURN' ? 'return' : 'outbound';
        storageKey(String(token || ''), leg).then(function (key) {
          if (seen(key)) return;
          play(cfg, base, key);
        });
      } catch (e) { /* the page is already usable: nothing to do */ }
    }
  };
})();
