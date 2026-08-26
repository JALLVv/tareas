-- =====================================================================
-- RESPUESTAS A COMENTARIOS
-- Ejecuta este archivo entero en el SQL Editor de Supabase.
-- Es idempotente: puedes volver a ejecutarlo sin romper nada.
--
-- Qué añade:
--   · Un comentario puede responder a otro (columna parent_id).
--   · Al responder, el autor del comentario respondido recibe un aviso
--     "[Nombre] respondió tu comentario" — y su push.
--   · Borrar un comentario se lleva sus respuestas (y los avisos de todas).
-- =====================================================================

-- 1) La columna. Un comentario sin parent_id es de primer nivel; con él, es
--    una respuesta a ese comentario.
alter table public.comments add column if not exists parent_id uuid;
create index if not exists comments_parent_idx on public.comments(parent_id);

-- Borrar un comentario se lleva sus respuestas: una respuesta huérfana no
-- significa nada, y dejarla colgando enseñaría media conversación. El borrado
-- en cascada dispara a su vez trg_cleanup_comment_notif en cada respuesta, así
-- que sus avisos también desaparecen.
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'comments_parent_fk') then
    alter table public.comments
      add constraint comments_parent_fk foreign key (parent_id)
      references public.comments(id) on delete cascade;
  end if;
end $$;

-- 2) Al comentar: a quién se avisa.
--    · Si es una RESPUESTA, avisa al autor del comentario respondido
--      ('comment_reply' → "respondió tu comentario").
--    · Y en los dos casos avisa a los dueños de la completada ('comment'),
--      saltándose a quien ya recibió el aviso de respuesta: dos avisos por el
--      mismo comentario serían el mismo hecho contado dos veces.
create or replace function public.notify_comment()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare o uuid; ttl text; ph text; cname text; ctime text; ccat text; cpts int; pauthor uuid;
begin
  select name into cname from public.profiles where id = new.author_id;
  select title, photo_url, time, category, points into ttl, ph, ctime, ccat, cpts from public.completions
    where id = new.completion_key or shared_id = new.completion_key limit 1;

  if new.parent_id is not null then
    -- El padre tiene que ser un comentario de ESTA MISMA completada. Sin esa
    -- condición, un parent_id apuntando a otra tarea avisaría al autor de un
    -- comentario que el que responde ni siquiera puede ver: el aviso se inserta
    -- desde una función security definer, que no pasa por las políticas de RLS.
    select author_id into pauthor from public.comments
      where id = new.parent_id and completion_key = new.completion_key;
    if pauthor is not null and pauthor <> new.author_id then
      begin
        insert into public.notifications(recipient_id, actor_id, actor_name, type, task_title, photo_url, ref_key, task_time, task_category, task_points, comment_id)
        values(pauthor, new.author_id, cname, 'comment_reply', coalesce(ttl,''), ph, new.completion_key, ctime, ccat, cpts, new.id);
      exception when others then null;
      end;
    end if;
  end if;

  for o in
    select distinct user_id from public.completions
    where id = new.completion_key or shared_id = new.completion_key
  loop
    if o is null or o = new.author_id or o is not distinct from pauthor then continue; end if;
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

-- 3) El texto del push del tipo nuevo.
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
    when 'comment_reply'   then coalesce(new.actor_name,'Alguien') || ' respondió tu comentario'
    when 'shared_done'     then coalesce(new.actor_name,'Un amigo') || ' completó una tarea'
    when 'weekly_summary'  then 'Ya está disponible tu resumen de la semana'
    else coalesce(new.actor_name,'Alguien') || ' te envió una notificación'
  end;
  begin
    perform net.http_post(
      url     := 'https://muvqfjyzneszkptsjxgi.supabase.co/functions/v1/send-push',
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'Authorization', 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im11dnFmanl6bmVzemtwdHNqeGdpIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODI3MDI0NjIsImV4cCI6MjA5ODI3ODQ2Mn0.Ud4QhDc2EsTKPQoHtEaubH3jMTppI4CKDZKZqGf2Uao',
        'x-push-secret', private.push_secret()
      ),
      body    := jsonb_build_object('recipientId', new.recipient_id, 'title', 'Tareas', 'body', body, 'photo', new.photo_url,
                                    'tag', new.type || '-' || coalesce(new.ref_key, new.actor_id::text, new.id::text))
    );
  exception when others then null;
  end;
  return new;
end;
$$;

drop trigger if exists trg_send_push_notification on public.notifications;
create trigger trg_send_push_notification
  after insert on public.notifications
  for each row execute function public.send_push_for_notification();

-- 4) Antiduplicados: la ventana corta de los comentarios vale igual para las
--    respuestas. Con la de 3 minutos, dos respuestas seguidas del mismo autor
--    en la misma tarea se habrían tragado la segunda.
create or replace function public.dedupe_notification()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if exists (
    select 1 from public.notifications
    where recipient_id = new.recipient_id
      and actor_id is not distinct from new.actor_id
      and type = new.type
      and ref_key is not distinct from new.ref_key
      and created_at > now() - (case when new.type in ('comment','comment_reply')
                                     then interval '60 seconds'
                                     else interval '3 minutes' end)
  ) then
    return null;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_dedupe_notification on public.notifications;
create trigger trg_dedupe_notification
  before insert on public.notifications
  for each row execute function public.dedupe_notification();
