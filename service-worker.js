// ══════════════════════════════════════════════════════════════════════
// AirValet — Offline Mode Phase 1: App-shell service worker.
//
// Purpose: make the AirValet application shell (markup/styles/scripts/
// logo/vendored Supabase client) available when the network is down, so
// the app can at least load from cache. This worker does NOT fake a
// Supabase backend and does NOT cache any API/Auth/RPC response — every
// request to Supabase (or anything not explicitly listed in SHELL_FILES)
// passes straight through to the network, untouched, always.
//
// Registered with relative scope from index.html (`./service-worker.js`),
// so this file works correctly regardless of the path AirValet is served
// under (currently GitHub Pages at /farber-parking/) without hardcoding
// that path here.
// ══════════════════════════════════════════════════════════════════════

// Bump this on any deploy that changes a precached file. Bumping it is
// what causes install() to populate a fresh cache and activate() to drop
// the previous one — see the versioned-cache/update-lifecycle notes in
// PROJECT.md.
//
// v2 (2026-08-24): index.html/offline-db.js changed substantially
// (Offline Mode Phase 2 — real offline New Entry, PENDING SYNC) and
// index.html/styles.css changed again (TV Mode time format/Ascend In
// Custody/Return Date Follow-Up/high-volume pagination, Dashboard Quick
// H19). SHELL_FILES itself is unchanged — no new same-origin file was
// introduced by either change (verified by grepping every local
// src/href in index.html) — only the *content* of files already on this
// list changed, which is exactly what bumping CACHE_VERSION exists for.
//
// v3 (2026-08-24): index.html/styles.css changed again — Quick H19's
// individual action relocated into the card's normal .dc-qd row (was a
// separate, easy-to-miss meta-corner button) plus a fixed CSS
// specificity bug, and a new Leaving-Today "Bulk H19" action. Same
// SHELL_FILES, same reasoning as v2 — content changed, no new file.
//
// v4 (2026-08-24): index.html/styles.css changed again — individual
// Quick H19 is now Leaving Today/Tomorrow only (was showing on every
// Dashboard section via mkCards()'s shared render, now gated by an
// explicit showQuickH19 flag each caller passes), and the Leaving Today
// header's Print All + All H19 buttons are grouped into one flex
// container so they stay adjacent instead of Print All landing in the
// middle of the row. Also in this same v4 package (not a separate
// bump): TV Mode gained a pulsing "MOVE TO H19" reminder badge on
// Leaving Today/Tomorrow rows and cards (tvNeedsH19Move()), and
// TV_ROW_CAP/TV_CARD_CAP were retuned for the extra badge-row height —
// see PROJECT.md, TV Mode — H19 Move Reminder. Same SHELL_FILES, same
// reasoning as v2/v3.
//
// v5 (2026-08-25, deployed): index.html/styles.css changed again — TV
// Mode's Operations page was restructured into Group A (Alerts/Customs+
// Ascend/Active Vehicles, responsive 1-3 page layout from real measured
// width) and Group B (Return Date Follow-Up, dedicated continuation
// page(s), responsive 1-2 sub-columns), fixing a real physical-TV bug
// where Active Vehicles clipped on the right edge and Follow-Up showed
// an internal scrollbar — see PROJECT.md, TV Mode — Operations page
// architecture. Row/column capacity for these Operations pages is now
// measured live against the real DOM (tvMeasureColumnCapacity())
// instead of reusing Today's static TV_ROW_CAP, and every `.tv-list` in
// TV Mode changed from overflow-y:auto to overflow:hidden. Same
// SHELL_FILES, same reasoning as v2/v3/v4.
//
// v6 (2026-08-25): index.html changed again — same-day follow-up fix to
// v5. Production verification after the v5 deploy (rendering a
// constrained synthetic scenario on the live site, not just checking
// source) found real Operations overflow that every local test before
// deploy had missed: tvDoRender() called tvRenderKpis(vm) AFTER
// building Operations pages, so tvBuildOpsPages()'s real-DOM capacity
// measurement (tvRealPageBodyBox()) read the PREVIOUS render's KPI row
// height, not the current one — correct on a settled page where KPI
// height happens to stay put between renders (which is what every local
// test exercised), wrong the moment KPI height actually changes
// render-to-render, which a real device does regularly. Fixed by moving
// tvRenderKpis(vm) before the page-building calls, so the real available
// page-body height Operations measures against is always current. Same
// SHELL_FILES, same reasoning as v2-v5.
//
// v7 (2026-08-25, NOT YET DEPLOYED — prepared pending approval):
// index.html/styles.css changed again — real physical-32"-TV testing
// found Leaving Today/Checked In Today/Leaving Tomorrow still showing
// scrollbars in production despite the v5/v6 Operations fixes, because
// those two page groups still relied on static TV_ROW_CAP/TV_CARD_CAP
// guessing rather than the real-DOM measurement already built for
// Operations. This release generalizes that measurement into a genuine
// adaptive fit engine (tvFitTier()/tvFindCapacityAtTier()) used by
// Today AND Tomorrow: render the real candidate content offscreen,
// measure its natural height at 5 bounded density tiers (normal ->
// compact -> high -> xcompact -> min, name/time held at an 11px floor
// throughout), pick the first that fits, and only paginate if even the
// densest tier doesn't — never guessing a cap and hoping. Also fixes
// two confirmed CSS bugs found during the same physical-TV audit:
// .tv-card-grid still had overflow-y:auto (missed when .tv-list was
// fixed for v5), and a pre-existing @media(max-width:1400px) rule
// forced the KPI row to 3 columns (2 grid rows) at exactly the width
// range a real TV reports, which was the dominant cause of the KPI row
// eating ~114px of every page's available height — removed, plus
// .tv-kpi-lbl gained white-space:nowrap (it never had it, unlike
// .tv-kpi-sub, so long labels could wrap and inflate the row further).
// Added: a debounced resize/fullscreenchange reflow (previously TV Mode
// never re-rendered on either), and a TV Mode diagnostics panel in
// Debug (real viewport/DPI/fullscreen/fit-tier/overflow status — never
// shown on the TV display itself). See PROJECT.md, TV Mode — Adaptive
// Fit Engine. Same SHELL_FILES, same reasoning as v2-v6.
//
// v8 (2026-08-26, NOT YET DEPLOYED — prepared pending approval):
// index.html/styles.css changed again — Leaving Today only. The left
// time column now shows "✈ RV 17:02" (flight folded into the time
// block via a new opts.combineFlightTime flag on tvRow(), set only by
// tvTodayRowHtml's 'leaving' branch) instead of a bare time plus a
// separate flight line underneath the vehicle/hangar meta. No flight ->
// unchanged bare time; time missing -> "✈ RV TIME NOT SET" reusing the
// existing tv-time-unset shrink. New .tv-row-time-flight CSS gives that
// block a bounded auto width (78-168px, narrower per density tier) so
// it can't eat arbitrary space from the passenger name; .tv-row-time's
// fixed width for every other tvRow() consumer (Checked In Today,
// Ascend/Customs, Return Date Follow-Up) is untouched. Leaving
// Tomorrow's card layout (tvCard()/tvFlightLine()) is untouched — that
// is a separate code path. Same SHELL_FILES, same reasoning as v2-v7.
var CACHE_VERSION = 'v8';
var CACHE_NAME = 'airvalet-shell-' + CACHE_VERSION;

