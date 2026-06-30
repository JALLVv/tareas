-- =====================================================================
-- Rachas · Tareas — Configuración de Supabase para "amigos en la nube"
-- Ejecuta TODO esto una vez en: Supabase → SQL Editor → New query → Run.
-- Después, activa la autenticación anónima (ver el paso de abajo).
-- =====================================================================

-- 1) PERFILES ---------------------------------------------------------
create table if not exists public.profiles (
  id             uuid primary key,
  name           text,
  avatar_url     text,
  points         int  default 0,
  streak_current int  default 0,
  streak_best    int  default 0,
  updated_at     timestamptz default now()
);

alter table public.profiles enable row level security;

drop policy if exists "profiles_read"   on public.profiles;
drop policy if exists "profiles_insert" on public.profiles;
drop policy if exists "profiles_update" on public.profiles;

-- Cualquier usuario autenticado puede leer perfiles (para ver a los amigos).
create policy "profiles_read"   on public.profiles for select to authenticated using (true);
-- Solo puedes crear/editar tu propio perfil.
create policy "profiles_insert" on public.profiles for insert to authenticated with check (auth.uid() = id);
create policy "profiles_update" on public.profiles for update to authenticated using (auth.uid() = id);

-- 2) COMPLETADAS (tareas con foto) -----------------------------------
create table if not exists public.completions (
  id         text primary key,            -- id de la app (texto)
  user_id    uuid references public.profiles(id) on delete cascade,
  date       date,
  title      text,
  category   text,
  points     int,
  time       text,
  photo_url  text,
  created_at timestamptz default now()
);

-- Para tareas compartidas: con quién se completó (se muestra «con X» / «contigo»).
alter table public.completions add column if not exists partner_id   uuid;
alter table public.completions add column if not exists partner_name text;
-- Id de la tarea compartida (para limpiar la completada cuando se borra la tarea).
alter table public.completions add column if not exists shared_id    text;

alter table public.completions enable row level security;

drop policy if exists "completions_read"   on public.completions;
drop policy if exists "completions_insert" on public.completions;
drop policy if exists "completions_update" on public.completions;
drop policy if exists "completions_delete" on public.completions;

create policy "completions_read"   on public.completions for select to authenticated using (true);
create policy "completions_insert" on public.completions for insert to authenticated with check (auth.uid() = user_id);
create policy "completions_update" on public.completions for update to authenticated using (auth.uid() = user_id);
create policy "completions_delete" on public.completions for delete to authenticated using (auth.uid() = user_id);

-- 3) STORAGE: bucket público "photos" --------------------------------
insert into storage.buckets (id, name, public)
values ('photos', 'photos', true)
on conflict (id) do update set public = true;

drop policy if exists "photos_read"   on storage.objects;
drop policy if exists "photos_insert" on storage.objects;
drop policy if exists "photos_update" on storage.objects;
drop policy if exists "photos_delete" on storage.objects;

-- Lectura pública (para mostrar avatar y fotos de los amigos).
create policy "photos_read"   on storage.objects for select using (bucket_id = 'photos');
-- Solo puedes subir/actualizar/borrar fotos dentro de tu propia carpeta (tu uid).
create policy "photos_insert" on storage.objects for insert to authenticated
  with check (bucket_id = 'photos' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "photos_update" on storage.objects for update to authenticated
  using (bucket_id = 'photos' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "photos_delete" on storage.objects for delete to authenticated
  using (bucket_id = 'photos' and (storage.foldername(name))[1] = auth.uid()::text);

-- 4) TAREAS COMPARTIDAS ------------------------------------------------
create table if not exists public.shared_tasks (
  id           text primary key,
  owner_id     uuid, owner_name text,
  partner_id   uuid, partner_name text,
  title        text, descr text, category text, minutes int, people int, urgent bool,
  recurrence   jsonb, only_on_days bool,
  status       text default 'pending',   -- pending | done
  completed_by uuid, photo_url text, points int, done_date date, done_time text,
  created_at   timestamptz default now()
);
alter table public.shared_tasks enable row level security;
drop policy if exists "shared_read"   on public.shared_tasks;
drop policy if exists "shared_insert" on public.shared_tasks;
drop policy if exists "shared_update" on public.shared_tasks;
drop policy if exists "shared_delete" on public.shared_tasks;
-- Los dos implicados (dueño y compañero) pueden ver/editar/borrar.
create policy "shared_read"   on public.shared_tasks for select to authenticated using (auth.uid() = owner_id or auth.uid() = partner_id);
create policy "shared_insert" on public.shared_tasks for insert to authenticated with check (auth.uid() = owner_id);
create policy "shared_update" on public.shared_tasks for update to authenticated using (auth.uid() = owner_id or auth.uid() = partner_id);
create policy "shared_delete" on public.shared_tasks for delete to authenticated using (auth.uid() = owner_id or auth.uid() = partner_id);

-- 4b) LIMPIEZA AUTOMÁTICA AL BORRAR UNA TAREA COMPARTIDA ----------------
-- Cuando se borra una tarea compartida, este trigger (SECURITY DEFINER: corre
-- con permisos elevados, salta RLS) elimina la completada del OTRO implicado y
-- recalcula sus puntos y racha en la nube, SIN que su app tenga que abrirse.
-- Así, si tú borras una compartida que tu amigo completó, su perfil se
-- actualiza solo y todos lo ven al instante. Al que la borra (auth.uid()) no se
-- le toca aquí: su propia app ya ajusta sus datos.

