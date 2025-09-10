-- CWA Ride Scheduler — v1.9 Phase 1 RUN (Supabase-compatible, final backslash fixes)

BEGIN;

DROP SCHEMA IF EXISTS cwa CASCADE;
CREATE SCHEMA cwa;
SET search_path = cwa, public;

DO $$ BEGIN
  CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
EXCEPTION WHEN OTHERS THEN NULL;
END $$;

DO $$ BEGIN
  CREATE EXTENSION IF NOT EXISTS pgcrypto;
EXCEPTION WHEN OTHERS THEN NULL;
END $$;

CREATE TABLE cwa.roles (
  role_key text PRIMARY KEY
);

CREATE TABLE cwa.statuses (
  status_key text PRIMARY KEY,
  role_family text NOT NULL
);

CREATE TABLE cwa.role_allowed_statuses (
  role_key   text NOT NULL REFERENCES cwa.roles(role_key) ON DELETE CASCADE,
  status_key text NOT NULL REFERENCES cwa.statuses(status_key) ON DELETE CASCADE,
  PRIMARY KEY (role_key, status_key)
);

CREATE TABLE cwa.people (
  person_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  first_name text NOT NULL,
  last_name  text NOT NULL,
  email      text,
  phone      text,
  status_key text NOT NULL REFERENCES cwa.statuses(status_key),
  notes      text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT email_format_ok CHECK (
    email IS NULL OR email ~* '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'
  ),
  CONSTRAINT phone_format_ok CHECK (
    phone IS NULL OR length(regexp_replace(phone, '\D', '', 'g')) >= 7
  )
);

CREATE TABLE cwa.person_roles (
  person_id uuid NOT NULL REFERENCES cwa.people(person_id) ON DELETE CASCADE,
  role_key  text NOT NULL REFERENCES cwa.roles(role_key) ON DELETE CASCADE,
  PRIMARY KEY (person_id, role_key)
);

CREATE TABLE cwa.people_unavailability (
  unavailability_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  person_id uuid NOT NULL REFERENCES cwa.people(person_id) ON DELETE CASCADE,
  start_at timestamptz NOT NULL,
  end_at   timestamptz NOT NULL,
  CHECK (start_at < end_at)
);

CREATE TABLE cwa.ride_events (
  ride_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  start_at timestamptz NOT NULL,
  end_at   timestamptz NOT NULL,
  status   text NOT NULL CHECK (status IN ('tentative','scheduled','completed','cancelled')),
  cancel_reason text,
  notes    text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CHECK (start_at < end_at)
);

CREATE TABLE cwa.ride_assignments (
  assignment_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  ride_id   uuid NOT NULL REFERENCES cwa.ride_events(ride_id) ON DELETE CASCADE,
  person_id uuid NOT NULL REFERENCES cwa.people(person_id) ON DELETE CASCADE,
  role_key  text NOT NULL REFERENCES cwa.roles(role_key) ON DELETE RESTRICT,
  UNIQUE (ride_id, role_key, person_id)
);

CREATE TABLE cwa.ride_passenger_contacts (
  link_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  ride_id uuid NOT NULL REFERENCES cwa.ride_events(ride_id) ON DELETE CASCADE,
  passenger_id uuid NOT NULL REFERENCES cwa.people(person_id) ON DELETE CASCADE,
  contact_person_id uuid NOT NULL REFERENCES cwa.people(person_id) ON DELETE CASCADE,
  UNIQUE (ride_id, passenger_id, contact_person_id)
);

CREATE TABLE cwa.cert_types ( cert_key text PRIMARY KEY );

CREATE TABLE cwa.person_certifications (
  person_cert_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  person_id uuid NOT NULL REFERENCES cwa.people(person_id) ON DELETE CASCADE,
  cert_key  text NOT NULL REFERENCES cwa.cert_types(cert_key) ON DELETE CASCADE,
  expires_on date,
  UNIQUE (person_id, cert_key)
);

CREATE TABLE cwa.app_user_roles (
  auth_user_id uuid NOT NULL,
  role_key     text NOT NULL REFERENCES cwa.roles(role_key) ON DELETE CASCADE,
  PRIMARY KEY (auth_user_id, role_key)
);

