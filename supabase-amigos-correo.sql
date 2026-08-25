-- =====================================================================
-- AÑADIR AMIGOS POR CORREO
-- Ejecuta TODO este archivo una vez en: Supabase → SQL Editor.
-- (Requiere haber ejecutado antes supabase-cuentas.sql, que es donde se
--  crean las cuentas con correo.)
--
-- Sustituye al sistema de "Mi ID": ahora se busca a la gente por el correo
-- con el que se registró, no por un UUID que había que copiar y pegar.
--
-- SEGURIDAD
--   · La tabla de perfiles sigue SIN ser legible en abierto: nadie puede
--     listar ni "pescar" los usuarios que existen.
--   · Esta función devuelve SOLO id, nombre y avatar, y únicamente si le
--     das el correo COMPLETO y EXACTO. No hay búsqueda parcial ni por
--     aproximación, así que no sirve para ir descubriendo cuentas.
--   · Solo la pueden ejecutar usuarios con sesión iniciada.
--   · Los correos NUNCA se devuelven: solo se usan para comparar.
-- =====================================================================

create or replace function public.lookup_profile_email(target_email text)
returns table (id uuid, name text, avatar_url text)
language sql
stable
security definer
set search_path = public
as $$
  select p.id, p.name, p.avatar_url
  from auth.users u
  join public.profiles p on p.id = u.id
  where lower(u.email) = lower(btrim(target_email))
  limit 1;
$$;

-- Por defecto Postgres deja EXECUTE a PUBLIC: hay que quitarlo a mano, o
-- cualquiera sin sesión podría llamarla.
revoke all on function public.lookup_profile_email(text) from public, anon;
grant execute on function public.lookup_profile_email(text) to authenticated;
