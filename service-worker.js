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
//
// v9 (2026-08-27, NOT YET DEPLOYED — prepared pending approval):
// index.html changed again — a new presentation-only `tvShortName()`
// helper shortens passenger names in TV Mode to "FIRST-INITIAL LAST
// WORD(S)" (e.g. "CHRISTOPHER ALEXANDER MARTINEZ" -> "C ALEXANDER
// MARTINEZ") at its three TV Mode name-render points: tvCard()
// (Leaving Tomorrow), tvRow() (Leaving Today, Checked In Today,
// Ascend/Customs, Return Date Follow-Up), and alertsColHtml() (Special
// Handling & Alerts). Deterministic string split only — no
// surname-guessing, no casing changes beyond uppercasing the kept
// initial, no change to r.name or any other consumer (Dashboard,
// search, SMS, printed tickets, reports, Offline Mode). No CSS changed
// — the fit engine's existing measurement automatically reflects
// shorter names since it renders through these same functions. styles.css
// is unchanged this release. Same SHELL_FILES, same reasoning as v2-v8.
//
// v10 (2026-08-27, NOT YET DEPLOYED — prepared pending approval):
// index.html changed again — tiny follow-up to v9's tvShortName(): the
// kept first-name initial now gets a trailing period ("M FERIAN" ->
// "M. FERIAN") only when the name has more than one word; a single-word
// name is still returned completely unchanged, with no stray period.
// Same three TV Mode render points as v9 (tvCard/tvRow/alertsColHtml),
// same presentation-only scope — r.name and every other consumer
// untouched. No CSS changed. Same SHELL_FILES, same reasoning as v2-v9.
//
// v11 (2026-08-29, NOT YET DEPLOYED — prepared pending approval):
// index.html changed again — TV Mode (C.1) now reads the centralized
// aircraft_live_state_computed view from Supabase into _tv.aircraftState,
// throttled to its own ~60s cadence independent of refreshTvData()'s own
// call frequency (see maybeFetchTvAircraftState()/fetchTvAircraftState()).
// Read-only: the browser never calls adsb.lol and never invokes the
// refresh-aircraft-state Edge Function. Transport/state plumbing only — no
// rendering, no new DOM, no CSS. styles.css is unchanged this release.
// Same SHELL_FILES, same reasoning as v2-v10.
//
// v12 (2026-08-29, NOT YET DEPLOYED — prepared pending approval):
// index.html changed again — TV Mode (C.2) now renders an operational
// aircraft-tracking badge (RETURNING/APPROACHING/ARRIVING SOON) on Leaving
// Today rows only, derived from C.1's _tv.aircraftState combined with
// return_flight (tvAircraftTrackingBadge()/tvAircraftTrackingStatus()/
// TAIL_SUFFIX_TO_REGISTRATION). Reuses the existing .tv-badge/statusBadges
// mechanism — no new CSS, styles.css unchanged this release. Only reads
// server-computed freshness/physical_status/distance_trend, never
// recomputes them; no badge for STALE/NO_SIGNAL/missing/unmapped rows.
// Same SHELL_FILES, same reasoning as v2-v11.
//
// v13 (2026-08-29, NOT YET DEPLOYED — prepared pending approval):
// index.html AND styles.css changed — C.2 visual refinement, shipping as
// one combined release (nothing from v12 has been deployed yet):
//   1. Aircraft badge display changed from NM to an estimated minutes
//      value (~N MIN, radial distance / ground_speed_kt), falling back
//      to the status alone when speed is missing/invalid. Classification
//      thresholds (25nm/8nm on distance_to_fxe_nm) are unchanged —
//      display only.
//   2. ARRIVING SOON (airborne and ON_GROUND_NEAR_FXE) now pulses via a
//      new .tv-badge-arriving-pulse rule (styles.css), reusing the same
//      restrained never-toward-0 opacity-pulse idiom as the existing H19
//      move reminder, reduced-motion-aware. RETURNING/APPROACHING remain
//      static.
//   3. A new "⚠ DELAYED" badge on Leaving Today rows
//      (tvDelayedBadge()/tvIsDelayedRow()/tvExpectedReturnDateTime()),
//      shown once the row's scheduled return time (r.ret + departure_time,
//      via the existing pd()/getDepartureTime() helpers already used
//      elsewhere in TV Mode) has passed. Independent of the aircraft
//      badge — coexists with RETURNING/APPROACHING/ARRIVING SOON — and
//      clears only when the mapped aircraft reports LIVE +
//      ON_GROUND_NEAR_FXE (tvAircraftTrackingStatus()'s new
//      onGround:true field). Reuses the existing static
//      .tv-badge-critical class — no new CSS for this part.
// Same SHELL_FILES, same reasoning as v2-v12.
//
// v14 (2026-08-29, NOT YET DEPLOYED — prepared pending approval):
// index.html changed again — Leaving Today's aircraft badge now shows a
// live ETA (still ~N MIN math: distance_to_fxe_nm / ground_speed_kt * 60,
// same safeguards) alongside the existing RETURNING/APPROACHING/ARRIVING
// SOON tier word ("✈ APPROACHING · ETA 9 MIN"), and a new backend-derived
// "✓ LANDED · N MIN AGO" state (from the new aircraft_live_state.landed_at
// column, see migrations/20260829_add_aircraft_landed_at_timestamp.sql)
// replaces the airborne tier once the aircraft is confirmed on the ground
// near FXE — deliberately NOT gated on freshness, since a parked aircraft
// commonly stops transmitting ADS-B, but landed_at is meant to keep
// displaying anyway. DELAYED (⚠) remains a fully separate, independent,
// always-static badge — it coexists with the tier/ETA badge rather than
// replacing it, and now also clears on confirmed LANDED (in addition to
// the existing live ON_GROUND_NEAR_FXE fallback). ARRIVING SOON pulse
// unchanged (<=8nm only); LANDED reuses the existing static .tv-badge-ok
// class (same as DELIVERED) — no new CSS, styles.css unchanged this
// release. WELCOME BACK OVERDUE untouched. No adsb.lol/Edge Function call
// from the browser. Same SHELL_FILES, same reasoning as v2-v13.
//
// v15 (2026-08-29): iOS "Add to Home Screen" was showing a generic icon —
// index.html's apple-touch-icon was a 1x1 transparent placeholder and the
// manifest was an inline data: URI with no icons declared at all. Fixed
// with real icon files (apple-touch-icon.png, icon-192.png, icon-512.png,
// favicon-32x32.png) and an external manifest.webmanifest (replacing the
// inline data: URI so it can declare real icon src paths). SHELL_FILES
// DOES change this time — these 5 new files are added below — which is
// exactly the case this version-bump convention exists for (unlike v2-v14,
// which only changed content of files already on the list).
//
// v16 (2026-09-01, Phase 1 — AirValet V2 shell/layout/navigation):
// index.html/styles.css changed — :root color tokens repainted to the
// approved V2 palette (--tv-* tokens/every .tv-* rule untouched, verified
// not to inherit from anything changed here), a new desktop-only
// (>=1101px) fixed left sidebar replacing the horizontal .tabs bar (CSS
// only — no DOM reordering, so every modal and #tvMode, both
// position:fixed, are unaffected), and the .tabs children regrouped into
// Operations/Management/Administration. At <=1100px the original
// horizontal tab bar is pixel-identical to before. No JS logic changed.
// v19: Mockup 2 branding — logo-icon.png (Canva brand-kit asset, copied
// unmodified from the approved mockup) now used on the login screen,
// the desktop sidebar brand header, and the favicon, replacing the
// text-only "AirValet" treatment in those 3 spots. NEW FILE added to
// SHELL_FILES (./assets/logo-icon.png) — this bump is required, not
// optional, since cache.addAll() only ever fetches what's listed at
// install time; without bumping, an already-installed device would
// keep serving the old shell indefinitely and never precache the new
// asset. The other 3 brand-kit variants (logo-horizontal/stacked/
// wordmark.png) were copied into ./assets/ for future use but are not
// referenced by any current page, so they're deliberately not added
// here.
// v20: responsive-fix — the fixed sidebar (previously >=1101px) was
// too wide for real iPads (landscape CSS width often exceeds that
// threshold) and cramped the main content. Replaced with an
// off-canvas drawer for every width below true desktop (now 1280px):
// hamburger button in the header, backdrop, auto-close on nav-item
// select, drawer closes on backdrop tap. True desktop (>=1280px)
// keeps the exact same always-visible fixed sidebar as before, just
// at a higher breakpoint. No new files added to SHELL_FILES — only
// index.html/styles.css content changed.
// v21: TV Mode visual-only refresh — real AirValet logo (assets/
// logo-icon.png, in a white contrast chip since the mark is navy/blue
// and would vanish directly on the dark header gradient) replacing the
// old plane-emoji brand text, and TV's own typography swapped to match
// the rest of the app (Syne->Sora, DM Mono->JetBrains Mono, DM Sans->
// Inter). No TV business logic, RPC, data, timing, or fit/pagination
// code touched — confirmed via diff: every changed CSS line is a
// font-family value or the one new logo-badge rule, nothing else.
// v22: cache-version bump only — commit 68f45ee (passenger filters +
// default Pending view) changed index.html content but didn't bump this,
// so already-installed devices would have kept serving the old shell
// indefinitely. Bumping now so the normal Update Available flow picks
// up that commit's changes. No other file touched.
var CACHE_VERSION = 'v22';
var CACHE_NAME = 'airvalet-shell-' + CACHE_VERSION;

// Resolved relative to this file's own location, so they land in the
// correct GitHub Pages subpath automatically.
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
