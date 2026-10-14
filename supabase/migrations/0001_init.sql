-- Cita Clara: esquema inicial para Supabase (PostgreSQL)
-- Se puede ejecutar más de una vez sin romper nada.

create extension if not exists btree_gist;

-- ---------------------------------------------------------------
-- Tipos
-- ---------------------------------------------------------------
do $$ begin
  create type public.professional_kind as enum ('medico', 'dentista', 'psicologo');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.verification_status as enum ('pending', 'verified', 'rejected');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.appointment_status as enum ('pending', 'confirmed', 'cancelled', 'completed');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.user_role as enum ('patient', 'professional');
exception when duplicate_object then null; end $$;

-- ---------------------------------------------------------------
-- Perfiles de usuario (uno por cuenta de auth.users)
-- ---------------------------------------------------------------
create table if not exists public.profiles (
  id          uuid primary key references auth.users (id) on delete cascade,
  role        public.user_role not null default 'patient',
  full_name   text,
  phone       text,
  created_at  timestamptz not null default now()
);

-- Crea el perfil automáticamente cuando alguien se registra.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, role, full_name)
  values (
    new.id,
    case when new.raw_user_meta_data ->> 'role' = 'professional'
         then 'professional'::public.user_role
         else 'patient'::public.user_role end,
    new.raw_user_meta_data ->> 'full_name'
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------------------------------------------------------------
-- Especialidades (catálogo)
-- ---------------------------------------------------------------
create table if not exists public.specialties (
  id    serial primary key,
  kind  public.professional_kind not null,
  name  text not null,
  unique (kind, name)
);

-- ---------------------------------------------------------------
-- Profesionales (médicos, dentistas, psicólogos)
-- ---------------------------------------------------------------
create table if not exists public.professionals (
  id                  uuid primary key default gen_random_uuid(),
  user_id             uuid not null unique references auth.users (id) on delete cascade,
  kind                public.professional_kind not null,
  full_name           text not null,
  license_number      text not null,            -- cédula profesional
  about               text,
  consultation_price  numeric(10, 2) check (consultation_price >= 0),
  status              public.verification_status not null default 'pending',
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);
create index if not exists professionals_kind_idx on public.professionals (kind);
create index if not exists professionals_status_idx on public.professionals (status);

-- Un médico puede tener varias especialidades.
create table if not exists public.professional_specialties (
  professional_id  uuid not null references public.professionals (id) on delete cascade,
  specialty_id     int  not null references public.specialties (id) on delete restrict,
  primary key (professional_id, specialty_id)
);

-- ---------------------------------------------------------------
-- Consultorios y horarios
-- ---------------------------------------------------------------
create table if not exists public.offices (
  id                   uuid primary key default gen_random_uuid(),
  professional_id      uuid not null references public.professionals (id) on delete cascade,
  name                 text not null,
  address              text not null,
  city                 text not null,
  state                text not null default 'Morelos',
  postal_code          text,
  latitude             double precision,
  longitude            double precision,
  appointment_minutes  int not null default 30 check (appointment_minutes between 10 and 240),
  created_at           timestamptz not null default now()
);
create index if not exists offices_professional_idx on public.offices (professional_id);
create index if not exists offices_city_idx on public.offices (city);

-- Horario semanal: weekday 0 = domingo ... 6 = sábado. Varios bloques por día.
create table if not exists public.office_schedules (
  id          uuid primary key default gen_random_uuid(),
  office_id   uuid not null references public.offices (id) on delete cascade,
  weekday     smallint not null check (weekday between 0 and 6),
  start_time  time not null,
  end_time    time not null,
  check (end_time > start_time)
);
create index if not exists office_schedules_office_idx on public.office_schedules (office_id);

-- ---------------------------------------------------------------
-- Citas
-- ---------------------------------------------------------------
create table if not exists public.appointments (
  id               uuid primary key default gen_random_uuid(),
  professional_id  uuid not null references public.professionals (id) on delete cascade,
  office_id        uuid not null references public.offices (id) on delete cascade,
  patient_id       uuid not null references auth.users (id) on delete cascade,
  starts_at        timestamptz not null,
  ends_at          timestamptz not null,
  status           public.appointment_status not null default 'pending',
  notes            text,
  created_at       timestamptz not null default now(),
  check (ends_at > starts_at),
  -- Un profesional no puede tener dos citas activas que se traslapen.
  constraint appointments_no_overlap exclude using gist (
    professional_id with =,
    tstzrange(starts_at, ends_at) with &&
  ) where (status <> 'cancelled')
);
create index if not exists appointments_patient_idx on public.appointments (patient_id, starts_at);
create index if not exists appointments_professional_idx on public.appointments (professional_id, starts_at);

-- ---------------------------------------------------------------
-- Triggers de apoyo
-- ---------------------------------------------------------------
create or replace function public.touch_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists professionals_touch on public.professionals;
create trigger professionals_touch
  before update on public.professionals
  for each row execute function public.touch_updated_at();

-- Un profesional no puede verificarse a sí mismo ni cambiar su tipo.
-- (Desde el panel SQL o con la llave de servicio sí se puede.)
create or replace function public.protect_professional_fields()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if auth.uid() is not null then
    if new.status is distinct from old.status then
      raise exception 'Solo el equipo de la plataforma puede cambiar la verificación.';
    end if;
    if new.kind is distinct from old.kind then
      raise exception 'El tipo de profesional no se puede cambiar.';
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists professionals_protect on public.professionals;
create trigger professionals_protect
  before update on public.professionals
  for each row execute function public.protect_professional_fields();

-- Una cita no puede cambiar de paciente, profesional ni consultorio.
create or replace function public.protect_appointment_fields()
returns trigger
language plpgsql
as $$
begin
  if new.patient_id is distinct from old.patient_id
     or new.professional_id is distinct from old.professional_id
     or new.office_id is distinct from old.office_id
     or new.starts_at is distinct from old.starts_at
     or new.ends_at is distinct from old.ends_at then
    raise exception 'Para cambiar la fecha, cancela la cita y agenda otra.';
  end if;
  return new;
end;
$$;

drop trigger if exists appointments_protect on public.appointments;
create trigger appointments_protect
  before update on public.appointments
  for each row execute function public.protect_appointment_fields();

-- ---------------------------------------------------------------
-- Horarios ocupados: cualquiera puede ver CUÁNDO está ocupado un
-- consultorio, sin ver quién tiene la cita.
-- ---------------------------------------------------------------
create or replace function public.get_taken_slots(p_office_id uuid, p_from timestamptz, p_to timestamptz)
returns table (starts_at timestamptz, ends_at timestamptz)
language sql
stable
security definer
set search_path = ''
as $$
  select a.starts_at, a.ends_at
  from public.appointments a
  join public.professionals p on p.id = a.professional_id
  where a.office_id = p_office_id
    and p.status = 'verified'
    and a.status <> 'cancelled'
    and a.starts_at < p_to
    and a.ends_at > p_from;
$$;

revoke all on function public.get_taken_slots(uuid, timestamptz, timestamptz) from public;
grant execute on function public.get_taken_slots(uuid, timestamptz, timestamptz) to anon, authenticated;

-- ---------------------------------------------------------------
-- Seguridad por filas (RLS)
-- ---------------------------------------------------------------
alter table public.profiles                 enable row level security;
alter table public.specialties              enable row level security;
alter table public.professionals            enable row level security;
alter table public.professional_specialties enable row level security;
alter table public.offices                  enable row level security;
alter table public.office_schedules         enable row level security;
alter table public.appointments             enable row level security;

-- Perfiles: cada persona ve y edita solo el suyo.
drop policy if exists "profiles: ver el propio" on public.profiles;
create policy "profiles: ver el propio" on public.profiles
  for select to authenticated using (id = (select auth.uid()));

drop policy if exists "profiles: editar el propio" on public.profiles;
create policy "profiles: editar el propio" on public.profiles
  for update to authenticated
  using (id = (select auth.uid()))
  with check (id = (select auth.uid()));

-- Especialidades: lectura pública.
drop policy if exists "specialties: lectura pública" on public.specialties;
create policy "specialties: lectura pública" on public.specialties
  for select to anon, authenticated using (true);

-- Profesionales: el público ve solo los verificados; cada quien ve y edita el suyo.
drop policy if exists "professionals: ver verificados" on public.professionals;
create policy "professionals: ver verificados" on public.professionals
  for select to anon, authenticated using (status = 'verified');

drop policy if exists "professionals: ver el propio" on public.professionals;
create policy "professionals: ver el propio" on public.professionals
  for select to authenticated using (user_id = (select auth.uid()));

drop policy if exists "professionals: crear el propio" on public.professionals;
create policy "professionals: crear el propio" on public.professionals
  for insert to authenticated
  with check (user_id = (select auth.uid()) and status = 'pending');

drop policy if exists "professionals: editar el propio" on public.professionals;
create policy "professionals: editar el propio" on public.professionals
  for update to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

-- Especialidades del profesional.
drop policy if exists "prof_specialties: ver" on public.professional_specialties;
create policy "prof_specialties: ver" on public.professional_specialties
  for select to anon, authenticated using (
    exists (select 1 from public.professionals p
            where p.id = professional_id
              and (p.status = 'verified' or p.user_id = (select auth.uid())))
  );

drop policy if exists "prof_specialties: administrar las propias" on public.professional_specialties;
create policy "prof_specialties: administrar las propias" on public.professional_specialties
  for all to authenticated
  using (exists (select 1 from public.professionals p
                 where p.id = professional_id and p.user_id = (select auth.uid())))
  with check (exists (select 1 from public.professionals p
                      where p.id = professional_id and p.user_id = (select auth.uid())));

-- Consultorios.
drop policy if exists "offices: ver" on public.offices;
create policy "offices: ver" on public.offices
  for select to anon, authenticated using (
    exists (select 1 from public.professionals p
            where p.id = professional_id
              and (p.status = 'verified' or p.user_id = (select auth.uid())))
  );

drop policy if exists "offices: administrar los propios" on public.offices;
create policy "offices: administrar los propios" on public.offices
  for all to authenticated
  using (exists (select 1 from public.professionals p
                 where p.id = professional_id and p.user_id = (select auth.uid())))
  with check (exists (select 1 from public.professionals p
                      where p.id = professional_id and p.user_id = (select auth.uid())));

-- Horarios.
drop policy if exists "schedules: ver" on public.office_schedules;
create policy "schedules: ver" on public.office_schedules
  for select to anon, authenticated using (
    exists (select 1 from public.offices o
            join public.professionals p on p.id = o.professional_id
            where o.id = office_id
              and (p.status = 'verified' or p.user_id = (select auth.uid())))
  );

drop policy if exists "schedules: administrar los propios" on public.office_schedules;
create policy "schedules: administrar los propios" on public.office_schedules
  for all to authenticated
  using (exists (select 1 from public.offices o
                 join public.professionals p on p.id = o.professional_id
                 where o.id = office_id and p.user_id = (select auth.uid())))
  with check (exists (select 1 from public.offices o
                      join public.professionals p on p.id = o.professional_id
                      where o.id = office_id and p.user_id = (select auth.uid())));

-- Citas: el paciente ve las suyas; el profesional ve las de su agenda.
drop policy if exists "appointments: ver las propias" on public.appointments;
create policy "appointments: ver las propias" on public.appointments
  for select to authenticated using (
    patient_id = (select auth.uid())
    or exists (select 1 from public.professionals p
               where p.id = professional_id and p.user_id = (select auth.uid()))
  );

drop policy if exists "appointments: agendar" on public.appointments;
create policy "appointments: agendar" on public.appointments
  for insert to authenticated
  with check (
    patient_id = (select auth.uid())
    and status = 'pending'
    and exists (select 1 from public.offices o
                join public.professionals p on p.id = o.professional_id
                where o.id = office_id
                  and p.id = professional_id
                  and p.status = 'verified')
  );

drop policy if exists "appointments: actualizar las propias" on public.appointments;
create policy "appointments: actualizar las propias" on public.appointments
  for update to authenticated
  using (
    patient_id = (select auth.uid())
    or exists (select 1 from public.professionals p
               where p.id = professional_id and p.user_id = (select auth.uid()))
  )
  with check (
    -- El paciente solo puede cancelar; el profesional puede confirmar, cancelar o completar.
    (patient_id = (select auth.uid()) and status = 'cancelled')
    or exists (select 1 from public.professionals p
               where p.id = professional_id and p.user_id = (select auth.uid()))
  );

-- ---------------------------------------------------------------
-- Especialidades iniciales
-- ---------------------------------------------------------------
insert into public.specialties (kind, name) values
  ('medico', 'Medicina general'),
  ('medico', 'Medicina familiar'),
  ('medico', 'Medicina interna'),
  ('medico', 'Pediatría'),
  ('medico', 'Ginecología y obstetricia'),
  ('medico', 'Cardiología'),
  ('medico', 'Dermatología'),
  ('medico', 'Traumatología y ortopedia'),
  ('medico', 'Neurología'),
  ('medico', 'Oftalmología'),
  ('medico', 'Otorrinolaringología'),
  ('medico', 'Gastroenterología'),
  ('medico', 'Endocrinología'),
  ('medico', 'Urología'),
  ('medico', 'Psiquiatría'),
  ('medico', 'Neumología'),
  ('medico', 'Reumatología'),
  ('medico', 'Oncología'),
  ('medico', 'Nutriología'),
  ('medico', 'Medicina del deporte'),
  ('dentista', 'Odontología general'),
  ('dentista', 'Ortodoncia'),
  ('dentista', 'Endodoncia'),
  ('dentista', 'Odontopediatría'),
  ('dentista', 'Periodoncia'),
  ('dentista', 'Cirugía maxilofacial'),
  ('dentista', 'Prostodoncia'),
  ('dentista', 'Implantología'),
  ('psicologo', 'Psicología clínica'),
  ('psicologo', 'Terapia de pareja'),
  ('psicologo', 'Psicología infantil'),
  ('psicologo', 'Terapia cognitivo-conductual'),
  ('psicologo', 'Psicología del adolescente'),
  ('psicologo', 'Neuropsicología'),
  ('psicologo', 'Terapia familiar')
on conflict (kind, name) do nothing;
