// Halloween Valet — operator alerts (Web Push) + offline start of the staff page.
// Scope: /events/makers-halloween-2026/ — separate from the main AirValet worker.
// Network first (always the newest page); the cached copy is used only when
// there is no connection, so the app still opens and can check in offline.
var CACHE = 'ev-halloween-2026-v1';
var SHELL = ['/events/makers-halloween-2026/', '/vendor/supabase.js', '/events/makers-halloween-2026/manifest.webmanifest',
  '/icon-192.png', '/favicon-32x32.png', '/apple-touch-icon.png'];
self.addEventListener('install', function(e){
  e.waitUntil(caches.open(CACHE).then(function(c){ return c.addAll(SHELL); }).catch(function(){}).then(function(){ return self.skipWaiting(); }));
});
self.addEventListener('activate', function(e){
  e.waitUntil(caches.keys().then(function(keys){
    return Promise.all(keys.filter(function(k){ return k.indexOf('ev-halloween-') === 0 && k !== CACHE; }).map(function(k){ return caches.delete(k); }));
  }).then(function(){ return self.clients.claim(); }));
});
self.addEventListener('fetch', function(event){
  var req = event.request, url = new URL(req.url);
  if (req.method !== 'GET' || url.origin !== self.location.origin) return;            // API, printer: never touched
  var isPage = req.mode === 'navigate' && url.pathname.indexOf('/events/makers-halloween-2026') === 0 && url.pathname.indexOf('/t') < 0;
  if (!isPage && SHELL.indexOf(url.pathname) < 0) return;
  event.respondWith(fetch(req).then(function(res){
    if (res && res.ok) { var copy = res.clone(); caches.open(CACHE).then(function(c){ c.put(isPage ? '/events/makers-halloween-2026/' : url.pathname, copy); }); }
    return res;
  }).catch(function(){
    return caches.match(isPage ? '/events/makers-halloween-2026/' : url.pathname).then(function(hit){ return hit || Response.error(); });
  }));
});

self.addEventListener('push', function(event){
  var d = {};
  try { d = event.data ? event.data.json() : {}; } catch (e) { d = { title: 'Halloween Valet', body: event.data ? event.data.text() : '' }; }
  event.waitUntil(self.registration.showNotification(d.title || '🚗 Car requested', {
    body: d.body || '', tag: d.tag || 'halloween-valet', renotify: true,
    icon: '/icon-192.png', badge: '/favicon-32x32.png',
    data: { url: d.url || '/events/makers-halloween-2026/' }
  }));
});

self.addEventListener('notificationclick', function(event){
  event.notification.close();
  var url = (event.notification.data && event.notification.data.url) || '/events/makers-halloween-2026/';
  event.waitUntil(self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then(function(list){
    for (var i = 0; i < list.length; i++) {
      if (list[i].url.indexOf('/events/makers-halloween-2026') >= 0 && 'focus' in list[i]) return list[i].focus();
    }
    return self.clients.openWindow(url);
  }));
});
