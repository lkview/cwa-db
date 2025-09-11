
-- CWA Ride Scheduler — v1.9 Phase 3 RUN (full rebuild: Phases 1 + 2 + 3)
-- This script DROPS and recreates the schema, installs Phase 1 core, Phase 2 RPCs & constraints,
-- and adds Phase 3 features: locations, structured pickup/dropoff, chaperone role,
-- self-service RPCs, self-service views, and minor indexes.
-- Safe to run repeatedly; seeds included for reproducibility.

BEGIN;

DROP SCHEMA IF EXISTS cwa CASCADE;
CREATE SCHEMA cwa;
SET search_path = cwa, public;

-- === Extensions ===
DO $$ BEGIN
  CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
EXCEPTION WHEN OTHERS THEN NULL;
END $$;

DO $$ BEGIN
  CREATE EXTENSION IF NOT EXISTS pgcrypto;
EXCEPTION WHEN OTHERS THEN NULL;
END $$;

-- === Phase 1: Core tables & views ===
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

-- Phase 3 addition: locations + structured pickup/dropoff fields
CREATE TABLE cwa.locations (
  location_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  address_line1 text,
  address_line2 text,
  city text,
  region text,
  postal_code text,
  latitude double precision,
  longitude double precision,
  notes text
);

CREATE TABLE cwa.ride_events (
  ride_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  start_at timestamptz NOT NULL,
  end_at   timestamptz NOT NULL,
  status   text NOT NULL CHECK (status IN ('tentative','scheduled','completed','cancelled')),
  cancel_reason text,
  notes    text,
  pickup_location_id uuid REFERENCES cwa.locations(location_id),
  dropoff_location_id uuid REFERENCES cwa.locations(location_id),
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

-- Helpers
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

-- Views
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
  r.pickup_location_id,
  r.dropoff_location_id,
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
  r.pickup_location_id,
  r.dropoff_location_id,
  ra.role_key,
  p.person_id,
  cwa.mask_name(p.first_name, p.last_name, cwa._can_view_pii()) AS person_name,
  cwa.mask_email(p.email, cwa._can_view_pii()) AS person_email,
  cwa.mask_phone(p.phone, cwa._can_view_pii()) AS person_phone
FROM cwa.ride_events r
LEFT JOIN cwa.ride_assignments ra ON ra.ride_id = r.ride_id
LEFT JOIN cwa.people p ON p.person_id = ra.person_id;

-- Self-service views (Phase 3)
CREATE OR REPLACE VIEW cwa.v_my_rides AS
SELECT d.*
FROM cwa.v_ride_detail d
JOIN cwa.app_user_people aup ON aup.person_id = d.person_id
WHERE aup.auth_user_id = cwa.current_auth_uid()
  AND d.role_key = 'pilot';

CREATE OR REPLACE VIEW cwa.v_my_ec_rides AS
SELECT r.*
FROM cwa.ride_events r
JOIN cwa.ride_passenger_contacts ec
  ON ec.ride_id = r.ride_id
JOIN cwa.app_user_people aup
  ON aup.person_id = ec.contact_person_id
WHERE aup.auth_user_id = cwa.current_auth_uid();

-- Indexes
CREATE INDEX ON cwa.ride_events (start_at);
CREATE INDEX ON cwa.ride_events (end_at);
CREATE INDEX ON cwa.ride_assignments (ride_id);
CREATE INDEX ON cwa.ride_assignments (person_id);
CREATE INDEX ON cwa.people_unavailability (person_id, start_at, end_at);
CREATE INDEX ON cwa.ride_events (pickup_location_id);
CREATE INDEX ON cwa.ride_events (dropoff_location_id);

-- Seeds
INSERT INTO cwa.roles(role_key) VALUES ('pilot'), ('passenger'), ('admin'), ('scheduler'), ('chaperone') ON CONFLICT DO NOTHING;

INSERT INTO cwa.statuses(status_key, role_family) VALUES
  ('active','pilot'),
  ('in_training','pilot'),
  ('inactive','pilot'),
  ('interested','passenger'),
  ('not_interested','passenger'),
  ('deceased','passenger'),
  ('available','support'),
  ('unavailable','support')
ON CONFLICT DO NOTHING;

INSERT INTO cwa.role_allowed_statuses(role_key, status_key) VALUES
  ('pilot','active'),
  ('pilot','in_training'),
  ('passenger','interested'),
  ('chaperone','available')
ON CONFLICT DO NOTHING;

INSERT INTO cwa.cert_types(cert_key) VALUES ('TRISHAW-BASICS'), ('FIRST-AID') ON CONFLICT DO NOTHING;

WITH inserted AS (
  INSERT INTO cwa.people(first_name,last_name,email,phone,status_key)
  VALUES
    ('Alice','Active','alice@example.com','+1 (206) 555-1001','active'),
    ('Paul','Passenger','paul@example.com','+1 (206) 555-2002','interested'),
    ('Ian','InTraining','ian@example.com','+1 (206) 555-3003','in_training'),
    ('Nina','NoPhone',NULL,'+1 (206) 555-4004','interested'),
    ('Charlie','Chaperone','charlie@example.com','+1 (206) 555-5005','available')
  RETURNING person_id, first_name, last_name
),
role_map AS (
  SELECT * FROM (VALUES
    ('Alice','Active','pilot'),
    ('Paul','Passenger','passenger'),
    ('Ian','InTraining','pilot'),
    ('Nina','NoPhone','passenger'),
    ('Charlie','Chaperone','chaperone')
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

-- Sample locations
INSERT INTO cwa.locations(name, address_line1, city, region, postal_code, latitude, longitude)
VALUES
  ('Community Center','123 Main St','Seattle','WA','98101',47.6097,-122.3331),
  ('Park Pavilion','456 Park Ave','Seattle','WA','98109',47.6239,-122.3560)
ON CONFLICT DO NOTHING;

-- === Phase 2: JSON result helper & business RPCs ===
CREATE OR REPLACE FUNCTION cwa._json_result(
  p_ok boolean,
  p_data jsonb DEFAULT NULL,
  p_err_code text DEFAULT NULL,
  p_message text DEFAULT NULL,
  p_warnings jsonb DEFAULT NULL
) RETURNS jsonb
LANGUAGE sql IMMUTABLE AS $$
  SELECT jsonb_strip_nulls(
    jsonb_build_object('ok', p_ok, 'data', p_data, 'err_code', p_err_code, 'message', p_message, 'warnings', p_warnings)
  );
$$;

CREATE OR REPLACE FUNCTION cwa.operating_hours() 
RETURNS TABLE(day_start time, day_end time) 
LANGUAGE sql STABLE AS $$
  SELECT time '09:00', time '18:00';
$$;

CREATE OR REPLACE FUNCTION cwa._to_local_time(p_ts timestamptz)
RETURNS time LANGUAGE sql STABLE AS $$
  SELECT (p_ts AT TIME ZONE 'America/Los_Angeles')::time;
$$;

CREATE OR REPLACE FUNCTION cwa.is_within_operating_hours(p_start timestamptz, p_end timestamptz)
RETURNS boolean
LANGUAGE plpgsql STABLE AS $$
DECLARE
  s time; e time; d1 date; d2 date;
BEGIN
  SELECT day_start, day_end INTO s, e FROM cwa.operating_hours();
  d1 := (p_start AT TIME ZONE 'America/Los_Angeles')::date;
  d2 := (p_end   AT TIME ZONE 'America/Los_Angeles')::date;
  IF d1 <> d2 THEN RETURN FALSE; END IF;
  IF cwa._to_local_time(p_start) < s OR cwa._to_local_time(p_end) > e THEN RETURN FALSE; END IF;
  RETURN TRUE;
END;
$$;

CREATE OR REPLACE FUNCTION cwa._status_allowed_for_role(p_person_id uuid, p_role text)
RETURNS boolean
LANGUAGE sql STABLE AS $$
  SELECT EXISTS (
    SELECT 1
    FROM cwa.people pe
    JOIN cwa.role_allowed_statuses ras ON ras.status_key = pe.status_key
    WHERE pe.person_id = p_person_id AND ras.role_key = p_role
  );
$$;

CREATE OR REPLACE FUNCTION cwa._pilot_is_assignable(p_person_id uuid)
RETURNS boolean
LANGUAGE sql STABLE AS $$
  SELECT EXISTS (
    SELECT 1 FROM cwa.people pe
    WHERE pe.person_id = p_person_id AND pe.status_key = 'active'
  );
$$;

CREATE OR REPLACE FUNCTION cwa._pilot_assignment_warnings(p_person_id uuid)
RETURNS jsonb
LANGUAGE sql STABLE AS $$
  WITH missing AS (
    SELECT ct.cert_key
    FROM cwa.cert_types ct
    LEFT JOIN cwa.person_certifications pc
      ON pc.person_id = p_person_id AND pc.cert_key = ct.cert_key
    WHERE pc.person_cert_id IS NULL
  ),
  expired AS (
    SELECT pc.cert_key
    FROM cwa.person_certifications pc
    WHERE pc.person_id = p_person_id AND pc.expires_on IS NOT NULL AND pc.expires_on < current_date
  )
  SELECT jsonb_build_object(
    'missing', (SELECT coalesce(jsonb_agg(cert_key), '[]'::jsonb) FROM missing),
    'expired', (SELECT coalesce(jsonb_agg(cert_key), '[]'::jsonb) FROM expired)
  );
$$;

CREATE OR REPLACE FUNCTION cwa._is_unavailable(p_person_id uuid, p_start timestamptz, p_end timestamptz)
RETURNS boolean
LANGUAGE sql STABLE AS $$
  SELECT EXISTS (
    SELECT 1
    FROM cwa.people_unavailability pu
    WHERE pu.person_id = p_person_id
      AND tstzrange(pu.start_at, pu.end_at, '[)') && tstzrange(p_start, p_end, '[)')
  );
$$;

-- Phase 2 + 3: save_ride accepts pickup/dropoff location ids
CREATE OR REPLACE FUNCTION cwa.save_ride(p_ride jsonb)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_auth uuid := cwa.current_auth_uid();
  v_id uuid;
  v_start timestamptz;
  v_end timestamptz;
  v_status text;
  v_cancel_reason text;
  v_pick uuid;
  v_drop uuid;
  v_existing cwa.ride_events%ROWTYPE;
  v_now timestamptz := now();
  v_allowed boolean;
BEGIN
  IF NOT cwa.is_admin_or_scheduler(v_auth) THEN
    RETURN cwa._json_result(false, NULL, 'ERR_PRIVS', 'Only admin/scheduler may write.');
  END IF;

  v_id := COALESCE((p_ride->>'ride_id')::uuid, gen_random_uuid());
  v_start := (p_ride->>'start_at')::timestamptz;
  v_end   := (p_ride->>'end_at')::timestamptz;
  v_status := COALESCE(p_ride->>'status', 'tentative');
  v_cancel_reason := p_ride->>'cancel_reason';
  v_pick := (p_ride->>'pickup_location_id')::uuid;
  v_drop := (p_ride->>'dropoff_location_id')::uuid;

  IF v_start IS NULL OR v_end IS NULL OR v_start >= v_end THEN
    RETURN cwa._json_result(false, NULL, 'ERR_INPUT', 'start_at/end_at invalid');
  END IF;

  IF NOT cwa.is_within_operating_hours(v_start, v_end) THEN
    RETURN cwa._json_result(false, NULL, 'ERR_HOURS', 'Ride outside operating hours');
  END IF;

  IF v_pick IS NOT NULL AND NOT EXISTS (SELECT 1 FROM cwa.locations WHERE location_id=v_pick) THEN
    RETURN cwa._json_result(false, NULL, 'ERR_INPUT', 'pickup_location_id not found');
  END IF;
  IF v_drop IS NOT NULL AND NOT EXISTS (SELECT 1 FROM cwa.locations WHERE location_id=v_drop) THEN
    RETURN cwa._json_result(false, NULL, 'ERR_INPUT', 'dropoff_location_id not found');
  END IF;

  SELECT * INTO v_existing FROM cwa.ride_events WHERE ride_id = v_id;

  IF v_existing.ride_id IS NULL THEN
    INSERT INTO cwa.ride_events(ride_id, start_at, end_at, status, cancel_reason, notes, pickup_location_id, dropoff_location_id)
    VALUES (v_id, v_start, v_end, v_status, v_cancel_reason, p_ride->>'notes', v_pick, v_drop);
  ELSE
    IF v_existing.end_at < v_now THEN
      IF v_existing.status = 'scheduled' AND v_status = 'completed' AND v_now < v_existing.end_at + interval '24 hours' THEN
        UPDATE cwa.ride_events SET status = 'completed', updated_at = now()
        WHERE ride_id = v_id;
      ELSE
        RETURN cwa._json_result(false, NULL, 'ERR_IMMUTABLE', 'Historical ride: times and assignments immutable');
      END IF;
    ELSE
      v_allowed :=
        (v_existing.status = 'tentative' AND v_status IN ('scheduled','cancelled')) OR
        (v_existing.status = 'scheduled' AND v_status IN ('completed','cancelled')) OR
        (v_existing.status IS NULL);

      IF NOT v_allowed THEN
        RETURN cwa._json_result(false, NULL, 'ERR_STATE', 'Forbidden state transition');
      END IF;

      IF v_status = 'cancelled' AND coalesce(trim(v_cancel_reason),'') = '' THEN
        RETURN cwa._json_result(false, NULL, 'ERR_CANCEL_REASON', 'Cancel reason required');
      END IF;

      UPDATE cwa.ride_events
      SET start_at = v_start,
          end_at = v_end,
          status = v_status,
          cancel_reason = v_cancel_reason,
          notes = p_ride->>'notes',
          pickup_location_id = v_pick,
          dropoff_location_id = v_drop,
          updated_at = now()
      WHERE ride_id = v_id;
    END IF;
  END IF;

  RETURN cwa._json_result(true, jsonb_build_object('ride_id', v_id));
END;
$$;

CREATE OR REPLACE FUNCTION cwa.assign_person(p_ride_id uuid, p_person_id uuid, p_role text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_auth uuid := cwa.current_auth_uid();
  v_r cwa.ride_events%ROWTYPE;
  v_p cwa.people%ROWTYPE;
  v_has_role boolean;
  v_warn jsonb := '{}'::jsonb;
BEGIN
  IF NOT cwa.is_admin_or_scheduler(v_auth) THEN
    RETURN cwa._json_result(false, NULL, 'ERR_PRIVS', 'Only admin/scheduler may write.');
  END IF;

  SELECT * INTO v_r FROM cwa.ride_events WHERE ride_id = p_ride_id;
  IF v_r.ride_id IS NULL THEN
    RETURN cwa._json_result(false, NULL, 'ERR_INPUT', 'Ride not found');
  END IF;

  IF v_r.end_at < now() THEN
    RETURN cwa._json_result(false, NULL, 'ERR_IMMUTABLE', 'Historical ride');
  END IF;

  SELECT * INTO v_p FROM cwa.people WHERE person_id = p_person_id;
  IF v_p.person_id IS NULL THEN
    RETURN cwa._json_result(false, NULL, 'ERR_INPUT', 'Person not found');
  END IF;

  v_has_role := EXISTS (SELECT 1 FROM cwa.person_roles WHERE person_id = p_person_id AND role_key = p_role);
  IF NOT v_has_role THEN
    RETURN cwa._json_result(false, NULL, 'ERR_ROLE', 'Person does not hold required role');
  END IF;

  IF NOT cwa._status_allowed_for_role(p_person_id, p_role) THEN
    RETURN cwa._json_result(false, NULL, 'ERR_STATUS', 'Status not allowed for this role');
  END IF;

  IF p_role = 'pilot' AND NOT cwa._pilot_is_assignable(p_person_id) THEN
    RETURN cwa._json_result(false, NULL, 'ERR_STATUS', 'Pilot must be active to assign');
  END IF;

  IF cwa._is_unavailable(p_person_id, v_r.start_at, v_r.end_at) THEN
    RETURN cwa._json_result(false, NULL, 'ERR_UNAVAILABLE', 'Person unavailable for ride window');
  END IF;

  INSERT INTO cwa.ride_assignments(ride_id, person_id, role_key)
  VALUES (p_ride_id, p_person_id, p_role)
  ON CONFLICT (ride_id, role_key, person_id) DO NOTHING;

  IF p_role = 'pilot' THEN
    v_warn := cwa._pilot_assignment_warnings(p_person_id);
  END IF;

  RETURN cwa._json_result(true, jsonb_build_object('ride_id', p_ride_id, 'person_id', p_person_id, 'role', p_role), NULL, NULL, v_warn);
END;
$$;

CREATE OR REPLACE FUNCTION cwa.unassign_person(p_ride_id uuid, p_person_id uuid, p_role text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_auth uuid := cwa.current_auth_uid();
  v_r cwa.ride_events%ROWTYPE;
  v_exists boolean;
BEGIN
  IF NOT cwa.is_admin_or_scheduler(v_auth) THEN
    RETURN cwa._json_result(false, NULL, 'ERR_PRIVS', 'Only admin/scheduler may write.');
  END IF;

  SELECT * INTO v_r FROM cwa.ride_events WHERE ride_id = p_ride_id;
  IF v_r.ride_id IS NULL THEN
    RETURN cwa._json_result(false, NULL, 'ERR_INPUT', 'Ride not found');
  END IF;

  IF v_r.end_at < now() THEN
    RETURN cwa._json_result(false, NULL, 'ERR_IMMUTABLE', 'Historical ride');
  END IF;

  v_exists := EXISTS (SELECT 1 FROM cwa.ride_assignments WHERE ride_id = p_ride_id AND person_id = p_person_id AND role_key = p_role);
  IF NOT v_exists THEN
    RETURN cwa._json_result(false, NULL, 'ERR_INPUT', 'Assignment not found');
  END IF;

  DELETE FROM cwa.ride_assignments WHERE ride_id = p_ride_id AND person_id = p_person_id AND role_key = p_role;

  RETURN cwa._json_result(true, jsonb_build_object('ride_id', p_ride_id, 'person_id', p_person_id, 'role', p_role));
END;
$$;

CREATE OR REPLACE FUNCTION cwa.link_emergency_contact(p_ride_id uuid, p_passenger_id uuid, p_contact_person_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_auth uuid := cwa.current_auth_uid();
  v_r cwa.ride_events%ROWTYPE;
  v_pax_assigned boolean;
  v_ec cwa.people%ROWTYPE;
BEGIN
  IF NOT cwa.is_admin_or_scheduler(v_auth) THEN
    RETURN cwa._json_result(false, NULL, 'ERR_PRIVS', 'Only admin/scheduler may write.');
  END IF;

  SELECT * INTO v_r FROM cwa.ride_events WHERE ride_id = p_ride_id;
  IF v_r.ride_id IS NULL THEN
    RETURN cwa._json_result(false, NULL, 'ERR_INPUT', 'Ride not found');
  END IF;

  v_pax_assigned := EXISTS (
    SELECT 1 FROM cwa.ride_assignments
    WHERE ride_id = p_ride_id AND person_id = p_passenger_id AND role_key = 'passenger'
  );
  IF NOT v_pax_assigned THEN
    RETURN cwa._json_result(false, NULL, 'ERR_EC_LINK', 'Passenger must be assigned before linking EC');
  END IF;

  SELECT * INTO v_ec FROM cwa.people WHERE person_id = p_contact_person_id;
  IF v_ec.person_id IS NULL THEN
    RETURN cwa._json_result(false, NULL, 'ERR_INPUT', 'EC person not found');
  END IF;

  IF cwa._is_unavailable(p_contact_person_id, v_r.start_at, v_r.end_at) THEN
    RETURN cwa._json_result(false, NULL, 'ERR_UNAVAILABLE', 'EC unavailable for ride window');
  END IF;

  INSERT INTO cwa.ride_passenger_contacts(ride_id, passenger_id, contact_person_id)
  VALUES (p_ride_id, p_passenger_id, p_contact_person_id)
  ON CONFLICT DO NOTHING;

  RETURN cwa._json_result(true, jsonb_build_object('ride_id', p_ride_id, 'passenger_id', p_passenger_id, 'contact_person_id', p_contact_person_id));
END;
$$;

CREATE OR REPLACE FUNCTION cwa.unlink_emergency_contact(p_ride_id uuid, p_passenger_id uuid, p_contact_person_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_auth uuid := cwa.current_auth_uid();
  v_exists boolean;
BEGIN
  IF NOT cwa.is_admin_or_scheduler(v_auth) THEN
    RETURN cwa._json_result(false, NULL, 'ERR_PRIVS', 'Only admin/scheduler may write.');
  END IF;

  v_exists := EXISTS (
    SELECT 1 FROM cwa.ride_passenger_contacts
    WHERE ride_id = p_ride_id AND passenger_id = p_passenger_id AND contact_person_id = p_contact_person_id
  );

  IF NOT v_exists THEN
    RETURN cwa._json_result(false, NULL, 'ERR_INPUT', 'EC link not found');
  END IF;

  DELETE FROM cwa.ride_passenger_contacts
  WHERE ride_id = p_ride_id AND passenger_id = p_passenger_id AND contact_person_id = p_contact_person_id;

  RETURN cwa._json_result(true, jsonb_build_object('ride_id', p_ride_id, 'passenger_id', p_passenger_id, 'contact_person_id', p_contact_person_id));
END;
$$;

-- Phase 2: deferrable constraints (composition: 1 pilot, ≤2 passengers; overlaps across rides)
CREATE OR REPLACE FUNCTION cwa._check_composition()
RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  v_pilots int;
  v_pax int;
BEGIN
  SELECT
    COUNT(*) FILTER (WHERE ra.role_key='pilot'),
    COUNT(*) FILTER (WHERE ra.role_key='passenger')
  INTO v_pilots, v_pax
  FROM cwa.ride_assignments ra
  WHERE ra.ride_id = COALESCE(NEW.ride_id, OLD.ride_id);

  IF v_pilots > 1 THEN
    RAISE EXCEPTION 'ERR_COMPOSITION: more than one pilot on a ride';
  END IF;

  IF v_pax > 2 THEN
    RAISE EXCEPTION 'ERR_COMPOSITION: more than two passengers on a ride';
  END IF;

  RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS trg_composition_insupd ON cwa.ride_assignments;
CREATE CONSTRAINT TRIGGER trg_composition_insupd
AFTER INSERT OR UPDATE OR DELETE ON cwa.ride_assignments
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION cwa._check_composition();

CREATE OR REPLACE FUNCTION cwa._check_overlaps()
RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  v_person uuid;
  v_ride uuid;
  v_has_overlap boolean;
BEGIN
  IF TG_TABLE_NAME = 'ride_assignments' THEN
    v_person := COALESCE(NEW.person_id, OLD.person_id);

    WITH my_ranges AS (
      SELECT r.ride_id, tstzrange(r.start_at, r.end_at, '[)') AS rrange
      FROM cwa.ride_events r
      JOIN cwa.ride_assignments ra ON ra.ride_id = r.ride_id
      WHERE ra.person_id = v_person
    )
    SELECT EXISTS (
      SELECT 1
      FROM my_ranges a
      JOIN my_ranges b ON a.ride_id <> b.ride_id
      WHERE a.rrange && b.rrange
    ) INTO v_has_overlap;

  ELSE
    v_ride := COALESCE(NEW.ride_id, OLD.ride_id);

    WITH persons AS (
      SELECT person_id FROM cwa.ride_assignments WHERE ride_id = v_ride
    ),
    my_ranges AS (
      SELECT ra.person_id, r.ride_id, tstzrange(r.start_at, r.end_at, '[)') AS rrange
      FROM cwa.ride_events r
      JOIN cwa.ride_assignments ra ON ra.ride_id = r.ride_id
      WHERE ra.person_id IN (SELECT person_id FROM persons)
    )
    SELECT EXISTS (
      SELECT 1
      FROM my_ranges a
      JOIN my_ranges b
        ON a.person_id = b.person_id
       AND a.ride_id <> b.ride_id
       AND a.rrange && b.rrange
    ) INTO v_has_overlap;
  END IF;

  IF v_has_overlap THEN
    RAISE EXCEPTION 'ERR_OVERLAP: person has overlapping ride assignments';
  END IF;

  RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS trg_overlap_insupd ON cwa.ride_assignments;
CREATE CONSTRAINT TRIGGER trg_overlap_insupd
AFTER INSERT OR UPDATE OR DELETE ON cwa.ride_assignments
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION cwa._check_overlaps();

DROP TRIGGER IF EXISTS trg_overlap_ride_time ON cwa.ride_events;
CREATE CONSTRAINT TRIGGER trg_overlap_ride_time
AFTER UPDATE OF start_at, end_at ON cwa.ride_events
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION cwa._check_overlaps();

-- === Phase 3: Self-service RPCs ===
CREATE OR REPLACE FUNCTION cwa.self_set_unavailability(p_ranges jsonb)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_auth uuid := cwa.current_auth_uid();
  v_person uuid;
  v_range jsonb;
  v_start timestamptz;
  v_end   timestamptz;
BEGIN
  SELECT person_id INTO v_person FROM cwa.app_user_people WHERE auth_user_id = v_auth;
  IF v_person IS NULL THEN
    RETURN cwa._json_result(false, NULL, 'ERR_PRIVS', 'No person mapped to caller');
  END IF;

  -- replace strategy: clear then insert
  DELETE FROM cwa.people_unavailability WHERE person_id = v_person;

  FOR v_range IN SELECT * FROM jsonb_array_elements(p_ranges)
  LOOP
    v_start := (v_range->>'start_at')::timestamptz;
    v_end   := (v_range->>'end_at')::timestamptz;
    IF v_start IS NULL OR v_end IS NULL OR v_start >= v_end THEN
      RETURN cwa._json_result(false, NULL, 'ERR_INPUT', 'Invalid range in payload');
    END IF;
    INSERT INTO cwa.people_unavailability(person_id, start_at, end_at) VALUES (v_person, v_start, v_end);
  END LOOP;

  RETURN cwa._json_result(true, jsonb_build_object('person_id', v_person));
END;
$$;

CREATE OR REPLACE FUNCTION cwa.self_update_contact(p_contact jsonb)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_auth uuid := cwa.current_auth_uid();
  v_person uuid;
  v_email text := p_contact->>'email';
  v_phone text := p_contact->>'phone';
BEGIN
  SELECT person_id INTO v_person FROM cwa.app_user_people WHERE auth_user_id = v_auth;
  IF v_person IS NULL THEN
    RETURN cwa._json_result(false, NULL, 'ERR_PRIVS', 'No person mapped to caller');
  END IF;

  UPDATE cwa.people
     SET email = COALESCE(v_email, email),
         phone = COALESCE(v_phone, phone),
         updated_at = now()
   WHERE person_id = v_person;

  RETURN cwa._json_result(true, jsonb_build_object('person_id', v_person));
END;
$$;

COMMIT;
