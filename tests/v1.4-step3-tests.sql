-- v1.4-step3-tests.sql
-- Purpose: Automated checks for RPCs + validations (Step 3).
-- These SELECTs return JSON envelopes: { ok, data, error }.
-- Run AFTER seeding + applying step 3 SQL.

-- --------------------------------------------------
-- 1) Time window validation
-- --------------------------------------------------
select 'time_window_pass' as test, create_ride(now() + interval '1 day', 60,
  'aaaaaaa1-0000-0000-0000-000000000001',
  'aaaaaaa2-0000-0000-0000-000000000002',
  'tentative', null, false);

select 'time_window_fail' as test, create_ride(date_trunc('day', now()) + interval '3 hours', 60,
  'aaaaaaa1-0000-0000-0000-000000000001',
  'aaaaaaa2-0000-0000-0000-000000000002',
  'tentative', null, false);

-- --------------------------------------------------
-- 2) Status transitions
-- --------------------------------------------------
-- Invalid: completed -> scheduled
select 'status_transition_fail' as test, update_ride('a0000005-0000-0000-0000-000000000005',
  now(), 60, 'aaaaaaa1-0000-0000-0000-000000000001','aaaaaaa2-0000-0000-0000-000000000002','scheduled',null,false);

-- --------------------------------------------------
-- 3) Assignment rules
-- --------------------------------------------------
-- Fail: assign a second pilot to ride a0000002 (already has Paula)
select 'assign_second_pilot_fail' as test, assign_person('a0000002-0000-0000-0000-000000000002',
  '22222222-2222-2222-2222-222222222222','pilot');

-- Fail: assign third passenger to ride a0000003 (already has Bob & Carol)
select 'assign_third_passenger_fail' as test, assign_person('a0000003-0000-0000-0000-000000000003',
  '33333333-3333-3333-3333-333333333333','passenger');

-- Fail: overlapping assignment (Alice already on a0000002, try again on overlapping a0000003)
select 'overlap_fail' as test, assign_person('a0000003-0000-0000-0000-000000000003',
  '33333333-3333-3333-3333-333333333333','passenger');

-- --------------------------------------------------
-- 4) Emergency contacts
-- --------------------------------------------------
-- Fail: passenger not on ride
select 'contact_fail' as test, link_emergency_contact('a0000002-0000-0000-0000-000000000002',
  '44444444-4444-4444-4444-444444444444','66666666-6666-6666-6666-666666666666');

-- Pass: valid passenger (Alice) on ride a0000002
select 'contact_pass' as test, link_emergency_contact('a0000002-0000-0000-0000-000000000002',
  '33333333-3333-3333-3333-333333333333','66666666-6666-6666-6666-666666666666');
