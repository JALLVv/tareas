# Rachas · Tareas

Aplicación web (PWA) con estética **iOS en modo oscuro**: glassmorphism, blur, tipografía estilo San Francisco, Tab Bar inferior y animaciones fluidas. Genera tareas aleatorias, crea las tuyas, súbelas con foto de evidencia y acumula puntos, rangos y rachas diarias.

Todo funciona **sin conexión y sin servidor**: los datos se guardan en tu dispositivo (localStorage para el estado y IndexedDB para las fotos). No se envía nada a internet.

---

## Cómo abrirla

### Opción A — Probarla rápido (escritorio o móvil)
Abre `index.html` directamente en el navegador (doble clic). Funciona todo: generar tareas, crearlas, completarlas con foto, puntos, rangos, rachas, calendario y galería.

> Nota: al abrir con `file://`, el navegador **no** registra el Service Worker (es una restricción de seguridad de Safari/Chrome). La app igual funciona; solo no queda cacheada como instalable. Para la experiencia PWA completa, usa la Opción B.

### Opción B — Instalarla en el iPhone (PWA completa)
1. Sube la carpeta completa a cualquier hosting estático gratuito (Netlify, GitHub Pages, Vercel, Cloudflare Pages…). Debe servirse por **https**.
2. Abre la URL en **Safari** en el iPhone.
3. Pulsa **Compartir** → **Añadir a pantalla de inicio**.
4. Ábrela desde el icono: se verá a pantalla completa, respetando notch, Dynamic Island y safe areas, y quedará disponible offline.

---

## Estructura

```
index.html          App completa (HTML + CSS + JS en un solo archivo, internamente modular)
manifest.json       Metadatos PWA (nombre, colores, iconos)
service-worker.js   Caché offline del app-shell (solo activo por http/https)
icons/              Iconos de la app (192, 512, maskable, apple-touch 180)
```

El JavaScript dentro de `index.html` está organizado en módulos independientes (Icons, DB, Store, Gamify, Generator, Router, Sheets, Tasks, Profile, Lightbox, UI). Se entregó en un único archivo a propósito: los módulos ES (`import`) no cargan desde `file://` en Safari, así que esta forma permite **abrir el archivo y que funcione** y, a la vez, instalarlo como PWA.

---

## Personalización rápida

- **Añadir una categoría:** agrégala en el objeto `TASK_BANK` (nombre + lista de plantillas de tarea) y, si quieres icono propio, en el módulo `Icons`. Aparece automáticamente en el generador y en el formulario de crear tarea.
- **Ajustar puntos:** la fórmula es `minutos × 2` (el doble si la tarea es aleatoria).
- **Ajustar rangos:** edita la tabla de rangos (Principiante → Leyenda) con sus umbrales de puntos.

---

## Notas

- La cámara/galería usa el selector de fotos nativo del sistema; en iPhone permite **Tomar foto** o **Elegir de la fototeca**.
- Si borras los datos del navegador o usas modo privado, se pierde el progreso (todo es local).
