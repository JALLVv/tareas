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

-- =====================================================================
-- 4) ÚLTIMO PASO (en el panel, no en SQL):
--    Authentication → Sign In / Providers → activa "Anonymous sign-ins".
--    Sin esto, la app no podrá iniciar sesión anónima y la nube no funcionará.
-- =====================================================================
