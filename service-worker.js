// AirValet app-shell service worker
// v29 (2026-09-06): refresh precached shell after Dashboard opacity hotfix.
// Scope: same-origin shell files only. Supabase/API requests are never intercepted.

// v30: commit 42207cd (NOT RETURNING indicator — Dashboard + TV Mode)
// changed index.html and styles.css content only. Same SHELL_FILES, no
// new same-origin file introduced.
// v31: commit 71525bb (fix stale PWA update detection — updateViaCache:
// 'none' + periodic reg.update() poll) changed index.html content only.
// Same SHELL_FILES, no new same-origin file introduced.
// v32 (2026-09-21): install() now fetches every SHELL_FILES entry with
// {cache:'reload'} instead of a bare cache.addAll(SHELL_FILES) — found
// this same day that a bare addAll() can silently precache a shell file
// straight from this browser's own still-fresh HTTP cache (GitHub Pages:
// Cache-Control max-age=600) instead of the network, so a deploy made
// within 10 minutes of a prior one could precache stale content despite
// a correct CACHE_VERSION bump. Same SHELL_FILES, no new same-origin file.
// v33: commit d642e54 (relabel NOT RETURNING -> OTHER BOAT, visual only —
// not_returning_with_makers_air and its business logic unchanged) changed
// index.html and styles.css content only. Same SHELL_FILES, no new
// same-origin file introduced.
// v34: commit 1177c70 (OTHER BOAT text badge -> icon-only fa-ship, plus
// new coverage in the Dashboard's Arrived/Leaving Today/Tomorrow/Sunday/
// Forgot section cards) changed index.html and styles.css content only.
// Same SHELL_FILES, no new same-origin file introduced.
// v35: Closing Report feature — WhatsApp-shareable end-of-day image
// (new sidebar tab, 5-screen pane, html2canvas PNG export, Stripe Tips
// KPI chip on Dashboard). Changed index.html, styles.css, service-worker.js.
// Same SHELL_FILES, no new same-origin file introduced.
// v36: sidebar UX fix — move Closing Report above legacy Daily Closing
// (renamed to Full Accounting). Navigation/label order only.
// v37: operational redesign — Valet Attendance (clock in/out), Closing
// Report v2 (VEHICLES 3-col with IN CUSTODY, auto VALETS from attendance,
// CASH CUSTODY radio, LEAVING TOMORROW, dual-image share).
// v38: DST-safe vsWallClockToISO (target-date offset, not current-date),
// Failure≠Zero error handling (Stripe tips, valets), LT incomplete-data
// block (REVIEW gate before generation).
// v39: fix Closing Report missing from authenticated nav — update
// TAB_VISIBILITY_BY_ROLE from 'closing' to 'closingreport'.
// v40: responsive UI polish (header/dashboard/KPI/FAB), TV Mode moved
// from header to sidebar, centralized avDevice detection helper,
// Device/Environment diagnostics in Debug pane.
// v41: End of Day → Closing Report shortcut in New Entry modal
// (navigation only, role-gated by TAB_VISIBILITY_BY_ROLE).

