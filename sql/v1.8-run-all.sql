
-- CWA Ride Scheduler - v1.8-run-all.sql  (RESET + RECREATE)
-- This version *drops and recreates* all CWA-specific objects in the public schema.
-- Use in dev/preview to guarantee a clean v1.8 schema even if v1.7 remnants exist.
-- Target: Supabase Postgres 15
-- ---------------------------------------------------------------------

begin;

-- ==============================
-- 0) EXTENSIONS
-- ==============================
create extension if not exists "uuid-ossp";
create extension if not exists "pgcrypto";
create extension if not exists "btree_gist";

-- ==============================
-- 1) RESET (DEV-ONLY): drop dependent views/functions first, then tables
-- ==============================
-- Views
drop view if exists public.v_roster_ready_passengers cascade;
drop view if exists public.v_roster_ready_pilots cascade;
drop view if exists public.v_ride_detail cascade;
drop view if exists public.v_people_lookup cascade;

-- Functions (helpers/RPCs/triggers)
drop function if exists public.unlink_emergency_contact(uuid, uuid) cascade;
drop function if exists public.link_emergency_contact(uuid, uuid) cascade;
drop function if exists public.unassign_person(uuid, uuid, text) cascade;
drop function if exists public.assign_person(uuid, uuid, text) cascade;
drop function if exists public.save_ride(uuid, timestamptz, integer, text, text) cascade;
drop function if exists public.trg_validate_emergency_contact() cascade;
drop function if exists public.trg_operating_hours_biu() cascade;
drop function if exists public.trg_check_operating_hours() cascade;
drop function if exists public.trg_check_overlaps() cascade;
drop function if exists public.trg_check_role_counts() cascade;
drop function if exists public.trg_compute_ride_bounds() cascade;
drop function if exists public.trg_touch_updated_at() cascade;
drop function if exists public.mask_phone(text, boolean) cascade;
drop function if exists public.mask_email(text, boolean) cascade;
drop function if exists public.is_within_operating_hours(timestamptz, integer) cascade;
drop function if exists public.get_operating_hours() cascade;
drop function if exists public.require_admin_scheduler() cascade;
drop function if exists public.is_admin_or_scheduler() cascade;
drop function if exists public.current_uid() cascade;
drop function if exists public.ok(jsonb) cascade;
drop function if exists public.err(text, text) cascade;

-- Tables (order matters due to FKs)
drop table if exists public.ride_emergency_contacts cascade;
drop table if exists public.ride_assignments cascade;
drop table if exists public.rides cascade;
drop table if exists public.person_unavailability cascade;
drop table if exists public.person_certs cascade;
drop table if exists public.person_roles cascade;
drop table if exists public.people cascade;
drop table if exists public.role_cert_requirements cascade;
drop table if exists public.cert_types cascade;
drop table if exists public.person_roles_catalog cascade;
drop table if exists public.ride_statuses cascade;
drop table if exists public.person_statuses cascade;
drop table if exists public.app_user_roles cascade;
drop table if exists public.app_roles cascade;
drop table if exists public.app_settings cascade;

-- ==============================
-- 2) SECURITY HELPERS
-- ==============================
set role postgres;

drop function if exists public.err(text, text) cascade;
create or replace function public.err(code text, message text)
returns jsonb language sql stable as
$$ select jsonb_build_object('ok', false, 'error', jsonb_build_object('code', code, 'message', message)) $$;

drop function if exists public.ok(jsonb) cascade;
create or replace function public.ok(payload jsonb)
returns jsonb language sql stable as
$$ select jsonb_build_object('ok', true, 'data', coalesce(payload, '{}'::jsonb)) $$;

drop function if exists public.current_uid() cascade;
create or replace function public.current_uid()
returns uuid language sql stable as
$$ select auth.uid()::uuid $$;

create table if not exists public.app_roles (
  key text primary key,
  label text not null unique
);

