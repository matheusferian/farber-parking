// ── PRINT TICKET PROTOTYPE ─────────────────────────────────────────────────────
// Isolated module — removable without affecting any existing system logic.
// Target: Epson TM-m30II / 80mm thermal paper / iOS Safari / MacBook Safari
//
// Exposed globals (all prefixed or namespaced to avoid collisions):
//   buildCustomerTicketHTML(record)
//   buildKeyTicketHTML(record)
//   printCustomerTicket(recordId)
//   printKeyTicket(recordId)
//   openTicketPrintWindow(recordId)
//
// Future ESC/POS hook: replace the window.open() block in openTicketPrintWindow()
// with a Bluetooth/ESC-POS driver call while reusing the build* functions.
// ──────────────────────────────────────────────────────────────────────────────

(function () {

  // ── THERMAL RECEIPT CSS ──────────────────────────────────────────────────────
  // 80mm paper = 302px at 96dpi, but we use mm units for accuracy.
  // Designed for: Epson TM-m30II, monospace, B&W only, no images/shadows/gradients.
  var THERMAL_CSS = [
    '* { box-sizing: border-box; margin: 0; padding: 0; }',

    'html, body {',
    '  background: #ffffff;',
    '  color: #000000;',
    '  font-family: "Courier New", Courier, monospace;',
    '  font-size: 12px;',
    '  line-height: 1.4;',
    '  width: 80mm;',
    '  max-width: 80mm;',
    '  -webkit-print-color-adjust: exact;',
    '  print-color-adjust: exact;',
    '}',

    '.ticket {',
    '  width: 72mm;',
    '  max-width: 72mm;',
    '  margin: 0 auto;',
    '  padding: 4mm 0 2mm;',
    '}',

    '.ticket + .ticket {',
    '  border-top: 2px dashed #000;',
    '  padding-top: 6mm;',
    '  margin-top: 2mm;',
    '}',

    '.t-center  { text-align: center; }',
    '.t-bold    { font-weight: bold; }',
    '.t-sm      { font-size: 10px; }',
    '.t-xs      { font-size: 9px; letter-spacing: 0.5px; }',
    '.t-lg      { font-size: 15px; font-weight: bold; }',
    '.t-xl      { font-size: 20px; font-weight: bold; letter-spacing: 3px; }',
    '.t-label   { font-size: 9px; text-transform: uppercase; letter-spacing: 1px; margin-bottom: 1mm; }',
    '.t-value   { font-size: 13px; font-weight: bold; }',

    '.dash {',
    '  border: none;',
    '  border-top: 1px dashed #000;',
    '  margin: 3mm 0;',
    '}',

    '.solid {',
    '  border: none;',
    '  border-top: 1px solid #000;',
    '  margin: 5mm 0;',
    '}',

    '.field { margin-bottom: 2.5mm; }',

    '.body-text {',
    '  font-size: 10px;',
    '  line-height: 1.55;',
    '}',

    '.spacer-sm { height: 2mm; }',
    '.spacer-md { height: 4mm; }',
    '.spacer-cut { height: 10mm; }',

    '.internal-badge {',
    '  display: inline-block;',
    '  border: 2px solid #000;',
    '  padding: 1mm 3mm;',
    '  font-size: 10px;',
    '  font-weight: bold;',
    '  letter-spacing: 1px;',
    '}',

    '.reminder-box {',
    '  border: 2px solid #000;',
    '  padding: 3mm;',
    '  text-align: center;',
    '  font-weight: bold;',
    '  font-size: 11px;',
    '  letter-spacing: 1px;',
    '  margin-top: 4mm;',
    '}',

    /* ── Print media ── */
    '@media print {',
    '  @page {',
    '    margin: 0;',
    '    size: 80mm auto;',
    '  }',
    '  html, body {',
    '    width: 80mm;',
    '    margin: 0;',
    '    padding: 0;',
    '  }',
    '  .no-print { display: none !important; }',
    '  .ticket + .ticket {',
    '    page-break-before: always;',
    '    border-top: none;',
    '    padding-top: 4mm;',
    '    margin-top: 0;',
    '  }',
    /* When tickets are in wrapper divs the sibling selector above won't fire;
       target the key wrapper directly for the page break. */
    '  #pt-key-wrap { page-break-before: always; }',
    /* Solo-print modes: body class toggles which wrapper is hidden. */
    '  body.pt-solo-customer #pt-key-wrap { display: none !important; }',
    '  body.pt-solo-key #pt-customer-wrap  { display: none !important; }',
    '}',

    /* ── Screen preview: vertical thermal roll, no flex ── */
    '@media screen {',
    '  body {',
    '    background: #c8cdd8;',
    '    padding: 16px 0 165px;',
    '    margin: 0;',
    '  }',
    '  .ticket {',
    '    background: #fff;',
    '    box-shadow: 0 2px 14px rgba(0,0,0,0.2);',
    '    display: block;',
    '    margin: 0 auto;',
    '    padding: 4mm 4mm 2mm;',
    '    width: 80mm;',
    '    max-width: calc(100vw - 16px);',
    '  }',
    '  .ticket + .ticket { border-top: none; }',
    /* Dashed cut-line separator — screen only, not printed */
    '  .cut-separator {',
    '    display: block;',
    '    margin: 0 auto;',
    '    width: 80mm;',
    '    max-width: calc(100vw - 16px);',
    '    background: #c8cdd8;',
    '    padding: 7px 0;',
    '    text-align: center;',
    '    font-family: "Courier New", Courier, monospace;',
    '    font-size: 9px;',
    '    letter-spacing: 3px;',
    '    color: #6a7280;',
    '  }',
    '  .preview-bar {',
    '    position: fixed;',
    '    bottom: 0;',
    '    left: 0;',
    '    right: 0;',
    '    background: #1B3B6F;',
    '    border-top: 2px solid #C9AC54;',
    '    padding: 10px 12px;',
    '    display: flex;',
    '    flex-direction: column;',
    '    gap: 8px;',
    '    z-index: 100;',
    '  }',
    '  .pb-row {',
    '    display: flex;',
    '    gap: 8px;',
    '  }',
    '  .pb-btn {',
    '    font-family: "Courier New", Courier, monospace;',
    '    font-weight: bold;',
    '    border-radius: 10px;',
    '    cursor: pointer;',
    '    border: none;',
    '    min-height: 48px;',
    '    -webkit-tap-highlight-color: transparent;',
    '    width: 100%;',
    '  }',
    '  .pb-solo {',
    '    flex: 1;',
    '    width: auto;',
    '    background: rgba(201,172,84,0.15);',
    '    color: #C9AC54;',
    '    border: 1px solid rgba(201,172,84,0.45) !important;',
    '    font-size: 11px;',
    '    padding: 10px 6px;',
    '    letter-spacing: 0.5px;',
    '  }',
    '  .pb-print {',
    '    background: #C9AC54;',
    '    color: #1B1400;',
    '    font-size: 14px;',
    '    padding: 13px;',
    '    letter-spacing: 1px;',
    '  }',
    '  .pb-close {',
    '    background: rgba(255,255,255,0.08);',
    '    color: rgba(255,255,255,0.6);',
    '    border: 1px solid rgba(255,255,255,0.18) !important;',
    '    font-size: 12px;',
    '    padding: 9px;',
    '    min-height: 40px;',
    '  }',
    '}'
  ].join('\n');

  // ── HELPER: Format return date for ticket (date only) ────────────────────────
  function _ticketReturnDate(ret) {
    if (!ret) return 'NO DATE';
    var d = pd(ret);
    if (!d) return String(ret);
    return d.toLocaleDateString('en-US', {
      weekday: 'short',
      month: 'short',
      day: 'numeric',
      year: 'numeric'
    });
  }

  // ── HELPER: Lookup record from global data array ─────────────────────────────
  function _findRecord(recordId) {
    if (typeof data === 'undefined') return null;
    for (var i = 0; i < data.length; i++) {
      if (data[i].id === recordId) return data[i];
    }
    return null;
  }

  // ── HELPER: Open a new window with html content ──────────────────────────────
  function _openWindow(html, windowName) {
    // window.open() must be called synchronously from a user gesture.
    // This function is always called from a click handler, so it is safe.
    var win = window.open('', windowName || '_blank', 'width=420,height=720');
    if (!win) {
      // Popup blocked — try without window features (may open as tab on iOS)
      win = window.open('about:blank', '_blank');
    }
    if (!win) {
      alert('Please allow popups for this site, then tap Print Ticket again.');
      return null;
    }
    win.document.open();
    win.document.write(html);
    win.document.close();
    return win;
  }

  // ── HELPER: Wrap ticket HTML into a full print document ──────────────────────
  // buttonsHTML : raw HTML placed inside .preview-bar before the Close button.
  // inlineScript: optional JS string embedded in <script> in <head>.
  function _buildDocument(title, bodyContent, buttonsHTML, inlineScript) {
    return [
      '<!DOCTYPE html>',
      '<html lang="en">',
      '<head>',
      '<meta charset="UTF-8">',
      '<meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0">',
      '<meta name="apple-mobile-web-app-capable" content="yes">',
      '<title>' + title + '</title>',
      '<style>' + THERMAL_CSS + '</style>',
      (inlineScript ? '<script>' + inlineScript + '<\/script>' : ''),
      '</head>',
      '<body>',
      bodyContent,
      '<div class="preview-bar no-print">',
      buttonsHTML,
      '  <button class="pb-btn pb-close" onclick="window.close()">Close</button>',
      '</div>',
      '</body>',
      '</html>'
    ].join('\n');
  }

  // ────────────────────────────────────────────────────────────────────────────
  // buildCustomerTicketHTML(r)
  // Returns the HTML string for the customer-facing parking claim check.
  // r = passenger record object from the global data array.
  // ────────────────────────────────────────────────────────────────────────────
  window.buildCustomerTicketHTML = function (r) {
    var ticket  = escapeHTML(r.ticket  || '---');
    var name    = escapeHTML(r.name    || '---');
    var phone   = escapeHTML(r.phone   ? fmtP(r.phone) : '---');
    var retDate = escapeHTML(_ticketReturnDate(r.ret));

    return [
      '<div class="ticket">',

      // Header
      '  <div class="t-center t-lg">MAKERS AIR VALET</div>',
      '  <div class="t-center t-xs" style="margin-top:1mm">Parking Ticket / Claim Check</div>',

      '  <hr class="dash">',

      // Ticket number — large and prominent
      '  <div class="t-center">',
      '    <div class="t-label">TICKET #</div>',
      '    <div class="t-xl">' + ticket + '</div>',
      '  </div>',

      '  <hr class="dash">',

      // Passenger info
      '  <div class="field">',
      '    <div class="t-label">PASSENGER</div>',
      '    <div class="t-value">' + name + '</div>',
      '  </div>',

      '  <div class="field">',
      '    <div class="t-label">PHONE</div>',
      '    <div class="t-value">' + phone + '</div>',
      '  </div>',

      '  <div class="field">',
      '    <div class="t-label">RETURN DATE</div>',
      '    <div class="t-value">' + retDate + '</div>',
      '  </div>',

      '  <hr class="dash">',

      // Conditional date change notice
      '  <div class="body-text">',
      '    If your return date changes,<br>',
      '    please notify us as soon as possible.',
      '  </div>',

      '  <div class="spacer-sm"></div>',

      '  <div class="body-text">',
      '    <span class="t-bold">Call or Text:</span><br>',
      '    +1 (954) 352-1010',
      '  </div>',

      '  <div class="spacer-sm"></div>',

      '  <div class="body-text">',
      '    <span class="t-bold">Service Hours:</span><br>',
      '    5:30 AM - 5:30 PM',
      '  </div>',

      '  <hr class="dash">',

      '  <div class="body-text">',
      '    If returning with Makers Air,<br>',
      '    we remain available until the<br>',
      '    last Makers Air arrival.<br>',
      '    <br>',
      '    If returning with another company,<br>',
      '    please notify us in advance.<br>',
      '    After-hours vehicle delivery is<br>',
      '    not guaranteed without prior notice.',
      '  </div>',

      '  <hr class="dash">',

      '  <div class="body-text">',
      '    Vehicles are parked in our parking lot.<br>',
      '    <br>',
      '    We are not responsible for lost,<br>',
      '    stolen, or unattended items left<br>',
      '    inside the vehicle.',
      '  </div>',

      '  <hr class="dash">',

      '  <div class="t-center t-bold" style="font-size:11px;letter-spacing:1px">',
      '    PLEASE KEEP THIS TICKET FOR PICKUP',
      '  </div>',

      '  <div class="spacer-cut"></div>',

      '</div>'
    ].join('\n');
  };

  // ────────────────────────────────────────────────────────────────────────────
  // buildKeyTicketHTML(r)
  // Returns the HTML string for the internal key/staff copy.
  // r = passenger record object from the global data array.
  // ────────────────────────────────────────────────────────────────────────────
  window.buildKeyTicketHTML = function (r) {
    var ticket   = escapeHTML(r.ticket || '---');
    var name     = escapeHTML(r.name   || '---');
    var phone    = escapeHTML(r.phone  ? fmtP(r.phone) : '---');
    var retDate  = escapeHTML(_ticketReturnDate(r.ret));
    var location = escapeHTML(r.loc    || '');
    var notes    = escapeHTML(r.obs    || '');

    return [
      '<div class="ticket">',

      // Header + internal badge
      '  <div class="t-center t-lg">MAKERS AIR VALET</div>',
      '  <div class="t-center" style="margin-top:2mm">',
      '    <span class="internal-badge">KEY COPY (INTERNAL)</span>',
      '  </div>',

      '  <hr class="dash">',

      // Ticket number
      '  <div class="t-center">',
      '    <div class="t-label">TICKET #</div>',
      '    <div class="t-xl">' + ticket + '</div>',
      '  </div>',

      '  <hr class="dash">',

      // Passenger info
      '  <div class="field">',
      '    <div class="t-label">PASSENGER</div>',
      '    <div class="t-value">' + name + '</div>',
      '  </div>',

      '  <div class="field">',
      '    <div class="t-label">PHONE</div>',
      '    <div class="t-value">' + phone + '</div>',
      '  </div>',

      '  <div class="field">',
      '    <div class="t-label">RETURN DATE</div>',
      '    <div class="t-value">' + retDate + '</div>',
      '  </div>',

      '  <hr class="dash">',

      // Hangar / Location
      '  <div class="field">',
      '    <div class="t-label t-bold">HANGAR / LOCATION:</div>',
      (location
        ? '    <div class="t-value">' + location + '</div>'
        : '    <div style="border-bottom:1px solid #000;height:8mm;"></div>'),
      '  </div>',

      '  <hr class="dash">',

      // Notes
      '  <div class="field">',
      '    <div class="t-label t-bold">NOTES:</div>',
      (notes
        ? '    <div class="body-text" style="margin-top:1mm">' + notes + '</div>'
        : '    <div style="border-bottom:1px solid #000;height:8mm;margin-top:1mm;"></div>'),
      '  </div>',

      // Writing lines
      '  <div style="margin-top:4mm">',
      '    <div style="border-bottom:1px solid #000;height:9mm;"></div>',
      '    <div style="border-bottom:1px solid #000;height:9mm;"></div>',
      '    <div style="border-bottom:1px solid #000;height:9mm;"></div>',
      '    <div style="border-bottom:1px solid #000;height:9mm;"></div>',
      '  </div>',

      // Reminder box
      '  <div class="reminder-box">',
      '    REMEMBER TO UPDATE<br>',
      '    VEHICLE LOCATION<br>',
      '    IN THE SYSTEM',
      '  </div>',

      '  <div class="spacer-cut"></div>',

      '</div>'
    ].join('\n');
  };

  // ── HELPER: Shared two-ticket document parts ────────────────────────────────
  // Used by openTicketPrintWindow AND ptWriteTicketToWindow to avoid duplication.
  function _buildBothTicketsDoc(r) {
    var bodyContent = [
      '<div id="pt-customer-wrap">' + buildCustomerTicketHTML(r) + '</div>',
      '<div class="cut-separator no-print">- - - - - - - ✂ - - - - - - -</div>',
      '<div id="pt-key-wrap">' + buildKeyTicketHTML(r) + '</div>'
    ].join('\n');

    // ptPrint(mode): adds body class so @media print hides the other ticket,
    // then restores via afterprint (with setTimeout fallback for older iOS).
    var ptScript = [
      'function ptPrint(mode) {',
      '  if (mode) document.body.classList.add(mode);',
      '  window.print();',
      "  if ('onafterprint' in window) {",
      '    window.addEventListener("afterprint", function h() {',
      '      if (mode) document.body.classList.remove(mode);',
      '      window.removeEventListener("afterprint", h);',
      '    });',
      '  } else {',
      '    setTimeout(function() { if (mode) document.body.classList.remove(mode); }, 2000);',
      '  }',
      '}'
    ].join('\n');

    var buttonsHTML = [
      '  <div class="pb-row">',
      "    <button class=\"pb-btn pb-solo\" onclick=\"ptPrint('pt-solo-customer')\">PRINT CUSTOMER COPY</button>",
      "    <button class=\"pb-btn pb-solo\" onclick=\"ptPrint('pt-solo-key')\">PRINT KEY COPY</button>",
      '  </div>',
      '  <button class="pb-btn pb-print" onclick="ptPrint()">PRINT BOTH TICKETS</button>'
    ].join('\n');

    return { bodyContent: bodyContent, buttonsHTML: buttonsHTML, ptScript: ptScript };
  }

  // ────────────────────────────────────────────────────────────────────────────
  // openTicketPrintWindow(recordId)
  // Opens a print window showing BOTH tickets. Called from the detail panel.
  // ────────────────────────────────────────────────────────────────────────────
  window.openTicketPrintWindow = function (recordId) {
    var r = _findRecord(recordId);
    if (!r) { alert('Record not found.'); return; }
    var d = _buildBothTicketsDoc(r);
    var html = _buildDocument(
      'Ticket #' + escapeHTML(r.ticket || '') + ' - ' + escapeHTML(r.name || ''),
      d.bodyContent, d.buttonsHTML, d.ptScript
    );
    _openWindow(html, 'pt_both_' + recordId);
  };

  // ── AUTO-PRINT HOOKS (called from saveEntry in index.html) ───────────────────
  // iOS Safari blocks window.open() after an await. Solution: open a blank
  // window synchronously FIRST (ptOpenBlankWindow), then fill it with ticket
  // content after the async save completes (ptWriteTicketToWindow).

  window.ptOpenBlankWindow = function () {
    var win = window.open('', 'pt_new_' + Date.now(), 'width=420,height=720');
    if (!win) win = window.open('about:blank', '_blank');
    if (win) {
      win.document.write(
        '<!DOCTYPE html><html><head>' +
        '<meta charset="UTF-8">' +
        '<meta name="viewport" content="width=device-width,initial-scale=1">' +
        '<style>body{background:#c8cdd8;font-family:"Courier New",Courier,monospace;' +
        'display:flex;align-items:center;justify-content:center;height:100vh;' +
        'margin:0;color:#1B3B6F;font-size:13px;letter-spacing:2px;}</style>' +
        '</head><body>PREPARING TICKET...</body></html>'
      );
      win.document.close();
    }
    return win || null;
  };

  window.ptWriteTicketToWindow = function (win, record) {
    if (!win || !record) return;
    var d = _buildBothTicketsDoc(record);
    var html = _buildDocument(
      'Ticket #' + escapeHTML(record.ticket || '') + ' - ' + escapeHTML(record.name || ''),
      d.bodyContent, d.buttonsHTML, d.ptScript
    );
    win.document.open();
    win.document.write(html);
    win.document.close();
  };

  // ────────────────────────────────────────────────────────────────────────────
  // printCustomerTicket(recordId)
  // Opens a print window with the customer copy only.
  // ────────────────────────────────────────────────────────────────────────────
  window.printCustomerTicket = function (recordId) {
    var r = _findRecord(recordId);
    if (!r) { alert('Record not found.'); return; }

    var html = _buildDocument(
      'Customer Ticket #' + escapeHTML(r.ticket || ''),
      buildCustomerTicketHTML(r),
      '  <button class="pb-btn pb-print" onclick="window.print()">PRINT CUSTOMER TICKET</button>'
    );

    _openWindow(html, 'pt_cust_' + recordId);
  };

  // ────────────────────────────────────────────────────────────────────────────
  // printKeyTicket(recordId)
  // Opens a print window with the key/internal copy only.
  // ────────────────────────────────────────────────────────────────────────────
  window.printKeyTicket = function (recordId) {
    var r = _findRecord(recordId);
    if (!r) { alert('Record not found.'); return; }

    var html = _buildDocument(
      'Key Ticket #' + escapeHTML(r.ticket || ''),
      buildKeyTicketHTML(r),
      '  <button class="pb-btn pb-print" onclick="window.print()">PRINT KEY TICKET</button>'
    );

    _openWindow(html, 'pt_key_' + recordId);
  };

})();

// ── END PRINT TICKET PROTOTYPE ────────────────────────────────────────────────
// Future ESC/POS integration point:
//   Replace _openWindow() with a Bluetooth/ESC-POS driver while keeping
//   buildCustomerTicketHTML() and buildKeyTicketHTML() as the data layer.
//   The build* functions return plain HTML strings; an ESC/POS adapter
//   would parse those or receive structured data from a separate API.
// ─────────────────────────────────────────────────────────────────────────────