// v42: ONE LOGIN Phase 2C — "Continue with FarberOS" (new same-origin file
// sso-client.js added to SHELL_FILES; index.html + styles.css changed).
// v43: SSO revalidation watcher in sso-client.js (human SSO sessions only).
// v44: rollout Step 5 — FARBEROS_SSO_ROLLOUT_ENABLED = true (button + return + watcher on).
// v45: Logout signs out THIS device only (scope 'local'), never every device of the account.
// v46: Returning with / pickup model, Makers Customs exception, Needs Review
//      (index.html, utils.js, styles.css changed). Same SHELL_FILES.
// v89: Closing Report — more than 12 cars leaving tomorrow → one line each (time · name · hangar).
// v88: Guests premium UI (pass header, segmented sections, timelines, duplicate
//      comparison) + Edit guest / vehicle / visit sheets (index.html + styles.css).
//      Same SHELL_FILES. Needs 20261115.
// v87: Guests — staff guest profiles (search, visits, activity, tips & notes),
//      returning-guest hint at check-in, Guest Profile on the ticket
//      (index.html + styles.css changed). Same SHELL_FILES. Needs 20261114.
// v94: Fix — "Print flight tag" offer never closed (inline display beat [hidden]); auto-closes after 10 s,
//      one at a time, Print closes after the printer confirms (index.html). Same SHELL_FILES.
// v93: DAILY TIPS hidden by default + Show / Hide + cash counted at closing; Closing Report image
//      redesigned (1080 px, numbers on top) and shared as a JPEG photo (WhatsApp preview). Same SHELL_FILES.
// v90: In-person tips at check-in / delivery / later (several per ticket, $5 $10 $20 $50 Other)
//      + DAILY TIPS on the Dashboard (index.html + styles.css). Same SHELL_FILES. Needs 20261117.
// v86: Smart Tips — cash tips at Deliver go to the audited ledger, car card Tips,
//      manual delivery message, Closing Report cash reconciliation
//      (index.html + styles.css changed). Same SHELL_FILES. Needs 20261113.
// v47: AirValet SMS inbox + server-side texts (only when SMS_PROVIDER = 'twilio').
// v91: Key Copy + Flight Tag V2 — portrait tags (Epson page mode) sized for the key
//      sleeve, car wash + notes printed, flight tag offer after tail + time
//      (index.html + utils.js). Same SHELL_FILES. No migration.
// v92: Key Copy black bar = return date (hangar plain); Flight Tag black bar = tail + return time;
//      no print stamp on either tag (utils.js).
// v95: Valet Clock In — fixed name buttons (DIEGO F, MATHEUS F, MARCIO C, EDUARDO) fill Name in one tap
//      (index.html). Same SHELL_FILES. No migration.
// v96: Closing shares ONE photo (no separate Leaving Tomorrow photo); Leaving Tomorrow list in the
//      Closing gets the old photo's alerts (3+ cars same time, midday rush, no hangar, Customs, Ascend). index.html.
// v97: Day trip option at check-in (classic + new) and Day trip / hangar line on the valet pass.
// v98: Day trip key choice (team keeps key / guest has key) at check-in, list tag, pass line.
// v99: Day trip pass — after Customs, stay with your pilots and come back with them.
// v100: Day trip pass uses the standard Welcome Back wording (no walk).
// v101: Day trip pass shows the Welcome Back text once (one paragraph).
// v102: Day trip only — 'Key handed over' step on the pass; key choice on the car card.
// v103: Valet Pass v2 look (one logo, left-aligned ticket card, day trip Customs callout + key chip).
// v104: TV Mode — Day trip shows DAY TRIP (not TIME NOT SET) + KEY WITH GUEST badge.
// v105: Dashboard card — DAY TRIP + KEY WITH GUEST chips.
// v106: staff wording — KEY WITH PASSENGER (not guest).
// v107: classic check-in form disabled — new check-in only on every device.
// v108: Day trip pass — staff Ready no longer says A/C running / luggage.
// v109: Dashboard card — Ready button next to the passenger name.
// v110: Valet Pass v3 — one boarding pass with a perforated stub, plain copy, calm gratuity section (owner approved).
// v111: Dashboard Ready button removed (owner: confusing; the pass marks Ready automatically at Hangar 19 on the return day).
// v112: audit fixes — day trip after midnight, Change return, gratuity after cash tip, checkout error box, early Ready, staff copy.
// v113: Send from iPhone uses the valet pass text with a fresh link for enrolled tickets (audit A1).
// v114: corrected phone → consent on the new number + welcome with a new pass link (audit A2).
// v115: audit A6 (Closing before 4 AM = previous day), A7 (undo delivery offers to remove the cash tip), A8 (TV overdue list + key badge).
// v116: audit #9 (offline upload watchdog), #10 (edited return request = new key), #12 (pass resets after Back from Stripe).
// v117: audit #16 — integrity check on the html2canvas / jsPDF CDN scripts.
// v118: audit #25 quiet hours, #27 clock-in guard, #28-#30 tips, #31 ticket after midnight, #32 closing save check, #33 print escape, #34/#35/#38 pass.
// v119: pass — day trip back with Ascend / Customs: Customs wording, key with the passenger, no Hangar 19 steps.
// v120: car photo on the valet pass (upload on the car card) + Ascend/Customs day trip pass.
// v121: Customs delivery asks for a car photo for the pass; Inbox quick reply 'At Customs, key with you'.
// v122: TV alert for day trips 1 h before landing (send Welcome Back).
// v123: TV day trip alert clears once the Welcome Back was sent.
// v124: Welcome Back reminders repeat until sent; Inbox 'Welcome back…' counts; TV alert for every pending Welcome Back.
// v180: Jet Runway Café rides (New Entry tab, READY card on the Dashboard, TV bar, /r tip page).
// v181: Makers robot — same last name pairs show what Makers says (flights out/back, together?) + Same family button.
// v182: iPad kiosk view of the Dashboard (opt-in per device: Kiosk view button / ?kiosk=1; Classic view turns it off).
// v183: kiosk view — New check-in full screen in steps (Guest / Return / Texts); Jet Runway widget only while a ride is open, after tips.
// v184: TV departures — DELAYED while the plane is still at FXE after its time; destinations of the people on board (route = first stop only).
// v185: TV departures — first stop + islands as bag tags (1ST STOP SAQ › TYM 4 · GHC 2).
var CACHE_VERSION = 'v188';
var CACHE_NAME = 'airvalet-shell-' + CACHE_VERSION;

