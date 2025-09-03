-- v1.4-step2.1-seed.sql (fixed UUIDs)
-- Purpose: Seed test data to exercise views + RLS and prepare for Step 3 validations.
-- Safe to re-run: truncates data (not schema) and reseeds with stable UUIDs.

begin;

set search_path = public;

-- 0) Wipe data (not objects)
truncate table
  ride_assignment_contacts,
  ride_notes,
  ride_assignments,
  pilot_certifications,
  rides,
  locations,
  people,
  app_user_roles
restart identity cascade;

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

commit;
