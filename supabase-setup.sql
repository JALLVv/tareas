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
-- Puntos descontados por tareas no completadas en su día (penalizaciones).
alter table public.profiles add column if not exists penalties int default 0;

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
-- Si fue una tarea aleatoria del generador (para el desglose "aleatorias vs
-- normales" que ve un amigo en tu perfil).
alter table public.completions add column if not exists random bool default false;

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
  status       text default 'invited',  -- invited (sin responder) | pending | done
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

-- 4b) SINCRONIZACIÓN AUTOMÁTICA DE TAREAS COMPARTIDAS (en la nube) -------
-- Estos triggers (SECURITY DEFINER: corren con permisos elevados, saltan RLS)
-- mantienen al día el perfil del OTRO implicado SIN que su app tenga que
-- abrirse. Así, cuando uno completa o borra una compartida, el calendario,
-- los puntos y la racha del otro se actualizan solos y todos lo ven al instante.

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

-- Recalcula puntos y racha de un usuario desde sus completadas (idempotente).
create or replace function public.recompute_profile(p_uid uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare s record;
begin
  select * into s from public.calc_streak(p_uid);
  update public.profiles p set
    points         = greatest(0, coalesce((select sum(points) from public.completions where user_id = p_uid), 0) - coalesce(p.penalties, 0)),
    streak_current = coalesce(s.cur, 0),
    streak_best    = coalesce(s.best, 0),
    updated_at     = now()
    where p.id = p_uid;
end;
$$;

-- (i) Al BORRAR una compartida: quita la completada del otro y recalcula.
create or replace function public.cleanup_shared_completions()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare u uuid;
begin
  foreach u in array array[old.owner_id, old.partner_id]
  loop
    if u is null or u = auth.uid() then continue; end if;  -- al que borra no se le toca
    -- Dos bloques SEPARADOS (no uno solo): en PL/pgSQL, un bloque "begin/exception"
    -- es un savepoint implícito — si recompute_profile fallara DENTRO del mismo
    -- bloque que el delete, el delete ya hecho se revertiría también, en silencio.
    begin
      delete from public.completions
        where user_id = u and (id = 'sh_' || old.id or shared_id = old.id);
    exception when others then null;  -- nunca bloquear el borrado
    end;
    begin
      perform public.recompute_profile(u);
    exception when others then null;
    end;
  end loop;
  -- Borra los avisos (completó / comentó) que apuntaban a esta tarea, para que no
  -- sigan apareciendo en el menú de notificaciones de nadie tras eliminarla.
  begin
    delete from public.notifications where ref_key = old.id;
  exception when others then null;
  end;
  return old;
end;
$$;

drop trigger if exists trg_cleanup_shared on public.shared_tasks;
create trigger trg_cleanup_shared
  after delete on public.shared_tasks
  for each row execute function public.cleanup_shared_completions();

-- (ii) Al COMPLETAR una compartida (status pasa a 'done'): da al OTRO implicado
-- su registro de completada (foto, puntos, calendario) y recalcula su perfil.
create or replace function public.propagate_shared_completion()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  u uuid;
  cname text;
begin
  if new.status = 'done' and (old.status is distinct from 'done') then
    select name into cname from public.profiles where id = new.completed_by;
    foreach u in array array[new.owner_id, new.partner_id]
    loop
      if u is null or u = new.completed_by then continue; end if;  -- el que completó ya tiene la suya
      -- Dos bloques SEPARADOS: si recompute_profile fallara dentro del MISMO
      -- bloque que el insert, el insert ya hecho se revertiría también (savepoint
      -- implícito de begin/exception), y la tarea nunca aparecería del otro lado
      -- aunque el insert en sí hubiera funcionado bien.
      begin
        insert into public.completions(id, user_id, date, title, category, points, time, photo_url, partner_id, partner_name, shared_id)
        values('sh_' || new.id, u, new.done_date, new.title, new.category, new.points, new.done_time, new.photo_url,
               new.completed_by, cname, new.id)
        on conflict (id) do update set
          date=excluded.date, title=excluded.title, category=excluded.category, points=excluded.points,
          time=excluded.time, photo_url=excluded.photo_url, partner_id=excluded.partner_id,
          partner_name=excluded.partner_name, shared_id=excluded.shared_id;
        -- (la notificación "completó una tarea" la crea trg_notify_friends al
        --  insertarse la completada del que la hizo; aquí no, para no duplicar.)
      exception when others then null;  -- nunca bloquear la compleción
      end;
      begin
        perform public.recompute_profile(u);
      exception when others then null;
      end;
    end loop;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_propagate_shared on public.shared_tasks;
create trigger trg_propagate_shared
  after update on public.shared_tasks
  for each row execute function public.propagate_shared_completion();

-- RECUPERACIÓN (una vez, segura de repetir): antes de separar los bloques de
-- arriba, un fallo silencioso en el recálculo del perfil podía deshacer el
-- registro que le tocaba ver al otro implicado de una compartida ya
-- completada. Esto revisa TODAS las compartidas ya marcadas 'done' y crea el
-- registro que le falte a quien no lo tenga (no toca nada si ya existe).
do $$
declare r record; u uuid; cname text;
begin
  for r in select * from public.shared_tasks where status = 'done' loop
    foreach u in array array[r.owner_id, r.partner_id]
    loop
      if u is null or u = r.completed_by then continue; end if;
      if not exists (select 1 from public.completions where id = 'sh_' || r.id) then
        select name into cname from public.profiles where id = r.completed_by;
        begin
          insert into public.completions(id, user_id, date, title, category, points, time, photo_url, partner_id, partner_name, shared_id)
          values('sh_' || r.id, u, r.done_date, r.title, r.category, r.points, r.done_time, r.photo_url, r.completed_by, cname, r.id);
          perform public.recompute_profile(u);
        exception when others then null;
        end;
      end if;
    end loop;
  end loop;
end $$;

-- (iii) Al COMPLETAR CUALQUIER tarea (compartida o no): avisa a TODOS tus
-- amigos. Se dispara al insertarse tu completada; ignora las recibidas (sh_).
create or replace function public.notify_friends_on_completion()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare f uuid; cname text;
begin
  if new.id like 'sh\_%' escape '\' then return new; end if; -- completada recibida (no la hiciste tú)
  select name into cname from public.profiles where id = new.user_id;
  for f in
    select case when requester = new.user_id then addressee else requester end
    from public.friendships
    where status = 'accepted' and (requester = new.user_id or addressee = new.user_id)
  loop
    begin
      if not exists (
        select 1 from public.notifications
        where recipient_id = f and actor_id = new.user_id and type = 'shared_done'
          and task_title = new.title and created_at > now() - interval '6 hours'
      ) then
        insert into public.notifications(recipient_id, actor_id, actor_name, type, task_title, photo_url, ref_key, task_time, task_category, task_points)
        values(f, new.user_id, cname, 'shared_done', new.title, new.photo_url, coalesce(new.shared_id, new.id), new.time, new.category, new.points);
      end if;
    exception when others then null;
    end;
  end loop;
  return new;
end;
$$;

drop trigger if exists trg_notify_friends on public.completions;
create trigger trg_notify_friends
  after insert on public.completions
  for each row execute function public.notify_friends_on_completion();

-- (iv) Al BORRAR una completada: elimina los avisos (completó / comentó) que
-- apuntaban a ella, para que las tareas eliminadas dejen de verse en el menú de
-- notificaciones. La clave del aviso es shared_id (si compartida) o el id.
create or replace function public.cleanup_completion_notifications()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  begin
    delete from public.notifications where ref_key = coalesce(old.shared_id, old.id);
  exception when others then null;
  end;
  return old;
end;
$$;

drop trigger if exists trg_cleanup_completion_notifs on public.completions;
create trigger trg_cleanup_completion_notifs
  after delete on public.completions
  for each row execute function public.cleanup_completion_notifications();

-- 4c) COMENTARIOS en tareas completadas --------------------------------
-- Se identifican por la "clave" de la completada: shared_id si es compartida,
-- o el id de la completada si no. Así el mismo comentario se ve desde cualquier
-- vista (tu perfil, el calendario del amigo, etc.).
create table if not exists public.comments (
  id             uuid default gen_random_uuid() primary key,
  completion_key text not null,
  author_id      uuid,
  author_name    text,
  text           text,
  created_at     timestamptz default now()
);
alter table public.comments enable row level security;
drop policy if exists "comments_read"   on public.comments;
drop policy if exists "comments_insert" on public.comments;
drop policy if exists "comments_delete" on public.comments;
create policy "comments_read"   on public.comments for select to authenticated using (true);
create policy "comments_insert" on public.comments for insert to authenticated with check (auth.uid() = author_id);
create policy "comments_delete" on public.comments for delete to authenticated using (auth.uid() = author_id);