var SHELL_FILES = [
  './',
  './index.html',
  './styles.css',
  './utils.js',
  './logo.PNG',
  './assets/logo-icon.png',
  './manifest.webmanifest',
  './apple-touch-icon.png',
  './icon-192.png',
  './icon-512.png',
  './favicon-32x32.png',
  './vendor/supabase.js',
  './offline-auth.js',
  './offline-db.js',
  './sso-client.js'
];

self.addEventListener('install', function(event){
  // cache.addAll(SHELL_FILES) alone does not reliably bypass this host's
  // own HTTP cache (GitHub Pages: Cache-Control max-age=600) — found
  // 2026-09-21: two deploys inside that 10-minute window let a NEWER
  // CACHE_VERSION's install() silently precache the PREVIOUS deploy's
  // still-HTTP-cached shell files instead of the true latest content.
  // Each fetch is forced to {cache:'reload'} so install() always hits
  // the network, never the browser's own disk cache. Promise.all keeps
  // the original cache.addAll() semantics — any single failed/non-2xx
  // fetch fails the entire install, same as before.
  event.waitUntil(
    caches.open(CACHE_NAME).then(function(cache){
      return Promise.all(SHELL_FILES.map(function(url){
        return fetch(url, {cache:'reload'}).then(function(response){
          if(!response.ok) throw new Error('Precache fetch failed for ' + url + ': ' + response.status);
          return cache.put(url, response);
        });
      }));
    })
  );
});

self.addEventListener('activate', function(event){
  event.waitUntil(
    caches.keys().then(function(names){
      return Promise.all(names.map(function(name){
        if(name.indexOf('airvalet-shell-') === 0 && name !== CACHE_NAME){
          return caches.delete(name);
        }
      }));
    }).then(function(){
      return self.clients.claim();
    })
  );
});