CREATE TABLE cwa.app_user_people (
  auth_user_id uuid PRIMARY KEY,
  person_id    uuid NOT NULL REFERENCES cwa.people(person_id) ON DELETE CASCADE
);

CREATE OR REPLACE FUNCTION cwa.current_auth_uid() RETURNS uuid
LANGUAGE plpgsql STABLE AS $$
DECLARE
  claims jsonb;
  subtext text;
BEGIN
  BEGIN
    claims := current_setting('request.jwt.claims', true)::jsonb;
  EXCEPTION WHEN others THEN
    claims := NULL;
  END;
  IF claims IS NULL THEN
    RETURN NULL;
  END IF;
  subtext := claims->>'sub';
  IF subtext IS NULL OR subtext = '' THEN
    RETURN NULL;
  END IF;
  RETURN subtext::uuid;
EXCEPTION WHEN others THEN
  RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION cwa.is_admin_or_scheduler(p_auth_user_id uuid DEFAULT cwa.current_auth_uid())
RETURNS boolean
LANGUAGE sql STABLE AS $$
  SELECT EXISTS (
    SELECT 1
    FROM cwa.app_user_roles r
    WHERE r.auth_user_id = p_auth_user_id
      AND r.role_key IN ('admin','scheduler')
  );
$$;

CREATE OR REPLACE FUNCTION cwa.mask_name(p_first text, p_last text, p_can_view boolean)
RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN p_can_view THEN trim(coalesce(p_first,'') || ' ' || coalesce(p_last,''))
    ELSE trim(coalesce(p_first,'') || ' ' || LEFT(coalesce(p_last,''),1) || CASE WHEN coalesce(p_last,'')<>'' THEN '…' ELSE '' END)
  END;
$$;

CREATE OR REPLACE FUNCTION cwa.mask_email(p_email text, p_can_view boolean)
RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN p_can_view OR p_email IS NULL THEN p_email
    ELSE regexp_replace(p_email, '^(.)([^@]*)(@.*)$', '\1•••\3')
  END;
$$;

CREATE OR REPLACE FUNCTION cwa.mask_phone(p_phone text, p_can_view boolean)
RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN p_can_view OR p_phone IS NULL THEN p_phone
    ELSE
      CASE
        WHEN length(regexp_replace(p_phone,'\D','','g')) >= 4
          THEN '•••' || right(regexp_replace(p_phone,'\D','','g'), 4)
        ELSE '•••' || coalesce(p_phone,'')
      END
  END;
$$;

CREATE OR REPLACE FUNCTION cwa._can_view_pii() RETURNS boolean
LANGUAGE sql STABLE AS $$
  SELECT cwa.is_admin_or_scheduler();
$$;

CREATE OR REPLACE VIEW cwa.v_pilot_roster AS
SELECT
  p.person_id,
  cwa.mask_name(p.first_name, p.last_name, cwa._can_view_pii()) AS full_name,
  cwa.mask_email(p.email, cwa._can_view_pii()) AS email,
  cwa.mask_phone(p.phone, cwa._can_view_pii()) AS phone,
  p.status_key,
  (p.email IS NOT NULL OR p.phone IS NOT NULL) AS has_contact_method,
  (p.status_key = 'active') AS assignable,
  (p.status_key IN ('active','in_training')) AS show_on_roster
FROM cwa.people p
JOIN cwa.person_roles pr ON pr.person_id = p.person_id AND pr.role_key = 'pilot';

CREATE OR REPLACE VIEW cwa.v_passenger_roster AS
SELECT
  p.person_id,
  cwa.mask_name(p.first_name, p.last_name, cwa._can_view_pii()) AS full_name,
  cwa.mask_email(p.email, cwa._can_view_pii()) AS email,
  cwa.mask_phone(p.phone, cwa._can_view_pii()) AS phone,
  p.status_key,
  (p.email IS NOT NULL OR p.phone IS NOT NULL) AS has_contact_method,
  (p.status_key = 'interested') AS assignable,
  (p.status_key IN ('interested')) AS show_on_roster
