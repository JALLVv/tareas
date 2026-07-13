-- =====================================================================
-- Recordatorios push programados (avisan aunque la app esté CERRADA)
-- Ejecuta TODO este archivo una vez en: Supabase → SQL Editor.
--
-- Cómo funciona:
--   1) La app guarda cada recordatorio en la tabla `reminders` (hora local +
--      qué días toca + tu zona horaria).
--   2) Un cron (pg_cron) ejecuta cada minuto `send_due_reminders()`, que busca
--      los recordatorios que "tocan" en este minuto y llama a tu Edge Function
--      `send-push` (la misma que ya usan los avisos de amigos) para enviar el
--      push a los dispositivos suscritos del usuario.
--
-- SEGURIDAD: NO se usa la service_role key (privada). Solo la ANON key, que es
-- PÚBLICA por diseño (ya va incrustada en la app) y es segura de publicar. El
-- trabajo con permisos (leer suscripciones, firmar el push) lo hace la Edge
-- Function send-push con SU propia clave privada, que Supabase le da como
-- variable de entorno — nunca sale del servidor ni entra al repositorio.
-- La URL del proyecto y la anon key de abajo ya son las tuyas.
-- =====================================================================

-- Extensiones necesarias (en Supabase suelen estar disponibles).
create extension if not exists pg_cron;
create extension if not exists pg_net;

-- ---------------------------------------------------------------------
-- Tabla de recordatorios
-- ---------------------------------------------------------------------
create table if not exists public.reminders (
  user_id     uuid    not null,
  task_id     text    not null,
  title       text    not null,
  hh          int     not null,               -- hora local 0-23
  mm          int     not null,               -- minuto 0-59
  kind        text    not null default 'daily',-- daily | weekly | monthly | date | once
  dow         int[]   not null default '{}',  -- días de semana 0=Dom..6=Sab (weekly)
  dom         int[]   not null default '{}',  -- días del mes 1-31 (monthly)
  on_date     date,                           -- fecha concreta (date | once)
  tz_offset   int     not null default 0,     -- getTimezoneOffset() en minutos (UTC-local)
  active      boolean not null default true,
  updated_at  timestamptz not null default now(),
  primary key (user_id, task_id)
);

alter table public.reminders enable row level security;

-- Cada quien gestiona SOLO sus recordatorios.
drop policy if exists reminders_own on public.reminders;
create policy reminders_own on public.reminders
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- ---------------------------------------------------------------------
-- Función que envía los recordatorios que tocan en este minuto.
-- Calcula la hora LOCAL de cada usuario con su tz_offset (minutos) y compara.
-- ---------------------------------------------------------------------
create or replace function public.send_due_reminders()
returns void
language plpgsql
security definer
as $$
declare
  r        record;
  loc      timestamp;     -- "ahora" en la hora LOCAL del usuario (sin tz, comparación directa)
  ldow     int;
  ldom     int;
  ldate    date;
  proj_url text := 'https://muvqfjyzneszkptsjxgi.supabase.co';
  -- ANON key (PÚBLICA, la misma de la app). Segura de publicar: solo sirve para
  -- INVOCAR la Edge Function; el envío del push lo hace ella con su clave privada.
  anon_key text := 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im11dnFmanl6bmVzemtwdHNqeGdpIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODI3MDI0NjIsImV4cCI6MjA5ODI3ODQ2Mn0.Ud4QhDc2EsTKPQoHtEaubH3jMTppI4CKDZKZqGf2Uao';
