/* Rachas · Tareas — Service Worker
   App-shell offline caching. The app stores all user data in
   localStorage + IndexedDB, so caching the shell is enough to run offline. */

const CACHE = "rachas-v68";

const SHELL = [
  "./",
  "./index.html",
  "./manifest.json",
  "./supabase.js",
  "./icons/icon-192.png",
  "./icons/icon-512.png",
  "./icons/icon-maskable-512.png",
  "./icons/apple-touch-icon.png",
];

// Pre-cache the app shell on install.
self.addEventListener("install", (event) => {
  event.waitUntil(
    caches.open(CACHE).then((cache) => cache.addAll(SHELL)).then(() => self.skipWaiting())
  );
});

// Drop old caches on activate.
self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

// Cache-first for same-origin GET requests, with a network fallback that
// refreshes the cache. Navigations fall back to the cached index.html offline.
self.addEventListener("fetch", (event) => {
  const { request } = event;
  if (request.method !== "GET" || new URL(request.url).origin !== self.location.origin) return;

  event.respondWith(
    caches.match(request).then((cached) => {
      if (cached) return cached;
      return fetch(request)
        .then((resp) => {
          const copy = resp.clone();
          caches.open(CACHE).then((cache) => cache.put(request, copy)).catch(() => {});
          return resp;
        })
        .catch(() => {
          if (request.mode === "navigate") return caches.match("./index.html");
        });
    })
  );
});

// --- Push en segundo plano (app cerrada) --------------------------------
// La Edge Function "send-push" envía un JSON: { title, body, photo, url }.
self.addEventListener("push", (event) => {
  let data = {};
  try { data = event.data ? event.data.json() : {}; } catch (e) {
    try { data = { body: event.data && event.data.text() }; } catch (_) {}
  }
  const title = data.title || "Tareas";
  const options = {
    body: data.body || "Tienes una nueva notificación",
    icon: "./icons/icon-192.png",
    badge: "./icons/icon-192.png",
    tag: data.tag || undefined,
    data: { url: data.url || "./" },
  };
  if (data.photo) options.image = data.photo; // foto de la tarea, formato calendario
  event.waitUntil(self.registration.showNotification(title, options));
});

// Al tocar la notificación: enfoca la app (o la abre) en la sección.
self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  const target = (event.notification.data && event.notification.data.url) || "./";
  event.waitUntil(
    self.clients.matchAll({ type: "window", includeUncontrolled: true }).then((list) => {
      for (const c of list) {
        if ("focus" in c) return c.focus();
      }
      if (self.clients.openWindow) return self.clients.openWindow(target);
    })
  );
});
