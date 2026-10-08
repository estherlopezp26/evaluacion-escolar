-- AulaEval V3. Ejecutar SOLO después de V2 y de hacer un respaldo.
-- El script es transaccional. Revisa los datos antes de confirmar la migración.
begin;
create extension if not exists pgcrypto;
create table public.workspaces (
 id uuid primary key default gen_random_uuid(),
 name text not null check(length(trim(name)) between 1 and 120),
 kind text not null check(kind in ('personal','school')),
 created_by uuid not null references auth.users(id),
 created_at timestamptz not null default now()
);
create table public.workspace_members (
 workspace_id uuid not null references public.workspaces(id) on delete cascade,
 user_id uuid not null references auth.users(id) on delete cascade,
 role text not null check(role in ('admin','teacher')),
 joined_at timestamptz not null default now(),
 primary key(workspace_id,user_id)
);
create table public.workspace_invites (
 id uuid primary key default gen_random_uuid(),
 workspace_id uuid not null references public.workspaces(id) on delete cascade,
 token_hash text not null unique,
 created_by uuid not null references auth.users(id),
 expires_at timestamptz not null default (now()+interval '7 days'),
 used_by uuid references auth.users(id),
 used_at timestamptz,
 created_at timestamptz not null default now()
);
create unique index workspace_one_personal on public.workspaces(created_by) where kind='personal';
-- Funciones de autorización que evitan recursión de políticas RLS.
create function public.is_workspace_member(w uuid) returns boolean language sql stable security definer set search_path=public as $$
 select exists(select 1 from workspace_members where workspace_id=w and user_id=(select auth.uid()))
$$;
create function public.is_workspace_admin(w uuid) returns boolean language sql stable security definer set search_path=public as $$
 select exists(select 1 from workspace_members where workspace_id=w and user_id=(select auth.uid()) and role='admin')