begin
  for r in select * from public.reminders where active loop
    -- hora local del usuario = ahora (UTC) menos su offset (minutos)
    loc  := now() at time zone 'UTC' - make_interval(mins => r.tz_offset);
    if extract(hour from loc)::int <> r.hh or extract(minute from loc)::int <> r.mm then
      continue;
    end if;
    ldow  := extract(dow  from loc)::int;   -- 0=Dom..6=Sab
    ldom  := extract(day  from loc)::int;
    ldate := loc::date;

    if     r.kind = 'daily'   then null;                                   -- todos los días
    elsif  r.kind = 'weekly'  then if not (r.dow @> array[ldow]) and array_length(r.dow,1) is not null then continue; end if;
    elsif  r.kind = 'monthly' then if not (r.dom @> array[ldom]) and array_length(r.dom,1) is not null then continue; end if;
    elsif  r.kind in ('date','once') then if r.on_date is distinct from ldate then continue; end if;
    end if;

    -- Llama a la Edge Function send-push (misma que los avisos de amigos).
    perform net.http_post(
      url     := proj_url || '/functions/v1/send-push',
      headers := jsonb_build_object(
                   'Content-Type','application/json',
                   'apikey', anon_key,
                   'Authorization','Bearer ' || anon_key),
      body    := jsonb_build_object(
                   'recipientId', r.user_id,
                   'title', '🛎️ Recordatorio',
                   'body', r.title,
                   'tag', 'reminder-' || r.task_id,   -- mismo tag = el sistema fusiona duplicados en uno
                   'url', './')
    );
  end loop;
end;
$$;

-- ---------------------------------------------------------------------
-- RESUMEN SEMANAL con la app CERRADA: cada lunes a las 9:00 (hora LOCAL de
-- cada usuario, según profiles.tz_offset), si tuvo actividad la semana pasada,
-- inserta el aviso 'weekly_summary'. El push lo manda el trigger existente
-- (trg_send_push_notification) al insertarse la fila. Idempotente por semana
-- (ref_key = lunes de la semana terminada): si la app ya lo creó al abrirse
-- (o al revés), el otro camino no lo repite.
-- ---------------------------------------------------------------------
create or replace function public.send_weekly_summaries()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  p    record;
  loc  timestamp;   -- "ahora" en la hora local del usuario
  wk   date;        -- lunes de la semana TERMINADA
begin
  for p in select id, name, coalesce(tz_offset,0) as tz from public.profiles loop
    loc := (now() at time zone 'UTC') - make_interval(mins => p.tz);
    -- lunes (dow=1) a las 09:00 local
    if extract(dow from loc)::int <> 1 or extract(hour from loc)::int <> 9 or extract(minute from loc)::int <> 0 then
      continue;
    end if;
    wk := loc::date - 7;   -- hoy es lunes → el lunes anterior abre la semana terminada
    -- solo si hubo actividad esa semana
    if not exists (
      select 1 from public.completions
      where user_id = p.id and date >= to_char(wk,'YYYY-MM-DD') and date <= to_char(wk+6,'YYYY-MM-DD')
    ) then continue; end if;
    -- idempotente: no repetir el aviso de esa semana
    if exists (
      select 1 from public.notifications
      where recipient_id = p.id and type = 'weekly_summary' and ref_key = to_char(wk,'YYYY-MM-DD')
    ) then continue; end if;
    begin
      insert into public.notifications(recipient_id, actor_id, actor_name, type, task_title, ref_key)
      values (p.id, p.id, coalesce(p.name,'Atleta'), 'weekly_summary', '', to_char(wk,'YYYY-MM-DD'));
    exception when others then null;
    end;
  end loop;
end;
$$;

-- ---------------------------------------------------------------------
-- Programa los crons: cada minuto.
-- ---------------------------------------------------------------------
select cron.unschedule('send_due_reminders')
  where exists (select 1 from cron.job where jobname = 'send_due_reminders');

select cron.schedule('send_due_reminders', '* * * * *', $$ select public.send_due_reminders(); $$);

select cron.unschedule('send_weekly_summaries')
  where exists (select 1 from cron.job where jobname = 'send_weekly_summaries');

select cron.schedule('send_weekly_summaries', '* * * * *', $$ select public.send_weekly_summaries(); $$);
