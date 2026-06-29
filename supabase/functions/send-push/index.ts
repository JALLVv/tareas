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

const VAPID_PUBLIC  = Deno.env.get("VAPID_PUBLIC_KEY")  ?? "";
const VAPID_PRIVATE = Deno.env.get("VAPID_PRIVATE_KEY") ?? "";
const VAPID_SUBJECT = Deno.env.get("VAPID_SUBJECT") ?? "mailto:admin@example.com";

webpush.setVapidDetails(VAPID_SUBJECT, VAPID_PUBLIC, VAPID_PRIVATE);

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });

  try {
    const { recipientId, title, body, photo, url } = await req.json();
    if (!recipientId) {
      return new Response(JSON.stringify({ error: "recipientId requerido" }), {
        status: 400, headers: { ...CORS, "Content-Type": "application/json" },
      });
    }

    // Cliente con service role: lee suscripciones saltándose RLS.
    const admin = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );

    const { data: subs, error } = await admin
      .from("push_subscriptions")
      .select("endpoint, subscription")
      .eq("user_id", recipientId);
    if (error) throw error;

    const payload = JSON.stringify({
      title: title || "Tareas",
      body: body || "Tienes una nueva notificación",
      photo: photo || null,
      url: url || "./",
    });

    let sent = 0;
    await Promise.all((subs ?? []).map(async (row: any) => {
      try {
        await webpush.sendNotification(row.subscription, payload);
        sent++;
      } catch (e: any) {
        // 404/410 => la suscripción ya no es válida: bórrala.
        if (e?.statusCode === 404 || e?.statusCode === 410) {
          await admin.from("push_subscriptions").delete().eq("endpoint", row.endpoint);
        }
      }
    }));

    return new Response(JSON.stringify({ ok: true, sent }), {
      headers: { ...CORS, "Content-Type": "application/json" },
    });
  } catch (e: any) {
    return new Response(JSON.stringify({ error: String(e?.message ?? e) }), {
      status: 500, headers: { ...CORS, "Content-Type": "application/json" },
    });
  }
});
