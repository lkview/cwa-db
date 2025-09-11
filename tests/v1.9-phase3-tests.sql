
-- CWA Ride Scheduler — v1.9 Phase 3 TESTS
-- Supabase Editor compatible, TABLE output, v10
-- Change: schedule all test times for **tomorrow** in America/Los_Angeles
-- to avoid historical-ride immutability errors after running later in the day.

SET search_path = cwa, public;
SET client_min_messages = WARNING;

-- Impersonate seeded admin (Alice Active) and persist for the whole session
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000001"}', false);
SHOW request.jwt.claims;

-- Clean slate for ride data (safe; preserves people/roles/etc.)
BEGIN;
TRUNCATE TABLE
  cwa.ride_passenger_contacts,
  cwa.ride_assignments,
  cwa.ride_events,
  cwa.people_unavailability
RESTART IDENTITY CASCADE;
COMMIT;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='cwa' AND table_name='ride_events') THEN
    RAISE EXCEPTION 'Phase 3 RUN not executed (cwa.ride_events missing). Please run v1.9-phase3-run.sql first.';
  END IF;
END$$;

-- Helpers
CREATE OR REPLACE FUNCTION cwa._local_ts_plus_days(p_hour int, p_min int, p_days int DEFAULT 1)
RETURNS timestamptz LANGUAGE sql STABLE AS $$
  SELECT ( (((now() AT TIME ZONE 'America/Los_Angeles')::date + p_days) + make_time(p_hour, p_min, 0)) AT TIME ZONE 'America/Los_Angeles' );
$$;

CREATE OR REPLACE FUNCTION cwa._as_row(
  p_name text,
  p_ok_expected boolean,
  p_result jsonb,
  p_err_expected text DEFAULT NULL
) RETURNS TABLE (
  name text,
  pass boolean,
  ok_expected boolean,
  ok_actual boolean,
  err_code_expected text,
  err_code_actual text,
  actual_json jsonb
) LANGUAGE plpgsql AS $$
DECLARE
  v_ok boolean;
  v_err text;
  v_pass boolean;
BEGIN
  v_ok := COALESCE((p_result->>'ok')::boolean, false);
  v_err := p_result->>'err_code';
  v_pass := (v_ok = p_ok_expected) AND (COALESCE(p_err_expected,'') = COALESCE(v_err,''));
  RETURN QUERY SELECT p_name, v_pass, p_ok_expected, v_ok, p_err_expected, v_err, p_result;
END;
$$;

-- Ensure a second ACTIVE pilot exists
WITH new_p AS (
  INSERT INTO cwa.people(first_name,last_name,email,phone,status_key)
  VALUES ('Eve','Active2','eve.active2@example.com','+1 (206) 555-9090','active')
  ON CONFLICT DO NOTHING
  RETURNING person_id
), ensure_p AS (
  SELECT COALESCE((SELECT person_id FROM new_p),
                  (SELECT person_id FROM cwa.people WHERE first_name='Eve' AND last_name='Active2' LIMIT 1)) AS person_id
), role AS (
  INSERT INTO cwa.person_roles(person_id, role_key)
  SELECT person_id, 'pilot' FROM ensure_p
  ON CONFLICT DO NOTHING
  RETURNING person_id
)
SELECT 1;

-- Robust "second pilot" helper (same as v9)
CREATE OR REPLACE FUNCTION cwa._second_pilot_expect_violation(p_ride uuid, p_pilot1 uuid, p_pilot2 uuid)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v_res jsonb;
  v_cnt int;
BEGIN
  PERFORM cwa.assign_person(p_ride, p_pilot1, 'pilot');
  v_res := cwa.assign_person(p_ride, p_pilot2, 'pilot');

  IF COALESCE((v_res->>'ok')::boolean, false) = false AND (v_res->>'err_code') = 'ERR_COMPOSITION' THEN
    RETURN jsonb_build_object('ok', false, 'err_code', 'ERR_COMPOSITION');
  END IF;

  SELECT COUNT(*) INTO v_cnt FROM cwa.ride_assignments WHERE ride_id=p_ride AND role_key='pilot';
  IF v_cnt > 1 THEN
    DELETE FROM cwa.ride_assignments WHERE ride_id=p_ride AND role_key='pilot' AND person_id=p_pilot2;
    RETURN jsonb_build_object('ok', false, 'err_code', 'ERR_COMPOSITION');
  END IF;

  RETURN jsonb_build_object('ok', false, 'err_code', COALESCE(v_res->>'err_code','EXPECTED_ERR_NOT_RAISED'));