$$;
revoke all on function public.is_workspace_member(uuid),public.is_workspace_admin(uuid) from public;
grant execute on function public.is_workspace_member(uuid),public.is_workspace_admin(uuid) to authenticated;
-- Crear un espacio personal por cada dueño existente (sin borrar datos).
insert into public.workspaces(name,kind,created_by)
select 'Mi espacio personal','personal',u.id from (
 select owner_id as id from public.students union select owner_id from public.evaluations
 union select owner_id from public.subjects union select owner_id from public.periods
) u;
insert into public.workspace_members(workspace_id,user_id,role)
select id,created_by,'admin' from public.workspaces;
-- Retirar los triggers V2 ANTES del backfill: el SQL Editor no tiene auth.uid() de un docente.
drop trigger if exists enrollment_guard on public.enrollments;
drop trigger if exists evaluation_guard on public.evaluations;
-- Los registros antiguos permanecen en el espacio personal de su propietario.
alter table public.students add column workspace_id uuid references public.workspaces(id);
alter table public.subjects add column workspace_id uuid references public.workspaces(id);
alter table public.periods add column workspace_id uuid references public.workspaces(id);
alter table public.enrollments add column workspace_id uuid references public.workspaces(id);
alter table public.evaluations add column workspace_id uuid references public.workspaces(id);
update public.students t set workspace_id=w.id from public.workspaces w where w.kind='personal' and w.created_by=t.owner_id;
update public.subjects t set workspace_id=w.id from public.workspaces w where w.kind='personal' and w.created_by=t.owner_id;
update public.periods t set workspace_id=w.id from public.workspaces w where w.kind='personal' and w.created_by=t.owner_id;
update public.enrollments t set workspace_id=w.id from public.workspaces w where w.kind='personal' and w.created_by=t.owner_id;
update public.evaluations t set workspace_id=w.id from public.workspaces w where w.kind='personal' and w.created_by=t.owner_id;
alter table public.students alter column workspace_id set not null;
alter table public.subjects alter column workspace_id set not null;
alter table public.periods alter column workspace_id set not null;
alter table public.enrollments alter column workspace_id set not null;
alter table public.evaluations alter column workspace_id set not null;
-- En V2 las restricciones de nombres únicos eran por dueño: ahora por espacio.
alter table public.subjects drop constraint if exists subjects_owner_id_name_key;
alter table public.periods drop constraint if exists periods_owner_id_name_key;
create unique index subjects_workspace_name_unique on public.subjects(workspace_id,lower(name));
create unique index periods_workspace_name_unique on public.periods(workspace_id,lower(name));
create index students_workspace_idx on public.students(workspace_id);
create index evaluations_workspace_idx on public.evaluations(workspace_id);
create index enrollments_workspace_idx on public.enrollments(workspace_id);
-- Validación relacional y protección contra cambios de espacio/propietario.
create function public.workspace_record_guard() returns trigger language plpgsql security definer set search_path=public as $$
declare w uuid;
begin
 if tg_op='UPDATE' and (new.workspace_id<>old.workspace_id or new.owner_id<>old.owner_id) then
  raise exception 'No se puede cambiar espacio o propietario de un registro';
 end if;
 if not public.is_workspace_member(new.workspace_id) then raise exception 'Sin acceso al espacio'; end if;
 if tg_op='INSERT' and new.owner_id<>auth.uid() then raise exception 'Propietario incorrecto'; end if;
 w:=new.workspace_id;
 if tg_table_name='enrollments' then
  if not exists(select 1 from students where id=new.student_id and workspace_id=w)
   or not exists(select 1 from subjects where id=new.subject_id and workspace_id=w) then
    raise exception 'La asignación pertenece a otro espacio'; end if;
 end if;
 if tg_table_name='evaluations' then
  if new.subject_id is null or new.period_id is null then raise exception 'Asignatura y período obligatorios'; end if;
  if not exists(select 1 from students where id=new.student_id and workspace_id=w)
   or not exists(select 1 from subjects where id=new.subject_id and workspace_id=w)
   or not exists(select 1 from periods where id=new.period_id and workspace_id=w)
   or not exists(select 1 from enrollments where student_id=new.student_id and subject_id=new.subject_id and workspace_id=w) then
   raise exception 'Referencias de evaluación de otro espacio'; end if;
  if jsonb_typeof(new.scores)<>'object' or exists(
   select 1 from jsonb_each(new.scores) x where x.value<>'null'::jsonb and
    (jsonb_typeof(x.value)<>'number' or (x.value::text)::numeric<0 or (x.value::text)::numeric>20
    or (x.value::text)::numeric*4<>trunc((x.value::text)::numeric*4))
  ) then raise exception 'Puntuaciones inválidas'; end if;
 end if;
 return new;
end $$;
drop trigger if exists evaluation_guard on public.evaluations;
drop trigger if exists enrollment_guard on public.enrollments;
-- Triggers por tabla.
create trigger students_workspace_guard before insert or update on public.students for each row execute function public.workspace_record_guard();
create trigger subjects_workspace_guard before insert or update on public.subjects for each row execute function public.workspace_record_guard();
create trigger periods_workspace_guard before insert or update on public.periods for each row execute function public.workspace_record_guard();
create trigger enrollments_workspace_guard before insert or update on public.enrollments for each row execute function public.workspace_record_guard();
create trigger evaluations_workspace_guard before insert or update on public.evaluations for each row execute function public.workspace_record_guard();
-- Eliminar las políticas anteriores: owner_id ya no limita la colaboración.
drop policy if exists students_own on public.students;
drop policy if exists evaluations_own on public.evaluations;
drop policy if exists subjects_own on public.subjects;
drop policy if exists periods_own on public.periods;
drop policy if exists enrollments_own on public.enrollments;
alter table public.workspaces enable row level security;
alter table public.workspace_members enable row level security;
alter table public.workspace_invites enable row level security;
create policy workspaces_read on public.workspaces for select to authenticated using(public.is_workspace_member(id));
create policy members_read on public.workspace_members for select to authenticated using(public.is_workspace_member(workspace_id));
-- No escritura directa en tablas de gestión de espacios, solo RPC controladas.
revoke all on public.workspaces,public.workspace_members,public.workspace_invites from anon,authenticated;
grant select on public.workspaces,public.workspace_members to authenticated;
-- RLS de datos: lectura y escritura solo de miembros del espacio.
create policy students_ws on public.students for all to authenticated using(public.is_workspace_member(workspace_id)) with check(public.is_workspace_member(workspace_id));
create policy subjects_ws on public.subjects for all to authenticated using(public.is_workspace_member(workspace_id)) with check(public.is_workspace_member(workspace_id));
create policy periods_ws on public.periods for all to authenticated using(public.is_workspace_member(workspace_id)) with check(public.is_workspace_member(workspace_id));
create policy enrollments_ws on public.enrollments for all to authenticated using(public.is_workspace_member(workspace_id)) with check(public.is_workspace_member(workspace_id));
create policy evaluations_ws on public.evaluations for all to authenticated using(public.is_workspace_member(workspace_id)) with check(public.is_workspace_member(workspace_id));
-- RPC: crea espacio personal si no existe; evita que se creen dos.
create function public.ensure_personal_workspace() returns uuid language plpgsql security definer set search_path=public as $$
declare w uuid;
begin
 if auth.uid() is null then raise exception 'No autenticado'; end if;
 select id into w from workspaces where kind='personal' and created_by=auth.uid();
 if w is null then
  insert into workspaces(name,kind,created_by) values('Mi espacio personal','personal',auth.uid()) returning id into w;
  insert into workspace_members(workspace_id,user_id,role) values(w,auth.uid(),'admin');
 end if;
 return w;
