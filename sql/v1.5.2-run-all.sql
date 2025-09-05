-- v1.4-run-all-fixed.sql
-- Purpose: Rebuild schema, install views/RLS, seed (incl. overlap ride), and RPCs in one pass.
-- WARNING: This DROPS and RECREATES the 'public' schema. Use only on disposable/dev DBs.

-- =====================================
-- STEP 1: Base schema
-- =====================================
-- CWA Ride Scheduler — Base Schema (v1.4, step 1)
-- Purpose: recreate the entire schema from scratch.
-- This script DROPS and RECREATES the public schema — nothing survives.
-- Run only if you are OK with losing everything in `public`.


-- Reset schema
drop schema if exists public cascade;
create schema public;
set search_path = public;

-- Extensions
create extension if not exists pgcrypto;   -- for gen_random_uuid()
create extension if not exists pg_trgm;    -- trigram search (people name)
create extension if not exists btree_gist; -- exclusion constraints

-- Enum(s)
create type ride_status as enum ('tentative','scheduled','completed','cancelled');

-- Utility: updated_at trigger
create or replace function set_updated_at() returns trigger
language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end$$;

-- App user role mapping
create table app_user_roles (
  user_id   uuid        not null,
  role_key  text        not null check (role_key in ('admin','scheduler')),
  created_at timestamptz not null default now(),
  primary key (user_id, role_key)
);