-- Al COMENTAR: avisa al dueño (o dueños, si es compartida) de la tarea.
create or replace function public.notify_comment()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare o uuid; ttl text; ph text; cname text; ctime text; ccat text; cpts int;
begin
  select name into cname from public.profiles where id = new.author_id;
  select title, photo_url, time, category, points into ttl, ph, ctime, ccat, cpts from public.completions
    where id = new.completion_key or shared_id = new.completion_key limit 1;
  for o in
    select distinct user_id from public.completions
    where id = new.completion_key or shared_id = new.completion_key
  loop
    if o is null or o = new.author_id then continue; end if;
    begin
      insert into public.notifications(recipient_id, actor_id, actor_name, type, task_title, photo_url, ref_key, task_time, task_category, task_points, comment_id)
      values(o, new.author_id, cname, 'comment', coalesce(ttl,''), ph, new.completion_key, ctime, ccat, cpts, new.id);
    exception when others then null;
    end;
  end loop;
  return new;
end;
$$;

drop trigger if exists trg_notify_comment on public.comments;
create trigger trg_notify_comment
  after insert on public.comments
  for each row execute function public.notify_comment();

-- Al BORRAR un comentario: borra el aviso que generó (solo ese, no los de otros
-- comentarios en la misma tarea).
create or replace function public.cleanup_comment_notification()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  begin
    delete from public.notifications where comment_id = old.id;
  exception when others then null;
  end;
  return old;
