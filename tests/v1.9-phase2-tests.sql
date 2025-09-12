-- CWA Ride Scheduler — v1.9 Phase 2 TESTS (latest v2: fixes ERR_PRIVS by ensuring admin mapping)
-- Emits rows: test | ok | data | err_code
-- Uses **tomorrow** (America/Los_Angeles) for windows to avoid immutability.

SET search_path = cwa, public;

-- Row helper
CREATE OR REPLACE FUNCTION cwa._t_row(name text, ok boolean, data jsonb DEFAULT NULL, err_code text DEFAULT NULL)
RETURNS TABLE (test text, ok boolean, data jsonb, err_code text)
LANGUAGE sql AS $$
  SELECT name, ok, data, err_code;
$$;

-- Helper: force evaluation of deferred constraints
CREATE OR REPLACE FUNCTION cwa.set_constraints_all_immediate()
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE 'SET CONSTRAINTS ALL IMMEDIATE';
END
$$;

-- Main test harness
CREATE OR REPLACE FUNCTION cwa._p2_tests()
RETURNS TABLE (test text, ok boolean, data jsonb, err_code text)
LANGUAGE plpgsql AS $$
DECLARE
  r jsonb;
  r2 jsonb;
  r3 jsonb;
  rid uuid;
  rid2 uuid;
  pilot uuid;
  pax1 uuid;
  pax2 uuid;
  pax3 uuid;
  ec1 uuid;
  ec2 uuid;
  p2 uuid;
  new_person uuid;
  d_local date;
  start_ok timestamptz;
  end_ok   timestamptz;
  start_bad timestamptz;
  end_bad   timestamptz;
  start_overlap timestamptz;
  end_overlap   timestamptz;
  start_future timestamptz;
  end_future   timestamptz;
  v_admin uuid := '00000000-0000-0000-0000-000000000001'::uuid;
  v_admin_person uuid;