-- App settings (singleton row: id=1)
create table app_settings (
  id          int not null primary key default 1 check (id = 1),
  start_hour  int not null check (start_hour between 0 and 23),
  end_hour    int not null check (end_hour between 1 and 24),
  timezone    text not null,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create trigger trg_app_settings_updated_at
before update on app_settings
for each row execute function set_updated_at();



-- People
create table people (
  id            uuid        primary key default gen_random_uuid(),
  first_name    text        not null check (btrim(first_name) <> '' and char_length(first_name) <= 100),
  last_name     text        not null check (btrim(last_name) <> '' and char_length(last_name) <= 100),
  email         text        null check (
                    email is null or
                    email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'
                  ),
  phone         text        null,
  role_affinity text        null check (role_affinity in ('pilot','passenger','emergency_contact')),
  notes         text        null,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  created_by    uuid        null,
  updated_by    uuid        null,
  constraint people_contact_chk check (email is not null or phone is not null)
);


-- Normalize helpers for people
create or replace function normalize_email(p text) returns text
language sql immutable as $$
  select case when p is null then null else lower(btrim(p)) end;
$$;

create or replace function normalize_phone_e164(p text) returns text
language plpgsql immutable as $$
declare
  d text;
begin
  if p is null then
    return null;
  end if;
  if p ~ '^\+[1-9][0-9]{1,14}$' then
    return p;
  end if;
  d := regexp_replace(p, '[^0-9]', '', 'g');
  if length(d) = 11 and left(d,1) = '1' then
    return '+'||d;
  elsif length(d) = 10 then
    return '+1'||d;
  else
    return p;
  end if;
end;
$$;

create or replace function people_biu_normalize()
returns trigger language plpgsql as $$
begin
  new.first_name := btrim(new.first_name);
  new.last_name  := btrim(new.last_name);
  if new.email is not null then
    new.email := normalize_email(new.email);
  end if;
  if new.phone is not null then
    new.phone := normalize_phone_e164(new.phone);
  end if;
  new.updated_by := auth.uid();
  if tg_op = 'INSERT' then
    new.created_by := auth.uid();
  end if;
  return new;
end;
$$;

drop trigger if exists trg_people_biu_normalize on people;
create trigger trg_people_biu_normalize
before insert or update on people
for each row execute function people_biu_normalize();

drop index if exists ux_people_email;
create unique index ux_people_email on people ((lower(email))) where email is not null;

drop index if exists ux_people_phone;
create unique index ux_people_phone on people (phone) where phone is not null;



create trigger trg_people_updated_at
before update on people
for each row execute function set_updated_at();

create index idx_people_trgm_fullname
  on people using gin ((first_name || ' ' || last_name) gin_trgm_ops);

-- Locations
create table locations (
  id            uuid        primary key default gen_random_uuid(),
  name          text        not null,
  address       text        not null,
  lat           double precision null,
  lng           double precision null,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  created_by    uuid        null,
  updated_by    uuid        null,
  unique (name, address)
);

create trigger trg_locations_updated_at
before update on locations
for each row execute function set_updated_at();

create index idx_locations_name on locations(name);
create index idx_locations_address on locations(address);

-- Rides
create table rides (
  id               uuid        primary key default gen_random_uuid(),
  date_time        timestamptz not null,
  duration_minutes integer     not null check (duration_minutes between 30 and 240),
  origin_id        uuid        not null references locations(id) on delete restrict,
  destination_id   uuid        not null references locations(id) on delete restrict,
  status           ride_status not null default 'tentative',
  cancellation_reason text     null,
  legacy_import    boolean     not null default false,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  created_by       uuid        null,
  updated_by       uuid        null

,
  constraint rides_cancelled_reason_chk
    check (status <> 'cancelled' or coalesce(length(btrim(cancellation_reason)) > 0, false))
);

create trigger trg_rides_updated_at
before update on rides
for each row execute function set_updated_at();

create index idx_rides_status_datetime on rides(status, date_time);
create index idx_rides_origin on rides(origin_id);
create index idx_rides_destination on rides(destination_id);

-- Ride assignments
create table ride_assignments (
  ride_id   uuid not null references rides(id) on delete cascade,
  person_id uuid not null references people(id) on delete restrict,
  role      text not null check (role in ('pilot','passenger')),
  created_at timestamptz not null default now(),
  primary key (ride_id, person_id, role)
);

create index idx_ra_ride on ride_assignments(ride_id);
create index idx_ra_person_role on ride_assignments(person_id, role);

create unique index ux_ra_one_pilot_per_ride
  on ride_assignments(ride_id)
  where role = 'pilot';

-- Enforce <= 2 passengers per ride (DB-level hardening)
create or replace function enforce_max_two_passengers()
returns trigger
language plpgsql as $$
declare
  v_ride uuid;
  v_count int;
begin
  v_ride := coalesce(new.ride_id, old.ride_id);
  select count(*) into v_count
  from ride_assignments
  where ride_id = v_ride and role = 'passenger';

  if v_count > 2 then
    raise exception 'Passenger limit exceeded (max 2)';
  end if;

  return null; -- AFTER/CONSTRAINT triggers ignore returned row
end;
$$;

drop trigger if exists trg_ra_max_two_passengers on ride_assignments;
create constraint trigger trg_ra_max_two_passengers
  after insert or update or delete on ride_assignments
  deferrable initially immediate
  for each row execute function enforce_max_two_passengers();


-- Ride assignment contacts
create table ride_assignment_contacts (
  ride_id            uuid not null references rides(id) on delete cascade,
  passenger_id       uuid not null references people(id) on delete restrict,
  contact_person_id  uuid not null references people(id) on delete restrict,
  created_at         timestamptz not null default now(),
  primary key (ride_id, passenger_id)
);

-- Ride notes
create table ride_notes (
  id          uuid        primary key default gen_random_uuid(),
  ride_id     uuid        not null references rides(id) on delete cascade,
  author_id   uuid        not null references people(id) on delete restrict,
  body        text        not null,
  created_at  timestamptz not null default now()
);
create index idx_ride_notes_ride on ride_notes(ride_id);

-- Pilot certifications
create table pilot_certifications (
  id          uuid        primary key default gen_random_uuid(),
  person_id   uuid        not null references people(id) on delete cascade,
  cert_type   text        not null,
  cert_number text        null,
  issued_on   date        null,
  expires_on  date        null,
  created_at  timestamptz not null default now()
);

-- =====================================
-- STEP 2: Views + masking + RLS/privileges
-- =====================================
-- v1.4-step2-views-rls.sql
-- Purpose: Add role helper, masking helpers, views (masked for non-admins), and RLS + privileges that
-- allow non-admins to read ONLY via views. Base tables remain protected for direct access.
-- Run AFTER the base schema (v1.4 step 1).


set search_path = public;

-- ------------------------------------------------------------------
-- Role helper: is_admin_or_scheduler()
-- ------------------------------------------------------------------
create or replace function is_admin_or_scheduler() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1
    from app_user_roles r
    where r.user_id = auth.uid()
      and r.role_key in ('admin','scheduler')
  );
$$;

-- ------------------------------------------------------------------
-- Masking helpers
-- ------------------------------------------------------------------
create or replace function mask_email(p_email text) returns text
language sql immutable as $$
  select case
    when p_email is null then null
    when position('@' in p_email) = 0 then '***'
    else
      repeat('*', greatest(1, position('@' in p_email) - 1)) || substring(p_email from position('@' in p_email))
  end;