end;
$$;

drop trigger if exists trg_cleanup_comment_notif on public.comments;
create trigger trg_cleanup_comment_notif
  after delete on public.comments
  for each row execute function public.cleanup_comment_notification();

-- 5) NOTIFICACIONES ---------------------------------------------------
create table if not exists public.notifications (
  id          uuid default gen_random_uuid() primary key,
  recipient_id uuid, actor_id uuid, actor_name text,
  type        text,                      -- 'shared_invite' | 'shared_done' | 'friend_request' | 'comment' | 'weekly_summary'
  task_title  text, photo_url text,
  created_at  timestamptz default now(), read boolean default false
);
-- clave de la completada relacionada (para abrir sus comentarios desde el aviso)
alter table public.notifications add column if not exists ref_key text;
-- detalle de la tarea (hora · categoría · puntos), para que abrir la tarea desde
-- el aviso se vea igual que abrirla en el calendario aunque el destinatario no
-- tenga esa completada en su propio historial (p.ej. un amigo completó SU tarea,
-- no compartida contigo).
alter table public.notifications add column if not exists task_time     text;
alter table public.notifications add column if not exists task_category text;
alter table public.notifications add column if not exists task_points   int;
-- comentario concreto que originó el aviso (para borrarlo si se borra el comentario)
alter table public.notifications add column if not exists comment_id uuid;
alter table public.notifications enable row level security;
drop policy if exists "notif_read"   on public.notifications;
drop policy if exists "notif_insert" on public.notifications;
drop policy if exists "notif_update" on public.notifications;
drop policy if exists "notif_delete" on public.notifications;
create policy "notif_read"   on public.notifications for select to authenticated using (auth.uid() = recipient_id);
create policy "notif_insert" on public.notifications for insert to authenticated with check (auth.uid() = actor_id);   -- el actor crea la del destinatario
create policy "notif_update" on public.notifications for update to authenticated using (auth.uid() = recipient_id);   -- marcar como leída
create policy "notif_delete" on public.notifications for delete to authenticated using (auth.uid() = recipient_id);

