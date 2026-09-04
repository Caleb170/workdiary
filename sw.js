// Cache only the public app shell. User data remains in Supabase/local storage.
const SHELL_CACHE='hourfolio-shell-v1';
const SHELL=['./index.html','./manifest.json','./hourfolio-icon.svg','./hourfolio-icon-192.png','./hourfolio-icon-512.png'];
self.addEventListener('install',event=>event.waitUntil(caches.open(SHELL_CACHE).then(cache=>cache.addAll(SHELL)).then(()=>self.skipWaiting())));
self.addEventListener('activate',event=>event.waitUntil(caches.keys().then(keys=>Promise.all(keys.filter(key=>key!==SHELL_CACHE).map(key=>caches.delete(key)))).then(()=>self.clients.claim())));
self.addEventListener('fetch',event=>{
  if(event.request.method!=='GET'||new URL(event.request.url).origin!==self.location.origin)return;
  event.respondWith(fetch(event.request).then(response=>{if(response.ok&&event.request.mode==='navigate')caches.open(SHELL_CACHE).then(cache=>cache.put('./index.html',response.clone()));return response;}).catch(()=>caches.match(event.request).then(hit=>hit||caches.match('./index.html'))));
});