$$;

create or replace function mask_phone(p_phone text) returns text
language sql immutable as $$
  select case
    when p_phone is null then null
    when length(p_phone) >= 4 then repeat('*', greatest(0, length(p_phone) - 4)) || right(p_phone, 4)
    else '****'
  end;
$$;

-- ------------------------------------------------------------------
-- Views
--   - v_people_lookup (masked contact fields for non-admins)
--   - v_rides_list (list view with aggregated names)
--   - v_ride_detail (rich object w/ conditional masking)
-- ------------------------------------------------------------------

-- 1) v_people_lookup
create or replace view v_people_lookup as
select
  p.id,
  p.first_name,
  p.last_name,
  case when is_admin_or_scheduler() then p.email else mask_email(p.email) end as email,
  case when is_admin_or_scheduler() then p.phone else mask_phone(p.phone) end as phone
from people p;

-- Helpful index already on people via trigram; view needs no extra index.

-- 2) v_rides_list
create or replace view v_rides_list as
with ra as (
  select
    r.id as ride_id,
    r.date_time,
    r.duration_minutes,
    r.status,
    o.name as origin_name,
    d.name as destination_name
  from rides r
  join locations o on o.id = r.origin_id
  join locations d on d.id = r.destination_id
),
names as (
  select
    x.ride_id,
    array_agg(distinct case when x.role = 'pilot' then (p.first_name || ' ' || p.last_name) end) filter (where x.role='pilot') as pilot_names,
    array_agg(distinct case when x.role = 'passenger' then (p.first_name || ' ' || p.last_name) end) filter (where x.role='passenger') as passenger_names
  from ride_assignments x
  join people p on p.id = x.person_id
  group by x.ride_id
)
select
  ra.ride_id as id,
  ra.date_time,
  ra.duration_minutes,
  ra.status,
  ra.origin_name,
  ra.destination_name,
  coalesce(names.pilot_names, array[]::text[]) as pilot_names,
  coalesce(names.passenger_names, array[]::text[]) as passenger_names
from ra
left join names on names.ride_id = ra.ride_id;

-- 3) v_ride_detail
create or replace view v_ride_detail as
with base as (
  select
    r.*,
    jsonb_build_object('id', o.id, 'name', o.name, 'address', o.address) as origin,
    jsonb_build_object('id', d.id, 'name', d.name, 'address', d.address) as destination
  from rides r
  join locations o on o.id = r.origin_id
  join locations d on d.id = r.destination_id
),
assigns as (
  select
    ra.ride_id,
    jsonb_agg(
      jsonb_build_object(
        'id', p.id,
        'role', ra.role,
        'first_name', p.first_name,
        'last_name', p.last_name,
        'email', case when is_admin_or_scheduler() then p.email else mask_email(p.email) end,
        'phone', case when is_admin_or_scheduler() then p.phone else mask_phone(p.phone) end
      )
      order by ra.role, p.last_name, p.first_name
    ) as people
  from ride_assignments ra
  join people p on p.id = ra.person_id
  group by ra.ride_id
),
enotes as (
  select
    n.ride_id,
    jsonb_agg(
      jsonb_build_object(
        'id', n.id,
        'author_id', n.author_id,
        'body', n.body,
        'created_at', n.created_at
      ) order by n.created_at
    ) as notes
  from ride_notes n
  group by n.ride_id
),
contacts as (
  select
    c.ride_id,
    jsonb_agg(
      jsonb_build_object(
        'passenger_id', c.passenger_id,
        'contact_person_id', c.contact_person_id
      )
    ) as emergency_contacts
  from ride_assignment_contacts c
  group by c.ride_id
)
select
  b.id,
  b.date_time,
  b.duration_minutes,
  b.status,
  b.cancellation_reason,
  b.legacy_import,
  b.created_at,
  b.updated_at,
  b.origin,
  b.destination,
  coalesce(a.people, '[]'::jsonb) as assignments,
  coalesce(e.notes, '[]'::jsonb) as notes,
  coalesce(c.emergency_contacts, '[]'::jsonb) as emergency_contacts
from base b
left join assigns a on a.ride_id = b.id
left join enotes e on e.ride_id = b.id
left join contacts c on c.ride_id = b.id;

-- ------------------------------------------------------------------
-- RLS + Privileges strategy
--   - Deny base tables to everyone by privileges; only views are granted to authenticated.
--   - Enable RLS on base tables and allow SELECT for authenticated (so views can read),
--     but keep privileges revoked so direct SELECTs on base tables still fail.
-- ------------------------------------------------------------------

