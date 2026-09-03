// A tiny pass-through service worker enables installed-app behavior without
// caching private Hourfolio data or leaving users on an outdated app shell.
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', event => event.waitUntil(self.clients.claim()));
self.addEventListener('fetch', () => {});
