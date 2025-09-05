
-- tests/v1.5-tests.sql
-- Purpose: Single-file suite for v1.5 (Step 3 + 4 + People hardening & write flow)

set search_path = public;

create or replace function _test_exec(p_sql text)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  execute p_sql;
  return ok();
exception when others then
  return err('ERR_DB', sqlerrm);
end;
$$;

with now_parts as (
  select extract(year from now())::int as y,
         extract(month from now())::int as m,
         extract(day from now())::int as d
),
samples as (
  select
    make_timestamptz(y, m, d + 1, 10, 0, 0, 'America/Los_Angeles') as t_pass,
    make_timestamptz(y, m, d,     3, 0, 0, 'America/Los_Angeles') as t_fail
  from now_parts
),
tests as (
  select *
  from (
    values
      -- Rides (carried forward)
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

      -- Step 4 hardening (carried)
      ('db_cancel_reason_fail',
        _test_exec($sql$
          update rides set status='cancelled', cancellation_reason=null
          where id='a0000002-0000-0000-0000-000000000002'
        $sql$)),
      ('db_cancel_reason_pass',
        _test_exec($sql$
          do $$
          declare v_old ride_status; v_reason text;
          begin
            select status, cancellation_reason into v_old, v_reason from rides where id='a0000002-0000-0000-0000-000000000002';
            update rides set status='cancelled', cancellation_reason='Test reason' where id='a0000002-0000-0000-0000-000000000002';
            update rides set status=v_old, cancellation_reason=v_reason where id='a0000002-0000-0000-0000-000000000002';
          end$$;
        $sql$)),
      ('db_max_two_passengers_fail',
        _test_exec($sql$
          do $$
          begin
            insert into ride_assignments(ride_id, person_id, role) values ('a0000005-0000-0000-0000-000000000005','44444444-4444-4444-4444-444444444444','passenger');
            insert into ride_assignments(ride_id, person_id, role) values ('a0000005-0000-0000-0000-000000000005','55555555-5555-5555-5555-555555555555','passenger');
          end$$;
        $sql$)),

      -- People v1.5
      ('people_blank_name_fail',
        upsert_person(null, '', 'Valid', 'new1@example.org', '206-555-7777', 'passenger', null)),
      ('people_missing_contact_fail',
        upsert_person(null, 'Valid', 'Person', null, null, 'passenger', null)),
      ('people_invalid_role_fail',
        upsert_person(null, 'Valid', 'Person', 'new2@example.org', '2065558888', 'driver', null)),
      ('people_normalize_pass',
        upsert_person(null, 'Case', 'Test', 'MixedCase@Example.ORG', '(206) 555-9090', 'passenger', null)),
      ('people_duplicate_email_fail',
        upsert_person(null, 'Dupe', 'Email', 'mixedcase@example.org', '2065550000', 'passenger', null)),
      ('people_duplicate_phone_fail',
        upsert_person(null, 'Dupe', 'Phone', 'other@example.org', '206-555-9090', 'passenger', null))
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
    ('time_window_pass',            true,  null),
    ('time_window_fail',            false, 'ERR_TIME_WINDOW'),
    ('status_transition_fail',      false, 'ERR_STATUS_TRANSITION'),
    ('assign_second_pilot_fail',    false, 'ERR_DUPLICATE_ROLE'),
    ('assign_third_passenger_fail', false, 'ERR_DUPLICATE_ROLE'),
    ('overlap_fail',                false, 'ERR_OVERLAP'),
    ('contact_fail',                false, 'ERR_INVALID_INPUT'),
    ('contact_pass',                true,  null),
    ('db_cancel_reason_fail',       false, 'ERR_DB'),
    ('db_cancel_reason_pass',       true,  null),
    ('db_max_two_passengers_fail',  false, 'ERR_DB'),
    ('people_blank_name_fail',      false, 'ERR_INVALID_INPUT'),
    ('people_missing_contact_fail', false, 'ERR_INVALID_INPUT'),
    ('people_invalid_role_fail',    false, 'ERR_INVALID_INPUT'),
    ('people_normalize_pass',       true,  null),
    ('people_duplicate_email_fail', false, 'ERR_DUPLICATE'),
    ('people_duplicate_phone_fail', false, 'ERR_DUPLICATE')
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

drop function if exists _test_exec(text);