FROM cwa.people p
JOIN cwa.person_roles pr ON pr.person_id = p.person_id AND pr.role_key = 'passenger';

CREATE OR REPLACE VIEW cwa.v_ride_list AS
SELECT
  r.ride_id,
  r.start_at,
  r.end_at,
  r.status,
  COUNT(*) FILTER (WHERE ra.role_key = 'pilot') AS pilot_count,
  COUNT(*) FILTER (WHERE ra.role_key = 'passenger') AS passenger_count
FROM cwa.ride_events r
LEFT JOIN cwa.ride_assignments ra ON ra.ride_id = r.ride_id
GROUP BY r.ride_id;

CREATE OR REPLACE VIEW cwa.v_ride_detail AS
SELECT
  r.ride_id,
  r.start_at,
  r.end_at,
  r.status,
  r.cancel_reason,
  r.notes,
  ra.role_key,
  p.person_id,
  cwa.mask_name(p.first_name, p.last_name, cwa._can_view_pii()) AS person_name,
  cwa.mask_email(p.email, cwa._can_view_pii()) AS person_email,
  cwa.mask_phone(p.phone, cwa._can_view_pii()) AS person_phone
FROM cwa.ride_events r
LEFT JOIN cwa.ride_assignments ra ON ra.ride_id = r.ride_id
LEFT JOIN cwa.people p ON p.person_id = ra.person_id;

CREATE INDEX ON cwa.ride_events (start_at);
CREATE INDEX ON cwa.ride_events (end_at);
CREATE INDEX ON cwa.ride_assignments (ride_id);
CREATE INDEX ON cwa.ride_assignments (person_id);
CREATE INDEX ON cwa.people_unavailability (person_id, start_at, end_at);

INSERT INTO cwa.roles(role_key) VALUES ('pilot'), ('passenger'), ('admin'), ('scheduler') ON CONFLICT DO NOTHING;

INSERT INTO cwa.statuses(status_key, role_family) VALUES
  ('active','pilot'),
  ('in_training','pilot'),
  ('inactive','pilot'),
  ('interested','passenger'),
  ('not_interested','passenger'),
  ('deceased','passenger')
ON CONFLICT DO NOTHING;

INSERT INTO cwa.role_allowed_statuses(role_key, status_key) VALUES
  ('pilot','active'),
  ('pilot','in_training'),
  ('passenger','interested')
ON CONFLICT DO NOTHING;

INSERT INTO cwa.cert_types(cert_key) VALUES ('TRISHAW-BASICS'), ('FIRST-AID') ON CONFLICT DO NOTHING;

WITH inserted AS (
  INSERT INTO cwa.people(first_name,last_name,email,phone,status_key)
  VALUES
    ('Alice','Active','alice@example.com','+1 (206) 555-1001','active'),
    ('Paul','Passenger','paul@example.com','+1 (206) 555-2002','interested'),
    ('Ian','InTraining','ian@example.com','+1 (206) 555-3003','in_training'),
    ('Nina','NoPhone',NULL,'+1 (206) 555-4004','interested')
  RETURNING person_id, first_name, last_name
),
role_map AS (
  SELECT * FROM (VALUES
    ('Alice','Active','pilot'),
    ('Paul','Passenger','passenger'),
    ('Ian','InTraining','pilot'),
    ('Nina','NoPhone','passenger')
  ) AS m(first_name,last_name,role_key)
)
INSERT INTO cwa.person_roles(person_id, role_key)
SELECT i.person_id, m.role_key
FROM inserted i
JOIN role_map m USING (first_name,last_name);

INSERT INTO cwa.app_user_roles(auth_user_id, role_key) VALUES
  ('00000000-0000-0000-0000-000000000001','admin'),
  ('00000000-0000-0000-0000-000000000002','scheduler')
ON CONFLICT DO NOTHING;

INSERT INTO cwa.app_user_people(auth_user_id, person_id)
SELECT '00000000-0000-0000-0000-000000000001'::uuid, p.person_id
FROM cwa.people p
WHERE p.first_name='Alice' AND p.last_name='Active'
ON CONFLICT DO NOTHING;

COMMIT;