self.addEventListener('fetch', function(event){
  if(event.request.method !== 'GET') return;

  var url = new URL(event.request.url);
  if(url.origin !== self.location.origin) return;

  var scopePath = self.registration.scope;
  var requestedRelative = event.request.url.indexOf(scopePath) === 0
    ? event.request.url.slice(scopePath.length)
    : null;
  if(requestedRelative === null) return;

  var isShellRequest = SHELL_FILES.some(function(f){
    var normalized = f.replace(/^\.\//, '');
    return requestedRelative === normalized || (requestedRelative === '' && normalized === '');
  }) || event.request.url === scopePath;
  // The app opened with a query (e.g. /?checkin=v2, /?mode=tv) is the same
  // page: serve the cached shell offline too (audit: v2 did not open offline).
  var isAppNavigation = event.request.mode === 'navigate' && (url.pathname === new URL(scopePath).pathname || /\/index\.html$/.test(url.pathname));
  if(!isShellRequest && !isAppNavigation) return;

  event.respondWith(
    caches.match(isAppNavigation && !isShellRequest ? scopePath : event.request, {cacheName: CACHE_NAME}).then(function(cached){
      if(cached) return cached;
      return fetch(event.request).then(function(networkResponse){
        if(networkResponse && networkResponse.ok){
          var toCache = networkResponse.clone();
          caches.open(CACHE_NAME).then(function(cache){
            cache.put(event.request, toCache);
          });
        }
        return networkResponse;
      });
    })
  );
});

// Keep the existing explicit-update lifecycle: the page controls when a waiting
// worker activates by sending SKIP_WAITING after the attendant accepts reload.
self.addEventListener('message', function(event){
  if(event.data && event.data.type === 'SKIP_WAITING'){
    self.skipWaiting();
  }
});

// v48: Web Push for staff alerts (new guest message / passenger request).
// Only devices that an ADMIN approved for AirValet texting can subscribe,
// and only after the iPad/iPhone user allows notifications. The payload is
// already privacy-trimmed by the server (no name or text on the lock screen
// unless that device turned previews on). Tapping opens the Messages tab.
self.addEventListener('push', function(event){
  var d = {};
  try { d = event.data ? event.data.json() : {}; } catch(e) { d = {}; }
  var title = typeof d.title === 'string' ? d.title.slice(0, 60) : 'AirValet';
  var body = typeof d.body === 'string' ? d.body.slice(0, 200) : 'Open AirValet';
  event.waitUntil(self.registration.showNotification(title, {
    body: body,
    tag: typeof d.tag === 'string' ? d.tag : 'airvalet-alert',
    renotify: true,
    icon: './icon-192.png',
    badge: './icon-192.png',
    // Staff alerts (check-in / tip) open the app's home; guest messages and requests open Messages.
    data: { url: d.url === '/' ? './' : './#messages' }
  }));
});
// Tap on a notification: bring AirValet to the front on the right screen.
// Staff alerts (url './': check-in, tip, reminders) → Dashboard; guest
// messages / requests ('./#messages') → Messages. An already open window is
// told where to go (it switches tabs itself, nothing reloads, the login and
// anything being typed stay) and focused; if focus is refused or no window
// exists, the app is opened at that URL (a fresh start lands on Dashboard).
// The TV page (?mode=tv / #tv) never gets this.
self.addEventListener('notificationclick', function(event){
  event.notification.close();
  var url = (event.notification.data && event.notification.data.url) || './#messages';
  var target = url.indexOf('#messages') >= 0 ? 'OPEN_MESSAGES' : 'OPEN_DASHBOARD';
  event.waitUntil(self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then(function(list){
    var app = null;
    for (var i = 0; i < list.length; i++) {
      var u = list[i].url || '';
      if (/[?&]mode=tv(&|$)|#tv$/.test(u)) continue;
      if (!app || list[i].focused || list[i].visibilityState === 'visible') app = list[i];
    }
    if (!app) return self.clients.openWindow(url);
    try { app.postMessage({ type: target }); } catch (e) {}
    return ('focus' in app ? app.focus() : Promise.reject()).catch(function(){ return self.clients.openWindow(url); });
  }));
});
