
-- tests/v1.4-tests.sql
-- Purpose: Single-file test suite for v1.4 (Steps 3 + 4 hardening)
-- Usage:
--   \i sql/v1.4-run-all-fixed.sql   -- installs schema and seeds
--   \i tests/v1.4-tests.sql         -- runs all tests, single result set

set search_path = public;

-- Helper: execute a block of SQL and surface as JSON (uses existing ok/err helpers)
create or replace function _test_exec(p_sql text)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  execute p_sql;
  return ok();
exception when others then
  return err('ERR_DB', sqlerrm);
end;
$$;

-- Helper: update a ride to cancelled with a non-empty reason, then revert (no lasting changes)
create or replace function _test_cancel_with_reason_then_revert(p_ride uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_old_status ride_status;
  v_old_reason text;
begin
  select status, cancellation_reason into v_old_status, v_old_reason from rides where id = p_ride;
  if v_old_status is null then
    return err('ERR_NOT_FOUND','Ride not found');
  end if;

  begin
    update rides set status='cancelled', cancellation_reason='Test reason' where id = p_ride;
    update rides set status=v_old_status, cancellation_reason=v_old_reason where id = p_ride;
    return ok();
  exception when others then
    return err('ERR_DB', sqlerrm);
  end;
end;
$$;

-- Helper: attempt to exceed 2 passengers via direct INSERTs; roll back inside subtransaction
create or replace function _test_three_passengers_direct(p_ride uuid, p_pass2 uuid, p_pass3 uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  begin
    -- Add 2nd passenger (should succeed)
    insert into ride_assignments(ride_id, person_id, role) values (p_ride, p_pass2, 'passenger');
    -- Add 3rd passenger (should fail due to DB-level constraint trigger)
    insert into ride_assignments(ride_id, person_id, role) values (p_ride, p_pass3, 'passenger');
    return ok(); -- If we got here, constraint failed to fire (this would be a bug)
  exception when others then
    -- Error expected; subtransaction rolls back both inserts
    return err('ERR_DB', sqlerrm);
  end;
end;
$$;

with now_parts as (
  select extract(year from now())::int as y,
         extract(month from now())::int as m,
         extract(day from now())::int as d
),
samples as (
  select
    make_timestamptz(y, m, d + 1, 10, 0, 0, 'America/Los_Angeles') as t_pass, -- 10am PT tomorrow
    make_timestamptz(y, m, d,     3, 0, 0, 'America/Los_Angeles') as t_fail  -- 3am PT today
  from now_parts
),
tests as (
  select *
  from (
    values
      -- ===== Step 3 existing cases (copied for single-file suite) =====
      ('time_window_pass',
        create_ride((select t_pass from samples), 60,
                    'aaaaaaa1-0000-0000-0000-000000000001',
                    'aaaaaaa2-0000-0000-0000-000000000002',
                    'tentative', null, false)),
      ('time_window_fail',
        create_ride((select t_fail from samples), 60,
                    'aaaaaaa1-0000-0000-0000-000000000001',
                    'aaaaaaa2-0000-0000-0000-000000000002',
                    'tentative', null, false)),
      ('status_transition_fail',
        update_ride('a0000005-0000-0000-0000-000000000005',
                    now(), 60,
                    'aaaaaaa1-0000-0000-0000-000000000001',
                    'aaaaaaa2-0000-0000-0000-000000000002',
                    'scheduled', null, false)),
      ('assign_second_pilot_fail',
        assign_person('a0000002-0000-0000-0000-000000000002',
                      '22222222-2222-2222-2222-222222222222','pilot')),
      ('assign_third_passenger_fail',
        assign_person('a0000003-0000-0000-0000-000000000003',
                      '33333333-3333-3333-3333-333333333333','passenger')),
      ('overlap_fail',
        assign_person('a0000006-0000-0000-0000-000000000006',
                      '33333333-3333-3333-3333-333333333333','passenger')),
      ('contact_fail',
        link_emergency_contact('a0000002-0000-0000-0000-000000000002',
                               '44444444-4444-4444-4444-444444444444',
                               '66666666-6666-6666-6666-666666666666')),
      ('contact_pass',
        link_emergency_contact('a0000002-0000-0000-0000-000000000002',
                               '33333333-3333-3333-3333-333333333333',
                               '66666666-6666-6666-6666-666666666666')),

      -- ===== Step 4 hardening cases =====
      -- Cancellation requires reason (raw UPDATE should fail)
      ('db_cancel_reason_fail',
        _test_exec($sql$
          update rides set status='cancelled', cancellation_reason=null
          where id='a0000002-0000-0000-0000-000000000002'
        $sql$)),
      -- Cancellation with reason then revert (raw UPDATE should succeed)
      ('db_cancel_reason_pass',
        _test_cancel_with_reason_then_revert('a0000002-0000-0000-0000-000000000002')),

      -- Enforce <= 2 passengers at DB level (bypass RPC)
      ('db_max_two_passengers_fail',
        _test_three_passengers_direct('a0000005-0000-0000-0000-000000000005',
                                      '44444444-4444-4444-4444-444444444444',
                                      '55555555-5555-5555-5555-555555555555'))
  ) as t(test, result)
),
actual as (
  select
    test,
    coalesce((result->>'ok')::boolean, false) as ok_actual,
    result #>> '{error,code}' as err_code_actual
  from tests
),
expected as (
  select * from (values
    -- Step 3
    ('time_window_pass',            true,  null),
    ('time_window_fail',            false, 'ERR_TIME_WINDOW'),
    ('status_transition_fail',      false, 'ERR_STATUS_TRANSITION'),
    ('assign_second_pilot_fail',    false, 'ERR_DUPLICATE_ROLE'),
    ('assign_third_passenger_fail', false, 'ERR_DUPLICATE_ROLE'),
    ('overlap_fail',                false, 'ERR_OVERLAP'),
    ('contact_fail',                false, 'ERR_INVALID_INPUT'),
    ('contact_pass',                true,  null),
    -- Step 4
    ('db_cancel_reason_fail',       false, 'ERR_DB'),
    ('db_cancel_reason_pass',       true,  null),
    ('db_max_two_passengers_fail',  false, 'ERR_DB')
  ) as x(test, ok_expected, err_code_expected)
)
select
  a.test,
  a.ok_actual,
  a.err_code_actual,
  e.ok_expected,
  e.err_code_expected,
  (a.ok_actual = e.ok_expected and coalesce(a.err_code_actual,'') = coalesce(e.err_code_expected,'')) as pass
from actual a
join expected e using (test)
order by a.test;

-- Cleanup helpers
drop function if exists _test_exec(text);
drop function if exists _test_cancel_with_reason_then_revert(uuid);
drop function if exists _test_three_passengers_direct(uuid, uuid, uuid);