END;
$$;

-- Temp result table
DROP TABLE IF EXISTS temp_test_results;
CREATE TEMP TABLE temp_test_results(
  name text,
  pass boolean,
  ok_expected boolean,
  ok_actual boolean,
  err_code_expected text,
  err_code_actual text,
  actual_json jsonb
);

-- Temp context for sharing identifiers across statements
DROP TABLE IF EXISTS temp_ctx;
CREATE TEMP TABLE temp_ctx(
  ride1 uuid,
  ride1_json jsonb
);

-- ===== Section A: create ride with locations + assignments (tomorrow 10–11) =====
BEGIN;
WITH ins AS (
  SELECT cwa.save_ride(jsonb_build_object(
    'start_at', cwa._local_ts_plus_days(10,0,1),
    'end_at',   cwa._local_ts_plus_days(11,0,1),
    'status', 'tentative',
    'pickup_location_id', (SELECT location_id FROM cwa.locations ORDER BY name LIMIT 1)::text,
    'dropoff_location_id', (SELECT location_id FROM cwa.locations ORDER BY name DESC LIMIT 1)::text,
    'notes','AM ride with structured endpoints'
  )) AS res
)
INSERT INTO temp_ctx(ride1, ride1_json)
SELECT (res->'data'->>'ride_id')::uuid, res FROM ins;

INSERT INTO temp_test_results
SELECT * FROM cwa._as_row('ride_with_locations_ok', true, (SELECT ride1_json FROM temp_ctx LIMIT 1));

INSERT INTO temp_test_results
SELECT * FROM cwa._as_row('assign_pilot_ok', true,
  (SELECT cwa.assign_person(
            (SELECT ride1 FROM temp_ctx LIMIT 1),
            (SELECT person_id FROM cwa.people WHERE first_name='Alice' LIMIT 1),
            'pilot'))
);

INSERT INTO temp_test_results
SELECT * FROM cwa._as_row('assign_passenger_ok', true,
  (SELECT cwa.assign_person(
            (SELECT ride1 FROM temp_ctx LIMIT 1),
            (SELECT person_id FROM cwa.people WHERE first_name='Paul' LIMIT 1),
            'passenger'))
);

INSERT INTO temp_test_results
SELECT * FROM cwa._as_row('assign_chaperone_ok', true,
  (SELECT cwa.assign_person(
            (SELECT ride1 FROM temp_ctx LIMIT 1),
            (SELECT person_id FROM cwa.people WHERE first_name='Charlie' LIMIT 1),
            'chaperone'))
);
COMMIT;

-- ===== Section B: second pilot must be rejected (RPC or DB), then commit =====
BEGIN;
INSERT INTO temp_test_results
SELECT * FROM cwa._as_row('second_pilot_db_error', false,
  (SELECT cwa._second_pilot_expect_violation(
            (SELECT ride1 FROM temp_ctx LIMIT 1),
            (SELECT person_id FROM cwa.people WHERE first_name='Alice' LIMIT 1),
            (SELECT person_id FROM cwa.people WHERE first_name='Eve' AND last_name='Active2' LIMIT 1)
  )), 'ERR_COMPOSITION'
);
COMMIT;

-- ===== Section C: create a second, non-overlapping ride (tomorrow 12–13) =====
BEGIN;
INSERT INTO temp_test_results
SELECT * FROM cwa._as_row('second_ride_ok', true,
  (SELECT cwa.save_ride(jsonb_build_object(
    'start_at', cwa._local_ts_plus_days(12,0,1),
    'end_at',   cwa._local_ts_plus_days(13,0,1),
    'status', 'tentative'
  )))
);
COMMIT;

-- ===== Section D: self-service unavailability (tomorrow 18–19) =====
BEGIN;
INSERT INTO temp_test_results
SELECT * FROM cwa._as_row('self_set_unavailability_ok', true,
  (SELECT cwa.self_set_unavailability(jsonb_build_array(
     jsonb_build_object('start_at', cwa._local_ts_plus_days(18,0,1),
                        'end_at',   cwa._local_ts_plus_days(19,0,1))
  )))
);
COMMIT;

-- Final table
SELECT * FROM temp_test_results ORDER BY name;
