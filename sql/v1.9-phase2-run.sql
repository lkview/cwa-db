-- CWA Ride Scheduler — v1.9 Phase 2 RUN (corrected)
-- Assumes Phase 1 run has created schema cwa and base objects.
-- Adds helpers, RPCs, and deferrable constraint triggers.

BEGIN;
SET search_path = cwa, public;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='cwa' AND table_name='ride_events') THEN
    RAISE EXCEPTION 'Phase 1 objects not found. Run v1.9-phase1-run.sql first.';
  END IF;
END$$;

-- 1) JSON result helper
CREATE OR REPLACE FUNCTION cwa._json_result(
  p_ok boolean,
  p_data jsonb DEFAULT NULL,
  p_err_code text DEFAULT NULL,
  p_message text DEFAULT NULL,
  p_warnings jsonb DEFAULT NULL
) RETURNS jsonb
LANGUAGE sql IMMUTABLE AS $$
  SELECT jsonb_strip_nulls(
    jsonb_build_object(
      'ok', p_ok,
      'data', p_data,
      'err_code', p_err_code,
      'message', p_message,
      'warnings', p_warnings
    )
  );
$$;

-- 2) Settings & operating-hours helpers
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
  s time;
  e time;
  d1 date;
  d2 date;
BEGIN
  SELECT day_start, day_end INTO s, e FROM cwa.operating_hours();
  d1 := (p_start AT TIME ZONE 'America/Los_Angeles')::date;
  d2 := (p_end   AT TIME ZONE 'America/Los_Angeles')::date;
  IF d1 <> d2 THEN RETURN FALSE; END IF;
  IF cwa._to_local_time(p_start) < s OR cwa._to_local_time(p_end) > e THEN
    RETURN FALSE;
  END IF;
  RETURN TRUE;
END;
$$;

-- 3) Utility: role/status gates & warnings
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

-- 4) RPC: save_ride
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

  IF v_start IS NULL OR v_end IS NULL OR v_start >= v_end THEN
    RETURN cwa._json_result(false, NULL, 'ERR_INPUT', 'start_at/end_at invalid');
  END IF;

  IF NOT cwa.is_within_operating_hours(v_start, v_end) THEN
    RETURN cwa._json_result(false, NULL, 'ERR_HOURS', 'Ride outside operating hours');
  END IF;

  SELECT * INTO v_existing FROM cwa.ride_events WHERE ride_id = v_id;

  IF v_existing.ride_id IS NULL THEN
    INSERT INTO cwa.ride_events(ride_id, start_at, end_at, status, cancel_reason, notes)
    VALUES (v_id, v_start, v_end, v_status, v_cancel_reason, p_ride->>'notes');
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
          updated_at = now()
      WHERE ride_id = v_id;
    END IF;
  END IF;

  RETURN cwa._json_result(true, jsonb_build_object('ride_id', v_id));
END;
$$;

-- 5) RPC: assign_person / unassign_person
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

-- 6) RPC: Emergency contact linkage
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

-- 7) Deferrable constraint triggers
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
  -- When fired on ride_assignments, check overlaps for the affected person
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
    -- When fired on ride_events (time change), re-check all persons on that ride
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

COMMIT;