insert into public.app_roles(key, label) values
  ('admin','Administrator'),
  ('scheduler','Scheduler'),
  ('viewer','Viewer')
on conflict (key) do nothing;

create table if not exists public.app_user_roles (
  user_id uuid not null,
  role_key text not null references public.app_roles(key),
  primary key (user_id, role_key)
);

drop function if exists public.is_admin_or_scheduler() cascade;
create or replace function public.is_admin_or_scheduler()
returns boolean language sql stable as
$$
  select exists (
    select 1
    from public.app_user_roles aur
    where aur.user_id = auth.uid()::uuid
      and aur.role_key in ('admin','scheduler')
  );
$$;

drop function if exists public.require_admin_scheduler() cascade;
create or replace function public.require_admin_scheduler()
returns void language plpgsql stable as
$$
begin
  if not public.is_admin_or_scheduler() then
    raise exception 'FORBIDDEN: admin/scheduler required';
  end if;
end;
$$;

-- ==============================
-- 3) CATALOGS
-- ==============================
create table if not exists public.person_statuses (
  key text primary key,
  label text not null unique
);

insert into public.person_statuses(key, label) values
  ('active','Active'),
  ('inactive','Inactive'),
  ('not_interested','Not Interested'),
  ('deceased','Deceased')
on conflict (key) do nothing;

create table if not exists public.ride_statuses (
  key text primary key,
  label text not null unique
);

insert into public.ride_statuses(key, label) values
  ('tentative','Tentative'),
  ('scheduled','Scheduled'),
  ('completed','Completed'),
  ('cancelled','Cancelled')
on conflict (key) do nothing;

create table if not exists public.person_roles_catalog (
  key text primary key,
  label text not null unique
);

insert into public.person_roles_catalog(key, label) values
  ('pilot','Pilot'),
  ('passenger','Passenger'),
  ('emergency_contact','Emergency Contact')
on conflict (key) do nothing;

create table if not exists public.cert_types (
  key text primary key,
  label text not null unique,
  description text
);

insert into public.cert_types(key, label, description) values
  ('TRISHAW-BASICS','Trishaw Basics','Basic training for pilots and safety'),
  ('FIRST-AID','First Aid','Basic first aid training')
on conflict (key) do nothing;

create table if not exists public.role_cert_requirements (
  role_key text not null references public.person_roles_catalog(key),
  cert_key text not null references public.cert_types(key),
  requirement text not null check (requirement in ('required','recommended')),
  primary key (role_key, cert_key)
);

insert into public.role_cert_requirements(role_key, cert_key, requirement) values
  ('pilot','TRISHAW-BASICS','required')
on conflict (role_key, cert_key) do nothing;

-- ==============================
-- 4) CORE ENTITIES
-- ==============================
create table if not exists public.people (
  id uuid primary key default gen_random_uuid(),
  first_name text not null,
  last_name  text not null,
  email text,
  phone text,
  status_key text not null references public.person_statuses(key) default 'active',
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid
);

create index if not exists idx_people_name on public.people (last_name, first_name);
create index if not exists idx_people_status on public.people (status_key);

create table if not exists public.person_roles (
  person_id uuid not null references public.people(id) on delete cascade,
  role_key text not null references public.person_roles_catalog(key),
  primary key (person_id, role_key)
);

create table if not exists public.person_certs (
  person_id uuid not null references public.people(id) on delete cascade,
  cert_key text not null references public.cert_types(key),
  issued_on date,
  expires_on date,
  notes text,
  primary key (person_id, cert_key)
);

create table if not exists public.person_unavailability (
  id uuid primary key default gen_random_uuid(),
  person_id uuid not null references public.people(id) on delete cascade,
  starts_at timestamptz not null,
  ends_at   timestamptz not null,
  reason text,
  check (ends_at > starts_at)
);
create index if not exists idx_unavail_person_time on public.person_unavailability using gist (person_id, tstzrange(starts_at, ends_at, '[)'));

