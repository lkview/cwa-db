-- tests/v1.4-step3-tests-v2.sql
-- Purpose: Return ALL test results in ONE result set so Supabase shows everything.
-- Produces two columns: test (text), result (jsonb).

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
)
select *
from (
  values
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
      assign_person('a0000003-0000-0000-0000-000000000003',
                    '33333333-3333-3333-3333-333333333333','passenger')),
    ('contact_fail',
      link_emergency_contact('a0000002-0000-0000-0000-000000000002',
                             '44444444-4444-4444-4444-444444444444',
                             '66666666-6666-6666-6666-666666666666')),
    ('contact_pass',
      link_emergency_contact('a0000002-0000-0000-0000-000000000002',
                             '33333333-3333-3333-3333-333333333333',
                             '66666666-6666-6666-6666-666666666666'))
) as t(test, result);
