// AirValet app-shell service worker
// v29 (2026-09-06): refresh precached shell after Dashboard opacity hotfix.
// Scope: same-origin shell files only. Supabase/API requests are never intercepted.

var CACHE_VERSION = 'v29';
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
  event.waitUntil(
    caches.open(CACHE_NAME).then(function(cache){
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
