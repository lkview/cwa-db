-- CWA Ride Scheduler — Base Schema (v1.4, step 1)
-- Purpose: recreate the entire schema from scratch.
-- This script DROPS and RECREATES the public schema — nothing survives.
-- Run only if you are OK with losing everything in `public`.

begin;

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

-- People
create table people (
  id            uuid        primary key default gen_random_uuid(),
  first_name    text        not null,
  last_name     text        not null,
  email         text        null,
  phone         text        null check (phone ~ '^[0-9]{10}$' or phone is null), -- US-only (10 digits)
  role_affinity text        null,
  notes         text        null,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  created_by    uuid        null,
  updated_by    uuid        null
);

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

commit;