-- 5b) AMISTADES (solicitudes + amigos aceptados) ----------------------
-- Una fila por relación. status 'pending' = solicitud enviada; 'accepted' = amigos.
-- Borrar la fila = rechazar la solicitud o eliminar al amigo (afecta a ambos).
create table if not exists public.friendships (
  requester  uuid not null,
  addressee  uuid not null,
  status     text default 'pending',   -- 'pending' | 'accepted'
  created_at timestamptz default now(),
  primary key (requester, addressee)
);
alter table public.friendships enable row level security;
drop policy if exists "fr_read"   on public.friendships;
drop policy if exists "fr_insert" on public.friendships;
drop policy if exists "fr_update" on public.friendships;
drop policy if exists "fr_delete" on public.friendships;
-- Los dos implicados pueden ver la relación.
create policy "fr_read"   on public.friendships for select to authenticated using (auth.uid() = requester or auth.uid() = addressee);
-- Solo tú envías solicitudes (como requester).
create policy "fr_insert" on public.friendships for insert to authenticated with check (auth.uid() = requester);
-- Solo el destinatario puede aceptar (cambiar a 'accepted').
create policy "fr_update" on public.friendships for update to authenticated using (auth.uid() = addressee);
-- Cualquiera de los dos puede borrar (rechazar o eliminar amigo) → desaparece para ambos.
create policy "fr_delete" on public.friendships for delete to authenticated using (auth.uid() = requester or auth.uid() = addressee);

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

-- 7) PUSH FIABLE: se envía desde el SERVIDOR, no desde el que actúa --------
-- Antes, cada acción (comentar, invitar a una tarea, completar, etc.) mandaba
-- el push desde el propio dispositivo del que actuó, justo después de crear
-- el aviso. Si cerrabas la app (o se cortaba la conexión) en ese instante, el
-- push se perdía aunque el aviso in-app sí quedara guardado (así pasó con un
-- comentario). Ahora un trigger en la tabla notifications manda el push en
-- cuanto se inserta CUALQUIER aviso, sin depender de que el dispositivo que
-- actuó siga conectado ni de que su app llegue a ejecutar ese paso.
create extension if not exists pg_net;

create or replace function public.send_push_for_notification()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare body text;
begin
  body := case new.type
    when 'friend_request' then coalesce(new.actor_name,'Alguien') || ' te ha enviado una solicitud de amistad'
    when 'shared_invite'   then coalesce(new.actor_name,'Alguien') || ' quiere agregarte a una tarea'
    when 'comment'         then coalesce(new.actor_name,'Alguien') || ' te comentó'
    when 'shared_done'     then coalesce(new.actor_name,'Un amigo') || ' completó una tarea'
    when 'weekly_summary'  then 'Ya está disponible tu resumen de la semana'
    else coalesce(new.actor_name,'Alguien') || ' te envió una notificación'
  end;
  begin
    perform net.http_post(
      url     := 'https://muvqfjyzneszkptsjxgi.supabase.co/functions/v1/send-push',
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'Authorization', 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im11dnFmanl6bmVzemtwdHNqeGdpIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODI3MDI0NjIsImV4cCI6MjA5ODI3ODQ2Mn0.Ud4QhDc2EsTKPQoHtEaubH3jMTppI4CKDZKZqGf2Uao'
      ),
      -- El "tag" es DETERMINISTA (tipo + referencia + actor): el envío de respaldo
      -- que hace la app del que actuó usa el MISMO tag, así que si el aviso llega
      -- por los dos caminos, el sistema los funde en UNA sola notificación.
      body    := jsonb_build_object('recipientId', new.recipient_id, 'title', 'Tareas', 'body', body, 'photo', new.photo_url,
                                    'tag', new.type || '-' || coalesce(new.ref_key, new.actor_id::text, new.id::text))
    );
  exception when others then null; -- nunca bloquear la inserción del aviso
  end;
  return new;
end;
$$;

drop trigger if exists trg_send_push_notification on public.notifications;
create trigger trg_send_push_notification
  after insert on public.notifications
  for each row execute function public.send_push_for_notification();

-- =====================================================================
-- 8) ÚLTIMO PASO (en el panel, no en SQL):
--    Authentication → Sign In / Providers → activa "Anonymous sign-ins".
--    Sin esto, la app no podrá iniciar sesión anónima y la nube no funcionará.
-- =====================================================================