// Resolved relative to this file's own location, so they land in the
// correct GitHub Pages subpath automatically.
var SHELL_FILES = [
  './',
  './index.html',
  './styles.css',
  './utils.js',
  './logo.PNG',
  './vendor/supabase.js',
  // index.html loads these two via <script src> for the Offline Mode
  // infrastructure itself — without them precached, a cold offline
  // launch throws (found during Phase 1 testing: openOfflineDb was
  // undefined offline because these weren't in this list yet).
  './offline-auth.js',
  './offline-db.js'
];

self.addEventListener('install', function(event){
  event.waitUntil(
    caches.open(CACHE_NAME).then(function(cache){
      // cache.addAll() is atomic: if any single request fails, or
      // returns a non-2xx response, the whole precache is rejected and
      // NOTHING is cached — this install then fails, and the browser
      // never activates this worker. That's deliberate (see PROJECT.md
      // Phase 1 notes): a service worker that "half" cached the shell
      // must never be allowed to claim offline readiness.
      return cache.addAll(SHELL_FILES);
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

// Explicit allow-list, not a wildcard: only requests whose URL resolves
// to one of SHELL_FILES are ever served from cache. Everything else
// (Supabase REST/Auth/RPC, the printer, any other origin) is passed
// through untouched by simply not calling event.respondWith() — the
// browser handles those exactly as if this worker didn't exist.
self.addEventListener('fetch', function(event){
  if(event.request.method !== 'GET') return;

  var url = new URL(event.request.url);
  if(url.origin !== self.location.origin) return;

  var scopePath = self.registration.scope; // e.g. https://…/farber-parking/
  var requestedRelative = event.request.url.indexOf(scopePath) === 0
    ? event.request.url.slice(scopePath.length)
    : null;
  if(requestedRelative === null) return;

  var isShellRequest = SHELL_FILES.some(function(f){
    var normalized = f.replace(/^\.\//, '');
    return requestedRelative === normalized || requestedRelative === '' && normalized === '';
  }) || url.pathname === scopePath; // exact scope root (`./`)

  if(!isShellRequest) return; // never touch Supabase or anything else

  event.respondWith(
    caches.match(event.request, {cacheName: CACHE_NAME}).then(function(cached){
      if(cached) return cached;
      // Not cached yet (or cache miss) — go to network, and only cache
      // the response if it actually succeeded. Never cache an error
      // page, a 404, or an auth failure as if it were the real shell.
      return fetch(event.request).then(function(networkResponse){
        if(networkResponse && networkResponse.ok){
          var toCache = networkResponse.clone();
          caches.open(CACHE_NAME).then(function(cache){ cache.put(event.request, toCache); });
        }
        return networkResponse;
      });
    })
  );
});

// Update lifecycle: this worker never calls skipWaiting() on its own —
// it sits in "waiting" (standard browser behavior) until the page
// explicitly asks it to activate, which only happens when the attendant
// taps the "Update Available — Reload" banner. See index.html's
// swUpdateReady handling.
self.addEventListener('message', function(event){
  if(event.data && event.data.type === 'SKIP_WAITING'){
    self.skipWaiting();
  }
});
