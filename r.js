// Jet Runway ride tip page (owner 2026-11-11). Token from #fragment → ride function decides ok/expired.
(function () {
  'use strict';
  var API = (document.querySelector('meta[name="airvalet-ride-api"]') || {}).content || '';
  var app = document.getElementById('app');
  var TOKEN = (location.hash || '').replace(/^#/, '');
  var RET = /[?&]gratuity=(thanks|cancel)/.exec(location.search);
  var KEY = 'jrTok';
  try { if (TOKEN) sessionStorage.setItem(KEY, TOKEN); else TOKEN = sessionStorage.getItem(KEY) || ''; } catch (e) {}
  var sel = 1000, busy = false;
  function esc(s) { return String(s).replace(/[&<>"']/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]; }); }
  function msg(h, p) { app.innerHTML = '<div class="msg"><h2>' + esc(h) + '</h2><p>' + esc(p) + '</p></div>'; }
  function ck() { try { return crypto.randomUUID().replace(/-/g, ''); } catch (e) { return Date.now().toString(36) + Math.random().toString(36).slice(2); } }
  async function post(body) {
    var r = await fetch(API, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
    return r.ok ? r.json() : { state: 'error' };
  }
  function form() {
    app.innerHTML = '<div class="note"><p class="nh">A note from your driver</p><p>Thank you for riding with us. It was a pleasure to drive you, and we hope you enjoyed Jet Runway Caf\u00e9.</p></div>' +
      '<p class="lbl">Leave a tip for your driver</p>' +
      '<div class="amts" role="group" aria-label="Tip amount">' + [500, 1000, 2000].map(function (c) {
        return '<button type="button" class="amt" data-c="' + c + '" aria-pressed="' + (c === sel) + '">$' + c / 100 + '</button>'; }).join('') + '</div>' +
      '<button type="button" class="btn other" id="oBtn">Other amount</button><div class="oth" id="oBox" hidden><input id="oAmt" type="number" inputmode="decimal" min="1" max="500" step="1" placeholder="$ amount" aria-label="Other amount in dollars"></div>' +
      '<button type="button" class="btn pay" id="pay">Pay $' + sel / 100 + '</button><p class="err" id="err" role="alert" hidden></p>' +
      '<p class="small">Optional · secure payment by Stripe · this link expires 1 day after your ride</p>';
    Array.prototype.forEach.call(app.querySelectorAll('.amt'), function (b) {
      b.addEventListener('click', function () { sel = +b.getAttribute('data-c'); document.getElementById('oBox').hidden = true; form(); });
    });
    document.getElementById('oBtn').addEventListener('click', function () {
      var bx = document.getElementById('oBox'); bx.hidden = false; var i = document.getElementById('oAmt'); i.focus();
      i.addEventListener('input', function () { var v = Math.round(parseFloat(i.value) * 100); document.getElementById('pay').textContent = v >= 100 && v <= 50000 ? 'Pay $' + (v / 100) : 'Pay'; });
    });
    document.getElementById('pay').addEventListener('click', pay);
  }
  async function pay() {
    if (busy) return;
    var err = document.getElementById('err'), box = document.getElementById('oBox'), cents = sel;
    if (box && !box.hidden) { cents = Math.round(parseFloat(document.getElementById('oAmt').value) * 100); }
    if (!(cents >= 100 && cents <= 50000)) { err.textContent = 'Choose an amount from $1 to $500.'; err.hidden = false; return; }
    busy = true; var b = document.getElementById('pay'); b.disabled = true; b.textContent = 'Opening secure payment…';
    try {
      var r = await post({ action: 'tip_checkout', t: TOKEN, amount_cents: cents, ck: ck() });
      if (r.state === 'expired') return msg('This link has expired', 'Thank you for riding with Makers Air Valet.');
      if (r.url) { location.href = r.url; return; }
      err.textContent = 'Payment is not available right now. Please try again.'; err.hidden = false;
    } catch (e) { err.textContent = 'No connection. Please try again.'; err.hidden = false; }
    busy = false; b.disabled = false; b.textContent = 'Pay';
  }
  async function start() {
    if (RET && RET[1] === 'thanks') { document.getElementById('title').textContent = 'Thank you!'; return msg('Your tip was received', 'Thank you for riding with Makers Air Valet. You can close this page.'); }
    if (!TOKEN) return msg('Link not found', 'Please use the link from your text message.');
    try {
      var r = await post({ action: 'tip_info', t: TOKEN });
      if (r.state === 'ok') return form();
      if (r.state === 'expired') return msg('This link has expired', 'Thank you for riding with Makers Air Valet.');
      return msg('Link not found', 'Please use the link from your text message.');
    } catch (e) { msg('No connection', 'Check your connection and try again.'); }
  }
  start();
})();