-- 0) Revoke all direct table privileges from anon/authenticated
revoke all on all tables in schema public from public, anon, authenticated;
revoke all on all sequences in schema public from public, anon, authenticated;
revoke all on all functions in schema public from public, anon, authenticated;

-- 1) Enable RLS on base tables
alter table app_user_roles           enable row level security;
alter table people                   enable row level security;
alter table locations                enable row level security;
alter table rides                    enable row level security;
alter table ride_assignments         enable row level security;
alter table ride_assignment_contacts enable row level security;
alter table ride_notes               enable row level security;
alter table pilot_certifications     enable row level security;
alter table app_settings               enable row level security;

-- 2) Policies: allow SELECT for authenticated on all base tables
--    (required so views can resolve for non-admins)
do $$
begin
  -- helper to create a simple select policy if it doesn't already exist
  if not exists (
    select 1 from pg_policies where schemaname = 'public' and tablename = 'people' and policyname = 'people_select_authenticated'
  ) then
    create policy people_select_authenticated on people
      for select to authenticated using (true);
  end if;

  if not exists (
    select 1 from pg_policies where schemaname = 'public' and tablename = 'locations' and policyname = 'locations_select_authenticated'
  ) then
    create policy locations_select_authenticated on locations
      for select to authenticated using (true);
  end if;

  if not exists (
    select 1 from pg_policies where schemaname = 'public' and tablename = 'rides' and policyname = 'rides_select_authenticated'
  ) then
    create policy rides_select_authenticated on rides
      for select to authenticated using (true);
  end if;

  if not exists (
    select 1 from pg_policies where schemaname = 'public' and tablename = 'ride_assignments' and policyname = 'ra_select_authenticated'
  ) then
    create policy ra_select_authenticated on ride_assignments
      for select to authenticated using (true);
  end if;

  if not exists (
    select 1 from pg_policies where schemaname = 'public' and tablename = 'ride_assignment_contacts' and policyname = 'rac_select_authenticated'
  ) then
    create policy rac_select_authenticated on ride_assignment_contacts
      for select to authenticated using (true);
  end if;

  if not exists (
    select 1 from pg_policies where schemaname = 'public' and tablename = 'ride_notes' and policyname = 'notes_select_authenticated'
  ) then
    create policy notes_select_authenticated on ride_notes
      for select to authenticated using (true);
  end if;

  if not exists (
    select 1 from pg_policies where schemaname = 'public' and tablename = 'pilot_certifications' and policyname = 'pc_select_authenticated'
  ) then
    create policy pc_select_authenticated on pilot_certifications
      for select to authenticated using (true);
  end if;

  if not exists (
    select 1 from pg_policies where schemaname = 'public' and tablename = 'app_user_roles' and policyname = 'aur_select_authenticated'
  ) then
    create policy aur_select_authenticated on app_user_roles
      for select to authenticated using (user_id = auth.uid());
  end if;


-- people write policies (admin/scheduler only)
if not exists (
  select 1 from pg_policies where schemaname='public' and tablename='people' and policyname='people_insert_admin_scheduler'
) then
  create policy people_insert_admin_scheduler on people
    for insert to authenticated
    with check (is_admin_or_scheduler());
end if;

if not exists (
  select 1 from pg_policies where schemaname='public' and tablename='people' and policyname='people_update_admin_scheduler'
) then
  create policy people_update_admin_scheduler on people
    for update to authenticated
    using (is_admin_or_scheduler())
    with check (is_admin_or_scheduler());
end if;


-- app_settings: allow SELECT to authenticated
if not exists (
  select 1 from pg_policies where schemaname='public' and tablename='app_settings' and policyname='app_settings_select_authenticated'
) then
  create policy app_settings_select_authenticated on app_settings
    for select to authenticated using (true);
end if;
end$$;

-- 3) Grant SELECT on views to authenticated (and nothing else)
grant select on v_people_lookup, v_rides_list, v_ride_detail to authenticated;

-- =====================================
-- STEP 2.1: Seed data (stable UUIDs + a0000006 overlap ride)
-- =====================================
-- v1.4-step2.1-seed.sql (fixed UUIDs)
-- Purpose: Seed test data to exercise views + RLS and prepare for Step 3 validations.
-- Safe to re-run: truncates data (not schema) and reseeds with stable UUIDs.