BEGIN
  -- Ensure the admin auth is mapped to a real person (Alice) so is_admin_or_scheduler() returns TRUE
  SELECT person_id INTO v_admin_person FROM cwa.people WHERE first_name='Alice' ORDER BY person_id LIMIT 1;
  IF v_admin_person IS NOT NULL THEN
    INSERT INTO cwa.app_user_people(person_id, auth_user_id)
    VALUES (v_admin_person, v_admin)
    ON CONFLICT DO NOTHING;
  END IF;

  -- Impersonate admin for writes (local to this function txn is fine)
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin)::text, true);

  -- Compute tomorrow's local date in America/Los_Angeles, then build windows
  d_local := (now() AT TIME ZONE 'America/Los_Angeles')::date + 1;
  start_ok := ( (d_local + time '10:00') AT TIME ZONE 'America/Los_Angeles');
  end_ok   := ( (d_local + time '12:00') AT TIME ZONE 'America/Los_Angeles');
  start_bad := ( (d_local + time '06:00') AT TIME ZONE 'America/Los_Angeles');
  end_bad   := ( (d_local + time '07:00') AT TIME ZONE 'America/Los_Angeles');
  start_overlap := ( (d_local + time '11:00') AT TIME ZONE 'America/Los_Angeles');
  end_overlap   := ( (d_local + time '13:00') AT TIME ZONE 'America/Los_Angeles');
  start_future := ( (d_local + 2 + time '10:00') AT TIME ZONE 'America/Los_Angeles');
  end_future   := ( (d_local + 2 + time '12:00') AT TIME ZONE 'America/Los_Angeles');

  -- Bootstrap: fetch ids from seeds
  SELECT p.person_id INTO pilot
  FROM cwa.people p
  JOIN cwa.person_roles pr ON pr.person_id=p.person_id AND pr.role_key='pilot'
  WHERE p.status_key='active'
  LIMIT 1;

  SELECT p.person_id INTO pax1
  FROM cwa.people p
  JOIN cwa.person_roles pr ON pr.person_id=p.person_id AND pr.role_key='passenger'
  WHERE p.status_key='interested'
  LIMIT 1;

  -- Create two more passengers & two EC people
  INSERT INTO cwa.people(first_name,last_name,email,phone,status_key)
  VALUES ('Bob','Pax','bob@example.com','+1 206 555 6001','interested')
  RETURNING person_id INTO pax2;
  INSERT INTO cwa.person_roles(person_id, role_key) VALUES (pax2,'passenger') ON CONFLICT DO NOTHING;

  INSERT INTO cwa.people(first_name,last_name,email,phone,status_key)
  VALUES ('Cat','Pax','cat@example.com','+1 206 555 6002','interested')
  RETURNING person_id INTO pax3;
  INSERT INTO cwa.person_roles(person_id, role_key) VALUES (pax3,'passenger') ON CONFLICT DO NOTHING;

  INSERT INTO cwa.people(first_name,last_name,email,phone,status_key)
  VALUES ('Eve','Contact','eve@example.com','+1 206 555 7001','interested')
  RETURNING person_id INTO ec1;

  INSERT INTO cwa.people(first_name,last_name,email,phone,status_key)
  VALUES ('Ivy','InactiveEC','ivy@example.com','+1 206 555 7002','inactive')
  RETURNING person_id INTO ec2;

  -- 1) ride_ok_create (within hours)
  r := cwa.save_ride(jsonb_build_object(
    'start_at', start_ok,
    'end_at',   end_ok,
    'status', 'tentative',
    'notes', 'p2 test ride'
  ));
  rid := (r->'data'->>'ride_id')::uuid;
  RETURN QUERY SELECT * FROM cwa._t_row('ride_ok_create', (r->>'ok')::boolean, r->'data', r->>'err_code');

  -- 2) ride_bad_hours (outside window) — expect ERR_HOURS
  r2 := cwa.save_ride(jsonb_build_object(
    'start_at', start_bad,
    'end_at',   end_bad,
    'status', 'tentative'
  ));
  RETURN QUERY SELECT * FROM cwa._t_row('ride_bad_hours', (r2->>'ok')::boolean = false AND r2->>'err_code'='ERR_HOURS', NULL, r2->>'err_code');

  -- 3) cancel_without_reason — expect ERR_CANCEL_REASON
  r2 := cwa.save_ride(jsonb_build_object('ride_id', rid, 'start_at',start_ok, 'end_at',end_ok, 'status','cancelled'));
  RETURN QUERY SELECT * FROM cwa._t_row('cancel_without_reason', (r2->>'ok')::boolean = false AND r2->>'err_code'='ERR_CANCEL_REASON', NULL, r2->>'err_code');

  -- 4) state_transition_illegal — expect ERR_STATE
  PERFORM cwa.save_ride(jsonb_build_object('ride_id', rid, 'start_at',start_ok, 'end_at',end_ok, 'status','scheduled'));
  r2 := cwa.save_ride(jsonb_build_object('ride_id', rid, 'start_at',start_ok, 'end_at',end_ok, 'status','tentative'));
  RETURN QUERY SELECT * FROM cwa._t_row('state_transition_illegal', (r2->>'ok')::boolean = false AND r2->>'err_code'='ERR_STATE', NULL, r2->>'err_code');

  -- 5) assign_interested_passenger_ok
  r2 := cwa.assign_person(rid, pax1, 'passenger');
  RETURN QUERY SELECT * FROM cwa._t_row('assign_interested_passenger_ok', (r2->>'ok')::boolean, r2->'data', r2->>'err_code');

  -- 6) assign_pilot_ok (warnings allowed)
  r2 := cwa.assign_person(rid, pilot, 'pilot');
  RETURN QUERY SELECT * FROM cwa._t_row('assign_pilot_ok', (r2->>'ok')::boolean, r2->'warnings', r2->>'err_code');

  -- 7) second_pilot_db_error — expect composition error; then cleanup
  PERFORM cwa.assign_person(rid, pilot, 'pilot'); -- duplicate won't add (unique)
  INSERT INTO cwa.people(first_name,last_name,status_key,email)
  VALUES ('Zed','Pilot','active','zed.pilot@example.com')
  RETURNING person_id INTO p2;
  INSERT INTO cwa.person_roles(person_id, role_key) VALUES (p2,'pilot');
  PERFORM cwa.assign_person(rid, p2, 'pilot');
  BEGIN
    PERFORM cwa.set_constraints_all_immediate();
    -- if no error, mark as failure
    RETURN QUERY SELECT * FROM cwa._t_row('second_pilot_db_error', false, NULL, NULL);
  EXCEPTION WHEN OTHERS THEN
    RETURN QUERY SELECT * FROM cwa._t_row('second_pilot_db_error', true, NULL, 'ERR_COMPOSITION');
  END;
  DELETE FROM cwa.ride_assignments WHERE ride_id = rid AND role_key='pilot' AND person_id = p2;

  -- 8) third_passenger_db_error — expect composition error; then cleanup
  PERFORM cwa.assign_person(rid, pax2, 'passenger');
  PERFORM cwa.assign_person(rid, pax3, 'passenger');
  BEGIN
    PERFORM cwa.set_constraints_all_immediate();
    RETURN QUERY SELECT * FROM cwa._t_row('third_passenger_db_error', false, NULL, NULL);
  EXCEPTION WHEN OTHERS THEN
    RETURN QUERY SELECT * FROM cwa._t_row('third_passenger_db_error', true, NULL, 'ERR_COMPOSITION');
  END;
  DELETE FROM cwa.ride_assignments WHERE ride_id = rid AND role_key='passenger' AND person_id IN (pax2, pax3);

  -- 9) overlap_db_error — expect overlap error; then cleanup
  r2 := cwa.save_ride(jsonb_build_object(
    'start_at', start_overlap,
    'end_at',   end_overlap,
    'status', 'tentative'
  ));
  rid2 := (r2->'data'->>'ride_id')::uuid;
  PERFORM cwa.assign_person(rid2, pilot, 'pilot');
  BEGIN
    PERFORM cwa.set_constraints_all_immediate();
    RETURN QUERY SELECT * FROM cwa._t_row('overlap_db_error', false, NULL, NULL);
  EXCEPTION WHEN OTHERS THEN
    RETURN QUERY SELECT * FROM cwa._t_row('overlap_db_error', true, NULL, 'ERR_OVERLAP');
  END;
  DELETE FROM cwa.ride_assignments WHERE ride_id = rid2 AND person_id = pilot;
  DELETE FROM cwa.ride_events WHERE ride_id = rid2;

  -- 10) ec_before_passenger_blocked — passenger not yet assigned → ERR_EC_LINK
  r2 := cwa.save_ride(jsonb_build_object(
    'start_at', start_future,
    'end_at',   end_future,
    'status', 'tentative'
  ));
  rid2 := (r2->'data'->>'ride_id')::uuid;
  r2 := cwa.link_emergency_contact(rid2, pax2, ec1);
  RETURN QUERY SELECT * FROM cwa._t_row('ec_before_passenger_blocked', (r2->>'ok')::boolean = false AND r2->>'err_code'='ERR_EC_LINK', NULL, r2->>'err_code');

  -- 11) ec_wrong_status_or_role_blocked — EC has disallowed status → ERR_STATUS
  PERFORM cwa.assign_person(rid2, pax2, 'passenger'); -- now passenger is assigned
  r2 := cwa.link_emergency_contact(rid2, pax2, ec2);
  RETURN QUERY SELECT * FROM cwa._t_row('ec_wrong_status_or_role_blocked', (r2->>'ok')::boolean = false AND r2->>'err_code'='ERR_STATUS', NULL, r2->>'err_code');

  -- 12) ec_link_ok — activate ec1 first, then link
  PERFORM (cwa.set_person_status(ec1, 'active'::text));
  r2 := cwa.link_emergency_contact(rid2, pax2, ec1);
  RETURN QUERY SELECT * FROM cwa._t_row('ec_link_ok', (r2->>'ok')::boolean, r2->'data', r2->>'err_code');

  -- 13) ride_cancel_with_reason_ok
  r2 := cwa.save_ride(jsonb_build_object('ride_id', rid2, 'start_at',start_future, 'end_at',end_future, 'status','cancelled', 'cancel_reason','weather'));
  RETURN QUERY SELECT * FROM cwa._t_row('ride_cancel_with_reason_ok', (r2->>'ok')::boolean, r2->'data', r2->>'err_code');

  -- 14) People RPCs — upsert_person (create)
  r3 := cwa.upsert_person(jsonb_build_object(
    'first_name','Test','last_name','Person','email','test.person@example.com','phone','+1 206 555 8001','status_key','interested'
  ));
  new_person := (r3->'data'->>'person_id')::uuid;
  RETURN QUERY SELECT * FROM cwa._t_row('upsert_person_create_ok', (r3->>'ok')::boolean, r3->'data', r3->>'err_code');

  -- 15) People RPCs — upsert_person (update)
  r3 := cwa.upsert_person(jsonb_build_object(
    'person_id', new_person, 'email','updated.person@example.com','phone','+1 206 555 8002'
  ));
  RETURN QUERY SELECT * FROM cwa._t_row('upsert_person_update_ok', (r3->>'ok')::boolean, r3->'data', r3->>'err_code');

  -- 16) set_person_status_ok
  r3 := cwa.set_person_status(new_person, 'active'::text);
  RETURN QUERY SELECT * FROM cwa._t_row('set_person_status_ok', (r3->>'ok')::boolean, r3->'data', r3->>'err_code');

  -- 17) set_person_status_bad_key — expect ERR_INPUT
  r3 := cwa.set_person_status(new_person, 'unknown_status_key'::text);
  RETURN QUERY SELECT * FROM cwa._t_row('set_person_status_bad_key', (r3->>'ok')::boolean = false AND r3->>'err_code'='ERR_INPUT', NULL, r3->>'err_code');

  -- 18) upsert_contact_methods_ok
  r3 := cwa.upsert_contact_methods(new_person, 'final.person@example.com', '+1 206 555 8003');
  RETURN QUERY SELECT * FROM cwa._t_row('upsert_contact_methods_ok', (r3->>'ok')::boolean, r3->'data', r3->>'err_code');

  -- 19) add_person_role_ok
  r3 := cwa.add_person_role(new_person, 'pilot');
  RETURN QUERY SELECT * FROM cwa._t_row('add_person_role_ok', (r3->>'ok')::boolean, r3->'data', r3->>'err_code');

  -- 20) remove_person_role_ok
  r3 := cwa.remove_person_role(new_person, 'pilot');
  RETURN QUERY SELECT * FROM cwa._t_row('remove_person_role_ok', (r3->>'ok')::boolean, r3->'data', r3->>'err_code');

  -- Final safety: surface any unexpected deferrable violation
  BEGIN
    PERFORM cwa.set_constraints_all_immediate();
  EXCEPTION WHEN OTHERS THEN
    RETURN QUERY SELECT * FROM cwa._t_row('final_constraints_check', false, NULL, 'DEFERRED_VIOLATION');
  END;

END;
$$;

-- Execute
SELECT * FROM cwa._p2_tests();