end $$;
create function public.create_school_workspace(p_name text) returns uuid language plpgsql security definer set search_path=public as $$
declare w uuid;
begin
 if auth.uid() is null then raise exception 'No autenticado'; end if;
 if length(trim(p_name)) not between 2 and 120 then raise exception 'Nombre inválido'; end if;
 insert into workspaces(name,kind,created_by) values(trim(p_name),'school',auth.uid()) returning id into w;
 insert into workspace_members(workspace_id,user_id,role) values(w,auth.uid(),'admin');
 return w;
end $$;
-- Invitación de un solo uso, expira a los 7 días. Código aleatorio de 256 bits.
create function public.create_workspace_invite(p_workspace uuid) returns text language plpgsql security definer set search_path=public as $$
declare token text;
begin
 if not public.is_workspace_admin(p_workspace) or not exists(select 1 from workspaces where id=p_workspace and kind='school') then
  raise exception 'Solo administradores de colegios pueden invitar'; end if;
 token:=encode(gen_random_bytes(32),'hex');
 insert into workspace_invites(workspace_id,token_hash,created_by) values(p_workspace,encode(digest(token,'sha256'),'hex'),auth.uid());
 return token;
end $$;
create function public.redeem_workspace_invite(p_token text) returns uuid language plpgsql security definer set search_path=public as $$
declare invite workspace_invites%rowtype;
begin
 if auth.uid() is null then raise exception 'No autenticado'; end if;
 select * into invite from workspace_invites where token_hash=encode(digest(trim(p_token),'sha256'),'hex') and used_at is null and expires_at>now() for update;
 if not found then raise exception 'Invitación inválida, utilizada o vencida'; end if;
 insert into workspace_members(workspace_id,user_id,role) values(invite.workspace_id,auth.uid(),'teacher') on conflict do nothing;
 update workspace_invites set used_by=auth.uid(),used_at=now() where id=invite.id;
 return invite.workspace_id;
end $$;
-- Administrador puede quitar docentes; nadie puede eliminar al último administrador.
create function public.remove_workspace_member(p_workspace uuid,p_user uuid) returns void language plpgsql security definer set search_path=public as $$
begin
 if not public.is_workspace_admin(p_workspace) then raise exception 'Solo administradores'; end if;
 if exists(select 1 from workspace_members where workspace_id=p_workspace and user_id=p_user and role='admin') then
  raise exception 'No se puede retirar a un administrador desde esta función'; end if;
 delete from workspace_members where workspace_id=p_workspace and user_id=p_user;
end $$;
revoke all on function public.ensure_personal_workspace(),public.create_school_workspace(text),public.create_workspace_invite(uuid),public.redeem_workspace_invite(text),public.remove_workspace_member(uuid,uuid) from public;
grant execute on function public.ensure_personal_workspace(),public.create_school_workspace(text),public.create_workspace_invite(uuid),public.redeem_workspace_invite(text),public.remove_workspace_member(uuid,uuid) to authenticated;
commit;