set search_path = public;

-- 0) Wipe data (not objects)
truncate table
  app_settings,
  ride_assignment_contacts,
  ride_notes,
  ride_assignments,
  pilot_certifications,
  rides,
  locations,
  people,
  app_user_roles
restart identity cascade;

-- Insert default operating hours/timezone
insert into app_settings (id, start_hour, end_hour, timezone)
values (1, 7, 20, 'America/Los_Angeles');


-- 1) People
insert into people (id, first_name, last_name, email, phone, role_affinity, notes)
values
  ('11111111-1111-1111-1111-111111111111','Paula','Pilot','paula.pilot@example.org','2065551111','pilot',null),
  ('22222222-2222-2222-2222-222222222222','Peter','Pilot','peter.pilot@example.org','4255552222','pilot',null),
  ('33333333-3333-3333-3333-333333333333','Alice','Rider','alice.rider@example.org','5095553333','passenger','Wheelchair access needed'),
  ('44444444-4444-4444-4444-444444444444','Bob','Rider','bob.rider@example.org','3605554444','passenger',null),
  ('55555555-5555-5555-5555-555555555555','Carol','Rider','carol.rider@example.org','2535555555','passenger',null),
  ('66666666-6666-6666-6666-666666666666','Eddie','Contact','eddie.contact@example.org','4255556666','emergency_contact',null);

-- 2) Locations
insert into locations (id, name, address, lat, lng) values
  ('aaaaaaa1-0000-0000-0000-000000000001','Clinic North','123 Health Way, Winthrop, WA',48.477,-120.186),
  ('aaaaaaa2-0000-0000-0000-000000000002','Clinic South','987 Care Ave, Twisp, WA',48.366,-120.121),
  ('aaaaaaa3-0000-0000-0000-000000000003','Community Center','50 Main St, Winthrop, WA',48.478,-120.185);

-- 3) Rides covering all statuses (use valid hex UUIDs)
insert into rides (id, date_time, duration_minutes, origin_id, destination_id, status, legacy_import) values
  ('a0000001-0000-0000-0000-000000000001', now() + interval '1 day', 60, 'aaaaaaa3-0000-0000-0000-000000000003', 'aaaaaaa1-0000-0000-0000-000000000001', 'tentative', false);

insert into rides (id, date_time, duration_minutes, origin_id, destination_id, status, legacy_import) values
  ('a0000002-0000-0000-0000-000000000002', now() + interval '2 days', 90, 'aaaaaaa3-0000-0000-0000-000000000003', 'aaaaaaa2-0000-0000-0000-000000000002', 'scheduled', false);

insert into rides (id, date_time, duration_minutes, origin_id, destination_id, status, legacy_import) values
  ('a0000003-0000-0000-0000-000000000003', now() + interval '3 days', 45, 'aaaaaaa1-0000-0000-0000-000000000001', 'aaaaaaa2-0000-0000-0000-000000000002', 'scheduled', false);

insert into rides (id, date_time, duration_minutes, origin_id, destination_id, status, cancellation_reason, legacy_import) values
  ('a0000004-0000-0000-0000-000000000004', now() + interval '4 days', 60, 'aaaaaaa2-0000-0000-0000-000000000002', 'aaaaaaa1-0000-0000-0000-000000000001', 'cancelled', 'Weather', false);

insert into rides (id, date_time, duration_minutes, origin_id, destination_id, status, legacy_import) values
  ('a0000005-0000-0000-0000-000000000005', now() - interval '2 days', 60, 'aaaaaaa3-0000-0000-0000-000000000003', 'aaaaaaa1-0000-0000-0000-000000000001', 'completed', false);

-- Additional ride to test overlap: same datetime as a0000002, no passengers yet
insert into rides (id, date_time, duration_minutes, origin_id, destination_id, status, legacy_import) values
  ('a0000006-0000-0000-0000-000000000006',
   (select date_time from rides where id = 'a0000002-0000-0000-0000-000000000002'),
   60,
   'aaaaaaa1-0000-0000-0000-000000000001',
   'aaaaaaa2-0000-0000-0000-000000000002',
   'scheduled',
   false);


-- 4) Assignments
insert into ride_assignments (ride_id, person_id, role) values
  ('a0000002-0000-0000-0000-000000000002','11111111-1111-1111-1111-111111111111','pilot'),
  ('a0000002-0000-0000-0000-000000000002','33333333-3333-3333-3333-333333333333','passenger');