create table if not exists public.app_settings (
  key text primary key,
  value jsonb not null
);

insert into public.app_settings(key, value) values
  ('operating_hours', jsonb_build_object('tz','America/Los_Angeles','start','07:00','end','20:00'))
on conflict (key) do nothing;

drop function if exists public.get_operating_hours() cascade;
create or replace function public.get_operating_hours()
returns jsonb language sql stable as
$$
  select coalesce((select value from public.app_settings where key='operating_hours'),
                  jsonb_build_object('tz','America/Los_Angeles','start','07:00','end','20:00'));
$$;

drop function if exists public.is_within_operating_hours(timestamptz, integer) cascade;
create or replace function public.is_within_operating_hours(p_start timestamptz, p_duration_minutes integer)
returns boolean language plpgsql stable as
$$
declare
  cfg jsonb;
  tz text;
  start_local time;
  end_local time;
  s_local time;
  e_local time;
  e_ts timestamptz;
begin
  cfg := public.get_operating_hours();
  tz := (cfg->>'tz');
  start_local := (cfg->>'start')::time;
  end_local   := (cfg->>'end')::time;

  e_ts := p_start + make_interval(mins => p_duration_minutes);
  s_local := (p_start at time zone tz)::time;
  e_local := (e_ts    at time zone tz)::time;

  return (s_local >= start_local) and (e_local <= end_local);
end;
$$;

create table if not exists public.rides (
  id uuid primary key default gen_random_uuid(),
  date_time timestamptz not null,
  duration_minutes integer not null check (duration_minutes between 30 and 240),
  status_key text not null references public.ride_statuses(key) default 'tentative',
  cancellation_reason text,
  start_at timestamptz,
  end_at   timestamptz,
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  check (status_key <> 'cancelled' or cancellation_reason is not null)
);


-- Compute start_at/end_at before write (avoid generated-column immutability limits)
drop function if exists public.trg_compute_ride_bounds() cascade;
create or replace function public.trg_compute_ride_bounds()
returns trigger language plpgsql as
$$
begin
  new.start_at := new.date_time;
  new.end_at := new.date_time + (new.duration_minutes * interval '1 minute');
  return new;
end;
$$;

drop trigger if exists trg_rides_compute_bounds on public.rides;
create trigger trg_rides_compute_bounds
before insert or update on public.rides
for each row execute function public.trg_compute_ride_bounds();
create index if not exists idx_rides_time on public.rides using gist (tstzrange(start_at, end_at, '[)'));
create index if not exists idx_rides_status on public.rides (status_key);

create table if not exists public.ride_assignments (
  ride_id uuid not null references public.rides(id) on delete cascade,
  person_id uuid not null references public.people(id) on delete cascade,
  role_key text not null references public.person_roles_catalog(key),
  primary key (ride_id, person_id, role_key)
);

create index if not exists idx_ra_person_role on public.ride_assignments (person_id, role_key);
create index if not exists idx_ra_ride on public.ride_assignments (ride_id);

-- ==============================
-- 5) BUSINESS-RULE TRIGGERS
-- ==============================
drop function if exists public.trg_check_role_counts() cascade;
create or replace function public.trg_check_role_counts()
returns trigger language plpgsql as
$$
declare
  pilots int;
  passengers int;
begin
  select count(*) into pilots
  from public.ride_assignments
  where ride_id = coalesce(new.ride_id, old.ride_id) and role_key = 'pilot';

  if pilots <> 1 then
    raise exception 'Each ride must have exactly 1 pilot (current=%).', pilots;
  end if;

  select count(*) into passengers
  from public.ride_assignments
  where ride_id = coalesce(new.ride_id, old.ride_id) and role_key = 'passenger';

  if passengers > 2 then
    raise exception 'Each ride can have at most 2 passengers (current=%).', passengers;
  end if;

  return null;
end;
$$;