-- Racha (actual y mejor) calculada desde las completadas de un usuario.
create or replace function public.calc_streak(p_uid uuid)
returns table(cur int, best int)
language sql
security definer
set search_path = public
as $$
  with dates as (
    select distinct date as d
    from public.completions
    where user_id = p_uid and date is not null
  ),
  grp as (
    select d, (d - (row_number() over (order by d))::int) as g from dates
  ),
  runs as (
    select count(*)::int as len, max(d) as end_d from grp group by g
  )
  select
    coalesce((select len from runs
              where end_d = current_date or end_d = current_date - 1
              order by len desc limit 1), 0) as cur,
    coalesce((select max(len) from runs), 0) as best;
$$;

create or replace function public.cleanup_shared_completions()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  u uuid;
  lost int;
  s record;
begin
  foreach u in array array[old.owner_id, old.partner_id]
  loop
    if u is null or u = auth.uid() then continue; end if;  -- al que borra no se le toca
    begin
      select coalesce(sum(points),0) into lost
        from public.completions
        where user_id = u and (id = 'sh_' || old.id or shared_id = old.id);
      delete from public.completions
        where user_id = u and (id = 'sh_' || old.id or shared_id = old.id);
      select * into s from public.calc_streak(u);
      update public.profiles set
        points         = greatest(0, coalesce(points,0) - coalesce(lost,0)),
        streak_current = coalesce(s.cur,0),
        streak_best    = coalesce(s.best,0),
        updated_at     = now()
        where id = u;
    exception when others then
      null;  -- si la limpieza de un usuario falla, no bloquear el borrado
    end;
  end loop;
  return old;
end;
$$;

drop trigger if exists trg_cleanup_shared on public.shared_tasks;
create trigger trg_cleanup_shared
  after delete on public.shared_tasks
  for each row execute function public.cleanup_shared_completions();

-- 5) NOTIFICACIONES ---------------------------------------------------
create table if not exists public.notifications (
  id          uuid default gen_random_uuid() primary key,
  recipient_id uuid, actor_id uuid, actor_name text,
  type        text,                      -- 'shared_added' | 'shared_done'
  task_title  text, photo_url text,
  created_at  timestamptz default now(), read boolean default false
);
alter table public.notifications enable row level security;
drop policy if exists "notif_read"   on public.notifications;
drop policy if exists "notif_insert" on public.notifications;
drop policy if exists "notif_update" on public.notifications;
drop policy if exists "notif_delete" on public.notifications;
create policy "notif_read"   on public.notifications for select to authenticated using (auth.uid() = recipient_id);
create policy "notif_insert" on public.notifications for insert to authenticated with check (auth.uid() = actor_id);   -- el actor crea la del destinatario
create policy "notif_update" on public.notifications for update to authenticated using (auth.uid() = recipient_id);   -- marcar como leída
create policy "notif_delete" on public.notifications for delete to authenticated using (auth.uid() = recipient_id);

-- 6) SUSCRIPCIONES DE PUSH (para notificaciones en segundo plano) ------
create table if not exists public.push_subscriptions (
  user_id    uuid, endpoint text primary key, subscription jsonb,
  updated_at timestamptz default now()
);
alter table public.push_subscriptions enable row level security;
drop policy if exists "push_all" on public.push_subscriptions;
-- Solo gestionas tus propias suscripciones (la Edge Function usa la service key).
create policy "push_all" on public.push_subscriptions for all to authenticated
  using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- =====================================================================
-- 7) ÚLTIMO PASO (en el panel, no en SQL):
--    Authentication → Sign In / Providers → activa "Anonymous sign-ins".
--    Sin esto, la app no podrá iniciar sesión anónima y la nube no funcionará.
-- =====================================================================