insert into ride_assignments (ride_id, person_id, role) values
  ('a0000003-0000-0000-0000-000000000003','22222222-2222-2222-2222-222222222222','pilot'),
  ('a0000003-0000-0000-0000-000000000003','44444444-4444-4444-4444-444444444444','passenger'),
  ('a0000003-0000-0000-0000-000000000003','55555555-5555-5555-5555-555555555555','passenger');

insert into ride_assignments (ride_id, person_id, role) values
  ('a0000004-0000-0000-0000-000000000004','11111111-1111-1111-1111-111111111111','pilot');

insert into ride_assignments (ride_id, person_id, role) values
  ('a0000005-0000-0000-0000-000000000005','22222222-2222-2222-2222-222222222222','pilot'),
  ('a0000005-0000-0000-0000-000000000005','33333333-3333-3333-3333-333333333333','passenger');

-- 5) Emergency contact link (Eddie for Alice on ride a0000003)
insert into ride_assignment_contacts (ride_id, passenger_id, contact_person_id) values
  ('a0000003-0000-0000-0000-000000000003','33333333-3333-3333-3333-333333333333','66666666-6666-6666-6666-666666666666');

-- 6) Notes
insert into ride_notes (ride_id, author_id, body) values
  ('a0000002-0000-0000-0000-000000000002','11111111-1111-1111-1111-111111111111','Bring wheelchair ramp.'),
  ('a0000003-0000-0000-0000-000000000003','22222222-2222-2222-2222-222222222222','Pickup at rear entrance.');

-- 7) Pilot certifications
insert into pilot_certifications (person_id, cert_type, cert_number, issued_on, expires_on) values
  ('11111111-1111-1111-1111-111111111111','FAA-PVT','PVT-123','2023-04-01','2026-04-01'),
  ('22222222-2222-2222-2222-222222222222','FAA-PVT','PVT-456','2022-06-15','2025-06-15');

-- 8) App user roles placeholders
insert into app_user_roles (user_id, role_key) values
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','admin'),
  ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb','scheduler');

-- =====================================
-- STEP 3: RPCs + validations (SECURITY DEFINER)
-- =====================================
-- v1.4-step3-rpcs-validations.sql
-- Purpose: Add RPCs (SECURITY DEFINER) that enforce key business rules:
--   - time window (07:00–20:00 America/Los_Angeles)
--   - status transitions
--   - exactly 1 pilot, <= 2 passengers
--   - no overlapping assignment for same person+role
--   - emergency contact must reference an assigned passenger
-- Returns JSONB envelopes: { ok, data, error }
-- Run AFTER step 1 (base schema) and step 2 (views+RLS).

set search_path = public;

-- ------------------------------------------------------------------
-- Helpers
-- ------------------------------------------------------------------

-- Convert to local time and check hour window
create or replace function is_within_operating_hours(ts timestamptz) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare
  v_start int := 7;
  v_end   int := 20;
  v_tz    text := 'America/Los_Angeles';
  v_hour  int;
begin
  -- Read settings if available
  begin
    select start_hour, end_hour, timezone
      into v_start, v_end, v_tz
    from app_settings
    limit 1;
  exception when others then
    -- fallback defaults
    v_start := 7; v_end := 20; v_tz := 'America/Los_Angeles';
  end;

  v_hour := extract(hour from (ts at time zone v_tz));
  return (v_hour >= v_start and v_hour < v_end);
end;
$$;

-- Build json response helpers
create or replace function ok(data jsonb default null) returns jsonb
language sql immutable as $$
  select jsonb_build_object('ok', true, 'data', data, 'error', null);
$$;

create or replace function err(code text, message text, details text default null) returns jsonb
language sql immutable as $$
  select jsonb_build_object('ok', false, 'data', null, 'error', jsonb_build_object('code', code, 'message', message, 'details', details));
$$;

-- ------------------------------------------------------------------
-- Status transition validation
-- ------------------------------------------------------------------
create or replace function validate_status_transition(old_status ride_status, new_status ride_status)
returns boolean
language sql immutable as $$
  select case
    when old_status is null and new_status in ('tentative','scheduled','cancelled') then true
    when old_status = 'tentative' and new_status in ('scheduled','cancelled') then true
    when old_status = 'scheduled' and new_status in ('completed','cancelled') then true
    when old_status = 'completed' and new_status = 'completed' then true
    when old_status = 'cancelled' and new_status = 'cancelled' then true
    else false
  end;