drop trigger if exists trg_role_counts_aiud on public.ride_assignments;
create constraint trigger trg_role_counts_aiud
after insert or update or delete on public.ride_assignments
deferrable initially deferred
for each row execute function public.trg_check_role_counts();

drop function if exists public.trg_check_overlaps() cascade;
create or replace function public.trg_check_overlaps()
returns trigger language plpgsql as
$$
declare
  rid uuid := coalesce(new.ride_id, old.ride_id);
  pid uuid := coalesce(new.person_id, old.person_id);
  overlap_exists boolean;
begin
  perform 1 from public.rides r where r.id = rid;
  if not found then
    return null;
  end if;

  select exists (
    select 1
    from public.ride_assignments ra
    join public.rides r on r.id = ra.ride_id
    where ra.person_id = pid
      and (ra.ride_id <> rid or TG_OP='UPDATE')
      and tstzrange(r.start_at, r.end_at, '[)') && (
            select tstzrange(r2.start_at, r2.end_at, '[)') from public.rides r2 where r2.id = rid
          )
  ) into overlap_exists;

  if overlap_exists then
    raise exception 'Person % is already assigned to an overlapping ride.', pid;
  end if;

  return null;
end;
$$;

drop trigger if exists trg_overlap_aiud on public.ride_assignments;
create constraint trigger trg_overlap_aiud
after insert or update on public.ride_assignments
deferrable initially deferred
for each row execute function public.trg_check_overlaps();

drop function if exists public.trg_check_operating_hours() cascade;
create or replace function public.trg_check_operating_hours()
returns trigger language plpgsql as
$$
begin
  if not public.is_within_operating_hours(new.date_time, new.duration_minutes) then
    raise exception 'Ride is outside operating hours.';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_operating_hours_biu on public.rides;
create trigger trg_operating_hours_biu
before insert or update on public.rides
for each row execute function public.trg_check_operating_hours();

create table if not exists public.ride_emergency_contacts (
  ride_id uuid not null references public.rides(id) on delete cascade,
  contact_person_id uuid not null references public.people(id) on delete cascade,
  primary key (ride_id, contact_person_id)
);

drop function if exists public.trg_validate_emergency_contact() cascade;
create or replace function public.trg_validate_emergency_contact()
returns trigger language plpgsql as
$$
declare
  s_key text;
  has_role boolean;
  has_unavail boolean;
begin
  select exists(
    select 1 from public.person_roles pr
    where pr.person_id = new.contact_person_id and pr.role_key = 'emergency_contact'
  ) into has_role;
  if not has_role then
    raise exception 'Emergency contact must have the emergency_contact role.';
  end if;

  select status_key into s_key from public.people where id = new.contact_person_id;
  if s_key <> 'active' then
    raise exception 'Emergency contact must be active (current status=%).', s_key;
  end if;

  select exists(
    select 1
    from public.person_unavailability u
    join public.rides r on r.id = new.ride_id
    where u.person_id = new.contact_person_id
      and tstzrange(u.starts_at, u.ends_at, '[)') && tstzrange(r.start_at, r.end_at, '[)')
  ) into has_unavail;
  if has_unavail then
    raise exception 'Emergency contact is unavailable during the ride window.';
  end if;

  return new;
end;
$$;

drop trigger if exists trg_validate_emc_biu on public.ride_emergency_contacts;
create trigger trg_validate_emc_biu
before insert or update on public.ride_emergency_contacts
for each row execute function public.trg_validate_emergency_contact();

-- ==============================
-- 6) RPCs
-- ==============================
drop function if exists public.save_ride(uuid, timestamptz, integer, text, text) cascade;
create or replace function public.save_ride(
  p_id uuid,
  p_date_time timestamptz,
  p_duration_minutes integer,
  p_status_key text,
  p_cancellation_reason text
) returns jsonb language plpgsql security definer as
$$
declare
  v_id uuid;
