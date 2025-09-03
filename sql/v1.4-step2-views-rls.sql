-- v1.4-step2-views-rls.sql
-- Purpose: Add role helper, masking helpers, views (masked for non-admins), and RLS + privileges that
-- allow non-admins to read ONLY via views. Base tables remain protected for direct access.
-- Run AFTER the base schema (v1.4 step 1).

begin;

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

create or replace function mask_phone_us10(p_phone text) returns text
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
  case when is_admin_or_scheduler() then p.phone else mask_phone_us10(p.phone) end as phone
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
        'phone', case when is_admin_or_scheduler() then p.phone else mask_phone_us10(p.phone) end
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
end$$;

-- 3) Grant SELECT on views to authenticated (and nothing else)
grant select on v_people_lookup, v_rides_list, v_ride_detail to authenticated;

commit;