$$;

-- ------------------------------------------------------------------
-- RPC: create_ride
-- ------------------------------------------------------------------
create or replace function create_ride(
  p_datetime timestamptz,
  p_duration_minutes int,
  p_origin_id uuid,
  p_destination_id uuid,
  p_status ride_status default 'tentative',
  p_cancellation_reason text default null,
  p_legacy_import boolean default false
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_id uuid;
begin
  if not is_within_operating_hours(p_datetime) and not p_legacy_import then
    return err('ERR_TIME_WINDOW','Ride time must be between 07:00–20:00 America/Los_Angeles.');
  end if;

  if p_status = 'cancelled' and coalesce(p_cancellation_reason,'') = '' then
    return err('ERR_INVALID_INPUT','cancellation_reason is required when status=cancelled');
  end if;

  insert into rides(id, date_time, duration_minutes, origin_id, destination_id, status, cancellation_reason, legacy_import, created_by, updated_by)
  values (gen_random_uuid(), p_datetime, p_duration_minutes, p_origin_id, p_destination_id, p_status, p_cancellation_reason, p_legacy_import, auth.uid(), auth.uid())
  returning id into v_id;

  return ok(jsonb_build_object('id', v_id));
exception when others then
  return err('ERR_CREATE_RIDE', sqlerrm);
end;
$$;

-- ------------------------------------------------------------------
-- RPC: update_ride (basic fields + status change with validation)
-- ------------------------------------------------------------------
create or replace function update_ride(
  p_id uuid,
  p_datetime timestamptz,
  p_duration_minutes int,
  p_origin_id uuid,
  p_destination_id uuid,
  p_status ride_status,
  p_cancellation_reason text default null,
  p_legacy_import boolean default false
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_old ride_status;
begin
  select status into v_old from rides where id = p_id;
  if v_old is null then
    return err('ERR_NOT_FOUND','Ride not found');
  end if;

  if not validate_status_transition(v_old, p_status) then
    return err('ERR_STATUS_TRANSITION', 'Invalid status transition from '||v_old||' to '||p_status);
  end if;

  if p_status = 'cancelled' and coalesce(p_cancellation_reason,'') = '' then
    return err('ERR_INVALID_INPUT','cancellation_reason is required when status=cancelled');
  end if;

  if not is_within_operating_hours(p_datetime) and not p_legacy_import then
    return err('ERR_TIME_WINDOW','Ride time must be between 07:00–20:00 America/Los_Angeles.');
  end if;

  update rides
     set date_time = p_datetime,
         duration_minutes = p_duration_minutes,
         origin_id = p_origin_id,
         destination_id = p_destination_id,
         status = p_status,
         cancellation_reason = p_cancellation_reason,
         legacy_import = p_legacy_import,
         updated_by = auth.uid()
   where id = p_id;

  return ok(jsonb_build_object('id', p_id));
exception when others then
  return err('ERR_UPDATE_RIDE', sqlerrm);
end;
$$;

-- ------------------------------------------------------------------
-- RPC: assign_person (enforces exactly 1 pilot, <=2 passengers, and no overlap)
-- ------------------------------------------------------------------
create or replace function assign_person(p_ride_id uuid, p_person_id uuid, p_role text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_dt timestamptz;
  v_dur int;
  v_pilot_count int;
  v_passenger_count int;
  v_overlap int;
begin
  if p_role not in ('pilot','passenger') then
    return err('ERR_INVALID_INPUT','role must be pilot or passenger');
  end if;

  select date_time, duration_minutes into v_dt, v_dur from rides where id = p_ride_id;
  if v_dt is null then
    return err('ERR_NOT_FOUND','Ride not found');
  end if;

  -- exactly 1 pilot
  if p_role = 'pilot' then
    select count(*) into v_pilot_count from ride_assignments where ride_id = p_ride_id and role = 'pilot';
    if v_pilot_count >= 1 then
      return err('ERR_DUPLICATE_ROLE','Ride already has a pilot');
    end if;
  end if;

  -- <= 2 passengers
  if p_role = 'passenger' then
    select count(*) into v_passenger_count from ride_assignments where ride_id = p_ride_id and role = 'passenger';
    if v_passenger_count >= 2 then
      return err('ERR_DUPLICATE_ROLE','Ride already has two passengers');
    end if;
  end if;

  -- no overlapping assignment for same person+role (approx using start & end)
  select count(*) into v_overlap
  from ride_assignments ra
  join rides r on r.id = ra.ride_id
  where ra.person_id = p_person_id
    and ra.role = p_role
    and tstzrange(r.date_time, r.date_time + make_interval(mins => r.duration_minutes), '[)')
        && tstzrange(v_dt, v_dt + make_interval(mins => v_dur), '[)');
  if v_overlap > 0 then
    return err('ERR_OVERLAP','Person already assigned to an overlapping ride for the same role');
  end if;

  insert into ride_assignments(ride_id, person_id, role) values (p_ride_id, p_person_id, p_role);
  return ok();
exception when others then
  return err('ERR_ASSIGN', sqlerrm);
end;
$$;

-- ------------------------------------------------------------------
-- RPC: unassign_person
-- ------------------------------------------------------------------
create or replace function unassign_person(p_ride_id uuid, p_person_id uuid, p_role text)
returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  delete from ride_assignments where ride_id = p_ride_id and person_id = p_person_id and role = p_role;
  return ok();
exception when others then
  return err('ERR_UNASSIGN', sqlerrm);
end;
$$;

-- ------------------------------------------------------------------
-- RPC: upsert_person (admin/scheduler only via RLS)
-- ------------------------------------------------------------------
create or replace function upsert_person(
  p_id uuid default null,
  p_first_name text default null,
  p_last_name text default null,
  p_email text default null,
  p_phone text default null,
  p_role_affinity text default null,
  p_notes text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_id uuid;
begin
  if coalesce(btrim(p_first_name),'') = '' or coalesce(btrim(p_last_name),'') = '' then
    return err('ERR_INVALID_INPUT','first_name and last_name are required');
  end if;
  if p_email is null and p_phone is null then
    return err('ERR_INVALID_INPUT','Provide at least one of email or phone');
  end if;
  if p_role_affinity is not null and p_role_affinity not in ('pilot','passenger','emergency_contact') then
    return err('ERR_INVALID_INPUT','role_affinity must be pilot, passenger, or emergency_contact');
  end if;

  if p_id is null then
    insert into people(first_name, last_name, email, phone, role_affinity, notes)
    values (p_first_name, p_last_name, p_email, p_phone, p_role_affinity, p_notes)
    returning id into v_id;
  else
    update people
       set first_name = p_first_name,
           last_name  = p_last_name,
           email      = p_email,
           phone      = p_phone,
           role_affinity = p_role_affinity,
           notes      = p_notes
     where id = p_id
     returning id into v_id;
    if v_id is null then
      return err('ERR_NOT_FOUND','Person not found');
    end if;
  end if;

  return ok(jsonb_build_object('id', v_id));
exception when unique_violation then
  return err('ERR_DUPLICATE','Email or phone already exists');
when others then
  return err('ERR_PERSON_UPSERT', sqlerrm);
end;
$$;


-- ------------------------------------------------------------------
-- RPC: link_emergency_contact (must reference an assigned passenger)
-- ------------------------------------------------------------------
create or replace function link_emergency_contact(p_ride_id uuid, p_passenger_id uuid, p_contact_person_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_exists int;
begin
  select count(*) into v_exists
  from ride_assignments
  where ride_id = p_ride_id
    and person_id = p_passenger_id
    and role = 'passenger';
  if v_exists = 0 then
    return err('ERR_INVALID_INPUT','Passenger is not assigned to the ride');
  end if;

  insert into ride_assignment_contacts(ride_id, passenger_id, contact_person_id)
  values (p_ride_id, p_passenger_id, p_contact_person_id)
  on conflict (ride_id, passenger_id) do update
    set contact_person_id = excluded.contact_person_id;

  return ok();
exception when others then
  return err('ERR_CONTACT', sqlerrm);
end;
$$;

-- ------------------------------------------------------------------
-- Grants
-- ------------------------------------------------------------------
grant execute on function
  create_ride(timestamptz,int,uuid,uuid,ride_status,text,boolean),
  update_ride(uuid,timestamptz,int,uuid,uuid,ride_status,text,boolean),
    upsert_person(uuid,text,text,text,text,text,text),
assign_person(uuid,uuid,text),
  unassign_person(uuid,uuid,text),
  link_emergency_contact(uuid,uuid,uuid),
  is_within_operating_hours(timestamptz),
  validate_status_transition(ride_status,ride_status),
  ok(jsonb),
  err(text,text,text)
to authenticated;

-- End. Now run tests/v1.5-tests.sql to verify behavior.