begin
  perform public.require_admin_scheduler();

  if p_status_key = 'cancelled' and p_cancellation_reason is null then
    return public.err('ERR_CANCEL_REASON','Cancellation requires a reason');
  end if;

  if p_id is null then
    insert into public.rides(date_time, duration_minutes, status_key, cancellation_reason)
    values (p_date_time, p_duration_minutes, coalesce(p_status_key,'tentative'), p_cancellation_reason)
    returning id into v_id;
  else
    update public.rides
      set date_time=p_date_time,
          duration_minutes=p_duration_minutes,
          status_key=coalesce(p_status_key, status_key),
          cancellation_reason = case when coalesce(p_status_key, status_key)='cancelled' then p_cancellation_reason else null end,
          updated_at=now(), updated_by=auth.uid()::uuid
    where id = p_id
    returning id into v_id;
  end if;

  return public.ok(jsonb_build_object('ride_id', v_id));
end;
$$;

grant execute on function public.save_ride(uuid, timestamptz, integer, text, text) to authenticated;

drop function if exists public.assign_person(uuid, uuid, text) cascade;
create or replace function public.assign_person(
  p_ride_id uuid,
  p_person_id uuid,
  p_role_key text
) returns jsonb language plpgsql security definer as
$$
declare
  s_key text;
  has_role boolean;
  has_unavail boolean;
  cert_warnings jsonb := '[]'::jsonb;
  ride_window tstzrange;
begin
  perform public.require_admin_scheduler();

  select exists(
    select 1 from public.person_roles pr
    where pr.person_id = p_person_id and pr.role_key = p_role_key
  ) into has_role;
  if not has_role then
    return public.err('ERR_ROLE_MISSING','Person lacks required role for assignment');
  end if;

  select status_key into s_key from public.people where id = p_person_id;

  if p_role_key = 'pilot' then
    if s_key <> 'active' then
      return public.err('ERR_STATUS','Pilot must be active');
    end if;
  elsif p_role_key = 'passenger' then
    if s_key in ('deceased','not_interested') then
      return public.err('ERR_STATUS','Passenger status blocks assignment');
    end if;
  else
    return public.err('ERR_ROLE','Unsupported role for assignment');
  end if;

  select tstzrange(r.start_at, r.end_at, '[)') into ride_window from public.rides r where r.id = p_ride_id;

  select exists(
    select 1 from public.person_unavailability u
    where u.person_id = p_person_id
      and tstzrange(u.starts_at, u.ends_at, '[)') && ride_window
  ) into has_unavail;

  if has_unavail then
    return public.err('ERR_UNAVAILABLE','Person is unavailable for the ride window');
  end if;

  select coalesce(jsonb_agg(jsonb_build_object('cert', req.cert_key, 'issue', 'missing_or_expired')), '[]'::jsonb)
  into cert_warnings
  from public.role_cert_requirements req
  left join public.person_certs pc
    on pc.person_id = p_person_id and pc.cert_key = req.cert_key
    and (pc.expires_on is null or pc.expires_on >= (lower(ride_window))::date)
  where req.role_key = p_role_key
    and (pc.person_id is null);

  insert into public.ride_assignments(ride_id, person_id, role_key)
  values (p_ride_id, p_person_id, p_role_key)
  on conflict (ride_id, person_id, role_key) do nothing;

  return public.ok(jsonb_build_object('warnings', cert_warnings));
end;
$$;

grant execute on function public.assign_person(uuid, uuid, text) to authenticated;

drop function if exists public.unassign_person(uuid, uuid, text) cascade;
create or replace function public.unassign_person(
  p_ride_id uuid,
  p_person_id uuid,
  p_role_key text
) returns jsonb language plpgsql security definer as
$$
begin
  perform public.require_admin_scheduler();
  delete from public.ride_assignments
  where ride_id = p_ride_id and person_id = p_person_id and role_key = p_role_key;
  return public.ok('{}'::jsonb);
