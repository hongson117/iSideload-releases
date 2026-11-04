const CACHE = 'sicontainer-shortcuts-v5';
const SHELLS = ['go.html', 'shortcut.html', 'shortcut.js'];
const base = new URL('./', self.location.href);

self.addEventListener('install', event => {
  event.waitUntil(caches.open(CACHE).then(cache =>
    cache.addAll(SHELLS.map(name => new URL(name + '?v=5', base).href))
  ).then(() => self.skipWaiting()));
});

self.addEventListener('activate', event => {
  event.waitUntil(caches.keys().then(keys => Promise.all(keys
    .filter(key => key !== CACHE && (key.startsWith('sicontainer-go-') || key.startsWith('sicontainer-shortcuts-')))
    .map(key => caches.delete(key))
  )).then(() => self.clients.claim()));
});

self.addEventListener('fetch', event => {
  const url = new URL(event.request.url);
  const filename = SHELLS.find(name => url.pathname === new URL(name, base).pathname);
  if (event.request.method !== 'GET' || url.origin !== base.origin || !filename) return;
  const cacheKey = new URL(filename + '?v=5', base).href;
  event.respondWith(fetch(event.request, { cache: 'no-store' }).then(response => {
    if (!response.ok) throw new Error('Shortcut unavailable');
    const copy = response.clone();
    event.waitUntil(caches.open(CACHE).then(cache => cache.put(cacheKey, copy)));
    return response;
  }).catch(async () => {
    const cache = await caches.open(CACHE);
    const saved = await cache.match(cacheKey);
    if (saved) return saved;
    return new Response('Không tải được trang shortcut. Hãy kết nối mạng và mở lại từ SIContainer.', {
      status: 503,
      headers: { 'Content-Type': 'text/plain; charset=utf-8' }
    });
  }));
});
