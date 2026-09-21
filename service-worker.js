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

var CACHE_VERSION = 'v32';
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
  './offline-db.js'
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

  if(!isShellRequest) return;

  event.respondWith(
    caches.match(event.request, {cacheName: CACHE_NAME}).then(function(cached){
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
