/* Rachas · Tareas — Service Worker
   App-shell offline caching. The app stores all user data in
   localStorage + IndexedDB, so caching the shell is enough to run offline. */

const CACHE = "rachas-v123";

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
// La Edge Function "send-push" envía un JSON: { title, body, photo, url, tag }.
// ANTIDUPLICADOS: el aviso puede llegar por más de un camino a la vez (trigger
// del servidor + envío de respaldo desde el dispositivo del que actuó). Todos
// usan el mismo "tag"; si no viene, se deriva del CONTENIDO (título+cuerpo por
// ventana de ~1 min). Con el mismo tag, el sistema funde los avisos en UNO.
function contentTag(title, body) {
  const s = String(title) + "|" + String(body) + "|" + Math.floor(Date.now() / 60000);
  let h = 0;
  for (let i = 0; i < s.length; i++) { h = ((h << 5) - h + s.charCodeAt(i)) | 0; }
  return "c" + (h >>> 0).toString(36);
}
self.addEventListener("push", (event) => {
  let data = {};
  try { data = event.data ? event.data.json() : {}; } catch (e) {
    try { data = { body: event.data && event.data.text() }; } catch (_) {}
  }
  const title = data.title || "Tareas";
  const body = data.body || "Tienes una nueva notificación";
  event.waitUntil((async () => {
    let tag = data.tag || contentTag(title, body);
    // Refuerzo extra: si YA hay una notificación visible con el mismo texto,
    // reutiliza su tag para REEMPLAZARLA en vez de añadir una segunda (cubre
    // el caso de que los dos caminos lleguen con tags distintos).
    try {
      const existing = await self.registration.getNotifications();
      const dup = existing.find((n) => n.title === title && n.body === body);
      if (dup && dup.tag) tag = dup.tag;
    } catch (_) {}
    const options = {
      body,
      icon: "./icons/icon-192.png",
      badge: "./icons/icon-192.png",
      tag,
      data: { url: data.url || "./" },
    };
    if (data.photo) options.image = data.photo; // foto de la tarea, formato calendario
    await self.registration.showNotification(title, options);
  })());
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

// --- Renovación de la suscripción push -----------------------------------
// El navegador puede invalidar/rotar la suscripción por su cuenta (rotación de
// claves, limpieza del sistema, etc.) y avisa con este evento. Si no
// reaccionamos, la app se queda "suscrita" a un endpoint muerto para siempre.
// Volvemos a suscribirnos con la misma clave VAPID y avisamos a las páginas
// abiertas para que guarden la nueva suscripción en Supabase (el service
// worker no tiene sesión propia para hacerlo él solo).
const VAPID_PUBLIC = "BALkr9K1ATw7s5_C4jOzRk6TX8-bVL-BuYsNxHF3miixd2r9s-cHeFcsNkrpWo67Ouq53s2Pbx7dxWf8L66-W7Q";
function urlB64ToUint8(base64) {
  const pad = "=".repeat((4 - (base64.length % 4)) % 4);
  const b = (base64 + pad).replace(/-/g, "+").replace(/_/g, "/");
  const raw = atob(b);
  const out = new Uint8Array(raw.length);
  for (let i = 0; i < raw.length; i++) out[i] = raw.charCodeAt(i);
  return out;
}
self.addEventListener("pushsubscriptionchange", (event) => {
  event.waitUntil(
    self.registration.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: urlB64ToUint8(VAPID_PUBLIC) })
      .then(() => self.clients.matchAll({ type: "window", includeUncontrolled: true }))
      .then((list) => list.forEach((c) => c.postMessage({ type: "push-resubscribed" })))
      .catch(() => {})
  );
});
