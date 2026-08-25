-- =====================================================================
-- CUENTAS CON CORREO + SINCRONIZACIÓN CONTINUA
-- Ejecuta TODO este archivo una vez en: Supabase → SQL Editor.
--
-- Qué añade:
--   1) Una tabla `app_state` con UNA fila por usuario que guarda el estado
--      completo de la app (tareas, historial, puntos, racha, amigos…).
--   2) Permisos para que cada quien solo pueda leer y escribir SU fila.
--   3) Realtime sobre esa tabla, para que al cambiar algo en un dispositivo
--      los demás se enteren al instante en vez de esperar a un sondeo.
--
-- No hace falta ninguna clave privada: todo va con la sesión del usuario.
-- =====================================================================

create table if not exists public.app_state (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  data       jsonb       not null default '{}'::jsonb,
  rev        bigint      not null default 0,
  updated_at timestamptz not null default now()
);

alter table public.app_state enable row level security;

-- Cada usuario, y SOLO ese usuario, toca su fila.
drop policy if exists app_state_own on public.app_state;
create policy app_state_own on public.app_state
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- Realtime. Añadir una tabla dos veces a la publicación da error, así que se
-- comprueba antes: este archivo se puede volver a ejecutar sin romper nada.
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'app_state'
  ) then
    alter publication supabase_realtime add table public.app_state;
  end if;
end $$;

-- =====================================================================
-- AJUSTE EN EL PANEL (no es SQL, pero hace falta):
--   Authentication → Providers → Email
--     · "Enable Email provider" activado.
--     · "Confirm email": si lo dejas ACTIVADO, al registrarte recibirás un
--       correo y no podrás entrar hasta confirmarlo. Si lo DESACTIVAS, la
--       cuenta funciona al instante (más cómodo para uso personal).
-- =====================================================================
