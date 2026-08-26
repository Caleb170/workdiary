// Minimal service worker — required for "Add to Home Screen" to behave like
// an installed app on some platforms. Deliberately does NOT cache app files,
// since WorkQuest's data model relies on always talking to Supabase directly;
// aggressive caching here could serve a stale version of the app shell.
self.addEventListener('install', (e) => { self.skipWaiting(); });
self.addEventListener('activate', (e) => { self.clients.claim(); });
self.addEventListener('fetch', (e) => { /* pass-through, no caching */ });
