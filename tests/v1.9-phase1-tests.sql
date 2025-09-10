-- CWA Ride Scheduler — v1.9 Phase 1 TESTS (unified)
-- Run this file after v1.9-phase1-run.sql
-- It returns one table with rows: test | ok | data | err_code

-- Helper: emit a row as table
CREATE OR REPLACE FUNCTION cwa._t_row(name text, ok boolean, data jsonb DEFAULT NULL, err_code text DEFAULT NULL)
RETURNS TABLE (test text, ok boolean, data jsonb, err_code text)
LANGUAGE sql AS $$
  SELECT name, ok, data, err_code;
$$;

-- Unified runner
CREATE OR REPLACE FUNCTION cwa._all_tests()
RETURNS TABLE (test text, ok boolean, data jsonb, err_code text)
LANGUAGE plpgsql AS $$
DECLARE
  r_id uuid;
  pilot_id uuid;
BEGIN
  -- 1) Basic existence tests
  RETURN QUERY
  SELECT * FROM cwa._t_row('tables_exist',
    (SELECT count(*) FROM information_schema.tables WHERE table_schema='cwa'
      AND table_name IN ('people','person_roles','people_unavailability','ride_events','ride_assignments','ride_passenger_contacts','roles','statuses','role_allowed_statuses','cert_types','person_certifications','app_user_roles','app_user_people')
    ) = 13,
    jsonb_build_object('table_count',
      (SELECT count(*) FROM information_schema.tables WHERE table_schema='cwa')
    )
  );

  RETURN QUERY
  SELECT * FROM cwa._t_row('views_exist',
    (SELECT count(*) FROM information_schema.views WHERE table_schema='cwa'
      AND table_name IN ('v_pilot_roster','v_passenger_roster','v_ride_list','v_ride_detail')
    ) = 4
  );

  -- 2) Masking behavior — non-admin
  PERFORM set_config('request.jwt.claims','{"sub":"00000000-0000-0000-0000-000000000099"}', true);

  RETURN QUERY
  WITH pilot AS (
    SELECT full_name, email, phone FROM cwa.v_pilot_roster ORDER BY full_name LIMIT 1
  ), pax AS (
    SELECT full_name, email, phone FROM cwa.v_passenger_roster ORDER BY full_name LIMIT 1
  )
  SELECT * FROM cwa._t_row('masking_non_admin',
    (SELECT pilot.full_name !~ '\s\S+$' OR pilot.full_name ~ '…' FROM pilot)
    AND (SELECT pax.full_name !~ '\s\S+$' OR pax.full_name ~ '…' FROM pax)
  );

  -- 3) Unmasked for admin
  PERFORM set_config('request.jwt.claims','{"sub":"00000000-0000-0000-0000-000000000001"}', true);

  RETURN QUERY
  WITH pilot AS (
    SELECT full_name, email, phone FROM cwa.v_pilot_roster ORDER BY full_name LIMIT 1
  ), pax AS (
    SELECT full_name, email, phone FROM cwa.v_passenger_roster ORDER BY full_name LIMIT 1
  )
  SELECT * FROM cwa._t_row('masking_admin_unmasked',
    (SELECT pilot.full_name ~ '\s\S+$' FROM pilot)
    AND (SELECT pax.full_name ~ '\s\S+$' FROM pax)
  );

  -- 4) Roster flags
  RETURN QUERY
  SELECT * FROM cwa._t_row('pilot_roster_flags',
    EXISTS (SELECT 1 FROM cwa.v_pilot_roster WHERE status_key='active' AND assignable = true)
    AND EXISTS (SELECT 1 FROM cwa.v_pilot_roster WHERE status_key='in_training' AND assignable = false AND show_on_roster = true)
  );

  RETURN QUERY
  SELECT * FROM cwa._t_row('passenger_roster_flags',
    EXISTS (SELECT 1 FROM cwa.v_passenger_roster WHERE status_key='interested' AND assignable = true)
    AND NOT EXISTS (SELECT 1 FROM cwa.v_passenger_roster WHERE status_key IN ('not_interested','deceased') AND show_on_roster = true)
  );

  -- 5) Ride list & detail shape
  SELECT p2.person_id INTO pilot_id
  FROM cwa.people p2
  JOIN cwa.person_roles pr ON pr.person_id=p2.person_id AND pr.role_key='pilot'
  LIMIT 1;

  INSERT INTO cwa.ride_events(start_at, end_at, status, notes)
    VALUES (now() + interval '1 day', now() + interval '1 day' + interval '2 hours', 'tentative', 'phase1 test')
    RETURNING ride_id INTO r_id;

  INSERT INTO cwa.ride_assignments(ride_id, person_id, role_key)
  VALUES (r_id, pilot_id, 'pilot');

  RETURN QUERY
  SELECT * FROM cwa._t_row('ride_list_projects',
    EXISTS (SELECT 1 FROM cwa.v_ride_list WHERE ride_id = r_id)
  );

  RETURN QUERY
  SELECT * FROM cwa._t_row('ride_detail_projects',
    EXISTS (SELECT 1 FROM cwa.v_ride_detail WHERE ride_id = r_id)
  );

  -- 6) has_contact_method correctness
  RETURN QUERY
  SELECT * FROM cwa._t_row('has_contact_method_flag',
    NOT EXISTS (SELECT 1 FROM cwa.v_pilot_roster WHERE (email IS NULL AND phone IS NULL) AND has_contact_method = true)
  );

END;
$$;

-- Execute
SELECT * FROM cwa._all_tests();