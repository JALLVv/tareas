-- =====================================================================
-- DIAGNÓSTICO DEL PUSH
-- Ejecuta este archivo entero en el SQL Editor de Supabase. No cambia
-- nada: solo mira y te dice qué eslabón de la cadena está roto.
--
-- La cadena de un aviso real (el de "un amigo te comentó") es:
--    comentario → trigger notify_comment → fila en notifications
--                → trigger send_push_for_notification → pg_net → send-push
-- Basta con que falle UNO para que no llegue nada, y todos fallan en
-- silencio: los triggers se tragan sus errores para no bloquear la app.
-- =====================================================================

select '1. pg_net instalado (sin esto NINGÚN push sale del servidor)' as comprobacion,
       case when exists (select 1 from pg_extension where extname='pg_net')
            then '✅ sí' else '❌ NO — instálalo en Database → Extensions → pg_net' end as resultado
union all
select '2. secreto push_hook_secret configurado',
       case when coalesce((select value from public.app_config where key='push_hook_secret'),'') <> ''
            then '✅ sí' else '❌ NO — la función send-push rechazará las llamadas del servidor' end
union all
select '3. trigger que crea el aviso al comentar',
       case when exists (select 1 from pg_trigger where tgname='trg_notify_comment' and not tgisinternal)
            then '✅ sí' else '❌ falta trg_notify_comment' end
union all
select '4. trigger que envía el push al crearse el aviso',
       case when exists (select 1 from pg_trigger where tgname='trg_send_push_notification' and not tgisinternal)
            then '✅ sí' else '❌ falta trg_send_push_notification' end
union all
select '5. dispositivos suscritos a push (los tuyos y los de tus amigos)',
       case when (select count(*) from public.push_subscriptions) > 0
            then '✅ ' || (select count(*)::text from public.push_subscriptions) || ' suscripción(es)'
            else '❌ ninguna — nadie recibirá push hasta activarlo en el móvil' end
union all
select '6. avisos creados en las últimas 24 h',
       coalesce((select count(*)::text from public.notifications where created_at > now() - interval '24 hours'),'0')
       || ' (si aquí hay avisos pero no te llegaron, el fallo está entre el 1 y el 2)'
union all
select '7. llamadas de pg_net en la última hora',
       case when exists (select 1 from pg_extension where extname='pg_net')
            then coalesce((select count(*)::text from net._http_response where created > now() - interval '1 hour'), 'sin registro')
            else 'n/a (pg_net no instalado)' end;

-- Detalle de los últimos avisos: si tienen fila pero no llegó el push, el
-- problema está en pg_net o en el secreto, no en la app.
select created_at, type, actor_name, recipient_id
  from public.notifications
 order by created_at desc
 limit 10;

-- Últimas respuestas de pg_net: aquí se ve si send-push devolvió error.
-- (Si pg_net no está instalado, esta consulta dará error: es el punto 1.)
select id, status_code, left(coalesce(content,''), 200) as respuesta, created
  from net._http_response
 order by created desc
 limit 10;
