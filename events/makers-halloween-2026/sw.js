// Halloween Valet — operator alerts (Web Push). Scope: /events/makers-halloween-2026/
// Separate from the main AirValet service worker; no caching, no fetch handler.
self.addEventListener('install', function(){ self.skipWaiting(); });
self.addEventListener('activate', function(e){ e.waitUntil(self.clients.claim()); });

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
