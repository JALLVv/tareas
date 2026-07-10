// =====================================================================
// Edge Function: send-push
// Envía una notificación push (Web Push / VAPID) a TODOS los dispositivos
// suscritos de un usuario. La invoca la app cuando un amigo te añade a una
// tarea o la completa, para que el aviso llegue aunque la app esté cerrada.
//
// Despliegue (una sola vez):
//   1) Genera tus claves VAPID:  npx web-push generate-vapid-keys
//   2) Pon la PÚBLICA en index.html (const VAPID_PUBLIC = "...").
//   3) Guarda los secretos del proyecto:
//        supabase secrets set VAPID_PUBLIC_KEY="<pública>"
//        supabase secrets set VAPID_PRIVATE_KEY="<privada>"
//        supabase secrets set VAPID_SUBJECT="mailto:tu@correo.com"
//      (SUPABASE_URL y SUPABASE_SERVICE_ROLE_KEY ya existen por defecto.)
//   4) Despliega:  supabase functions deploy send-push
// =====================================================================
import { createClient } from "jsr:@supabase/supabase-js@2";
import webpush from "npm:web-push@3.6.7";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });

  const json = (obj: unknown, status = 200) =>
    new Response(JSON.stringify(obj), {
      status, headers: { ...CORS, "Content-Type": "application/json" },
    });

  try {
    // 1) Claves VAPID desde los secretos. Si faltan o son inválidas, lo decimos
    //    con un mensaje claro (en vez de que la función se caiga sin explicación).
    const VAPID_PUBLIC  = Deno.env.get("VAPID_PUBLIC_KEY")  ?? "";
    const VAPID_PRIVATE = Deno.env.get("VAPID_PRIVATE_KEY") ?? "";
    const VAPID_SUBJECT = Deno.env.get("VAPID_SUBJECT") ?? "mailto:admin@example.com";
    if (!VAPID_PUBLIC || !VAPID_PRIVATE) {
      return json({ error: "Faltan secretos: configura VAPID_PUBLIC_KEY y VAPID_PRIVATE_KEY en el proyecto." }, 500);
    }
    try {
      webpush.setVapidDetails(VAPID_SUBJECT, VAPID_PUBLIC, VAPID_PRIVATE);
    } catch (e) {
      return json({ error: "Claves VAPID inválidas (¿la pública y la privada son del MISMO par?): " + String((e as Error)?.message ?? e) }, 500);
    }

    // 2) Cuerpo de la petición.
    const { recipientId, title, body, photo, url, tag } = await req.json().catch(() => ({}));
    if (!recipientId) return json({ error: "recipientId requerido" }, 400);

    // 3) Suscripciones del destinatario (service role: salta RLS).
    const admin = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );
    const { data: subs, error } = await admin
      .from("push_subscriptions")
      .select("endpoint, subscription")
      .eq("user_id", recipientId);
    if (error) return json({ error: "Base de datos: " + error.message }, 500);
    if (!subs || subs.length === 0) {
      return json({ ok: true, sent: 0, note: "El destinatario no tiene dispositivos suscritos." });
    }

    // 4) Enviar a cada dispositivo. El "tag" permite al service worker fundir
    //    en UNO los avisos duplicados (mismo aviso llegando por dos caminos).
    const payload = JSON.stringify({
      title: title || "Tareas",
      body: body || "Tienes una nueva notificación",
      photo: photo || null,
      url: url || "./",
      tag: tag || null,
    });

    let sent = 0;
    const errors: string[] = [];
    await Promise.all(subs.map(async (row: any) => {
      try {
        await webpush.sendNotification(row.subscription, payload);
        sent++;
      } catch (e: any) {
        // 404/410 => la suscripción ya no es válida: bórrala.
        if (e?.statusCode === 404 || e?.statusCode === 410) {
          await admin.from("push_subscriptions").delete().eq("endpoint", row.endpoint);
        } else {
          errors.push(String(e?.body ?? e?.message ?? e));
        }
      }
    }));

    return json({ ok: true, sent, errors: errors.length ? errors : undefined });
  } catch (e: any) {
    return json({ error: String(e?.message ?? e) }, 500);
  }
});