end;
$$;

grant execute on function public.unassign_person(uuid, uuid, text) to authenticated;

drop function if exists public.link_emergency_contact(uuid, uuid) cascade;
create or replace function public.link_emergency_contact(
  p_ride_id uuid, p_contact_person_id uuid
) returns jsonb language plpgsql security definer as
$$
begin
  perform public.require_admin_scheduler();
  insert into public.ride_emergency_contacts(ride_id, contact_person_id)
  values (p_ride_id, p_contact_person_id)
  on conflict do nothing;
  return public.ok('{}'::jsonb);
end;
$$;

grant execute on function public.link_emergency_contact(uuid, uuid) to authenticated;

drop function if exists public.unlink_emergency_contact(uuid, uuid) cascade;
create or replace function public.unlink_emergency_contact(
  p_ride_id uuid, p_contact_person_id uuid
) returns jsonb language plpgsql security definer as
$$
begin
  perform public.require_admin_scheduler();
  delete from public.ride_emergency_contacts where ride_id=p_ride_id and contact_person_id=p_contact_person_id;
  return public.ok('{}'::jsonb);
end;
$$;

grant execute on function public.unlink_emergency_contact(uuid, uuid) to authenticated;

-- ==============================
-- 7) VIEWS & MASKING
-- ==============================
drop function if exists public.mask_email(text, boolean) cascade;
create or replace function public.mask_email(email text, allow boolean)
returns text language sql immutable as
$$
  select case when allow or email is null then email
              else regexp_replace(email, '(^.).*(@.*$)', '\1***\2') end
$$;

drop function if exists public.mask_phone(text, boolean) cascade;
create or replace function public.mask_phone(phone text, allow boolean)
returns text language sql immutable as
$$
  select case when allow or phone is null then phone
              else case
                     when length(regexp_replace(phone,'\D','','g')) >= 4
                       then '***-***-'|| right(regexp_replace(phone,'\D','','g'),4)
                     else '***'
                   end
         end
$$;

drop view if exists public.v_people_lookup cascade;
create or replace view public.v_people_lookup as
select
  p.id,
  p.first_name,
  p.last_name,
  case when public.is_admin_or_scheduler() then p.email else public.mask_email(p.email,false) end as email,
  case when public.is_admin_or_scheduler() then p.phone else public.mask_phone(p.phone,false) end as phone,
  p.status_key
from public.people p;

drop view if exists public.v_ride_detail cascade;
create or replace view public.v_ride_detail as
select
  r.id as ride_id,
  r.date_time,
  r.duration_minutes,
  r.status_key,
  r.cancellation_reason,
  jsonb_agg(distinct jsonb_build_object(
    'person_id', a.person_id,
    'role', a.role_key
  )) filter (where a.person_id is not null) as assignments,
  jsonb_agg(distinct jsonb_build_object(
    'person_id', ec.contact_person_id
  )) filter (where ec.contact_person_id is not null) as emergency_contacts
from public.rides r
left join public.ride_assignments a on a.ride_id = r.id
left join public.ride_emergency_contacts ec on ec.ride_id = r.id
group by r.id, r.date_time, r.duration_minutes, r.status_key, r.cancellation_reason;

drop view if exists public.v_roster_ready_pilots cascade;
create or replace view public.v_roster_ready_pilots as
select
  p.id,
  p.first_name, p.last_name,
  case when public.is_admin_or_scheduler() then p.email else public.mask_email(p.email,false) end as email,
  case when public.is_admin_or_scheduler() then p.phone else public.mask_phone(p.phone,false) end as phone,
  p.status_key,
  (p.email is not null or p.phone is not null) as has_contact,
  coalesce(
    (
      select jsonb_agg(jsonb_build_object('cert', req.cert_key, 'issue', 'missing_or_expired'))
      from public.role_cert_requirements req
      left join public.person_certs pc
        on pc.person_id = p.id and pc.cert_key = req.cert_key
        and (pc.expires_on is null or pc.expires_on >= now()::date)
      where req.role_key='pilot' and (pc.person_id is null)
    ), '[]'::jsonb
  ) as cert_warnings
