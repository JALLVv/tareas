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
-- REQUISITO: pon abajo la URL de tu proyecto y la SERVICE ROLE KEY (donde dice
-- <<<...>>>). La service role key está en: Ajustes → API → service_role.
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
  loc      timestamptz;   -- "ahora" en la hora local del usuario
  ldow     int;
  ldom     int;
  ldate    date;
  proj_url text := '<<<PROJECT_URL>>>';        -- p.ej. https://xxxx.supabase.co
  svc_key  text := '<<<SERVICE_ROLE_KEY>>>';   -- service_role (secreta)
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
                   'Authorization','Bearer ' || svc_key),
      body    := jsonb_build_object(
                   'recipientId', r.user_id,
                   'title', '🛎️ Recordatorio',
                   'body', r.title,
                   'url', './')
    );
  end loop;
end;
$$;

-- ---------------------------------------------------------------------
-- Programa el cron: cada minuto.
-- ---------------------------------------------------------------------
select cron.unschedule('send_due_reminders')
  where exists (select 1 from cron.job where jobname = 'send_due_reminders');

select cron.schedule('send_due_reminders', '* * * * *', $$ select public.send_due_reminders(); $$);