from public.people p
join public.person_roles pr on pr.person_id = p.id and pr.role_key='pilot'
where p.status_key='active';

drop view if exists public.v_roster_ready_passengers cascade;
create or replace view public.v_roster_ready_passengers as
select
  p.id,
  p.first_name, p.last_name,
  case when public.is_admin_or_scheduler() then p.email else public.mask_email(p.email,false) end as email,
  case when public.is_admin_or_scheduler() then p.phone else public.mask_phone(p.phone,false) end as phone,
  p.status_key,
  (p.email is not null or p.phone is not null) as has_contact
from public.people p
join public.person_roles pr on pr.person_id = p.id and pr.role_key='passenger'
where p.status_key not in ('deceased','not_interested');

-- ==============================
-- 8) BASIC GRANTS (dev)
grant usage on schema public to authenticated;
grant select on public.v_people_lookup, public.v_ride_detail, public.v_roster_ready_pilots, public.v_roster_ready_passengers to authenticated;
grant select on public.people, public.rides, public.ride_assignments, public.ride_emergency_contacts to authenticated;

-- ==============================
-- 9) SEEDS
-- ==============================
insert into public.people(id, first_name, last_name, email, phone, status_key)
values
  ('00000000-0000-0000-0000-000000000001','Pat','Pilot','pat.pilot@example.org','+1 (206) 555-0101','active'),
  ('00000000-0000-0000-0000-000000000002','Casey','Contact','casey.contact@example.org','+1 (206) 555-0102','active'),
  ('00000000-0000-0000-0000-000000000003','Sam','Student','sam.student@example.org',null,'active'),
  ('00000000-0000-0000-0000-000000000004','Nia','NotInterested',null,null,'not_interested')
on conflict (id) do nothing;

insert into public.person_roles(person_id, role_key) values
  ('00000000-0000-0000-0000-000000000001','pilot'),
  ('00000000-0000-0000-0000-000000000002','emergency_contact'),
  ('00000000-0000-0000-0000-000000000003','passenger'),
  ('00000000-0000-0000-0000-000000000004','passenger')
on conflict do nothing;

insert into public.person_certs(person_id, cert_key, issued_on, expires_on, notes) values
  ('00000000-0000-0000-0000-000000000001','TRISHAW-BASICS', current_date - interval '30 days', current_date + interval '365 days','Seed valid')
on conflict do nothing;

insert into public.rides(id, date_time, duration_minutes, status_key) values
  ('10000000-0000-0000-0000-000000000001', date_trunc('day', now()) + interval '17 hours', 90, 'scheduled')
on conflict (id) do nothing;

insert into public.ride_assignments(ride_id, person_id, role_key) values
  ('10000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000001','pilot'),
  ('10000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000003','passenger')
on conflict do nothing;

insert into public.ride_emergency_contacts(ride_id, contact_person_id) values
  ('10000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000002')
on conflict do nothing;

-- ==============================
-- 10) HOUSEKEEPING (audit touch)
drop function if exists public.trg_compute_ride_bounds() cascade;
drop function if exists public.trg_touch_updated_at() cascade;
create or replace function public.trg_touch_updated_at()
returns trigger language plpgsql as
$$
begin
  new.updated_at := now();
  new.updated_by := auth.uid()::uuid;
  return new;
end;
$$;

drop trigger if exists trg_people_touch on public.people;
create trigger trg_people_touch before update on public.people
for each row execute function public.trg_touch_updated_at();

drop trigger if exists trg_rides_touch on public.rides;
create trigger trg_rides_touch before update on public.rides
for each row execute function public.trg_touch_updated_at();

commit;

-- End of v1.8-run-all.sql (RESET)
