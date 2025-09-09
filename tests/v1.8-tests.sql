
-- v1.8-tests-fixed.sql (rev 4)
-- Same as rev 3, but forces execution of data-modifying CTEs by referencing them.

begin;

-- ==== Session Auth ====
select set_config('request.jwt.claim.sub', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', false);
insert into public.app_user_roles(user_id, role_key)
values ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'::uuid, 'admin')
on conflict do nothing;

set constraints all immediate;

-- ==== Helper ====
drop function if exists public._test_exec(text) cascade;
create or replace function public._test_exec(p_sql text)
returns jsonb language plpgsql as
$$
declare
  res jsonb;
begin
  begin
    execute 'select to_jsonb(('||p_sql||'))' into res;
    if res ? 'ok' then
      return res;
    else
      return jsonb_build_object('ok', true, 'data', res);
    end if;
  exception when others then
    begin
      execute p_sql;
      return jsonb_build_object('ok', true, 'data', '{}'::jsonb);
    exception when others then
      return jsonb_build_object('ok', false, 'error', jsonb_build_object('code','ERR_DB','message',SQLERRM));
    end;
  end;
end;
$$;

-- ==== Fixtures (idempotent) ====
insert into public.people (id, first_name, last_name, email, phone, status_key) values
  ('10000000-0000-0000-0000-000000000101','Polly','PilotActive','polly@ex.org',null,'active'),
  ('10000000-0000-0000-0000-000000000102','Alex','PilotActive2','alex@ex.org',null,'active'),
  ('10000000-0000-0000-0000-000000000108','Iggy','PilotInactive','iggy@ex.org',null,'inactive'),
  ('10000000-0000-0000-0000-000000000103','Paula','PassengerActive','paula@ex.org',null,'active'),
  ('10000000-0000-0000-0000-000000000104','Nate','NotInterested','nate@ex.org',null,'not_interested'),
  ('10000000-0000-0000-0000-000000000107','Patty','Passenger2','patty@ex.org',null,'active'),
  ('10000000-0000-0000-0000-000000000105','Eve','EmergencyInactive','eve@ex.org',null,'inactive'),
  ('10000000-0000-0000-0000-000000000106','Eli','EmergencyActive','eli@ex.org','+1 (206) 555-2222','active'),
  ('00000000-0000-0000-0000-000000000003','Sam','Student','sam.student@example.org',null,'active')
on conflict (id) do nothing;

insert into public.person_roles(person_id, role_key) values
  ('10000000-0000-0000-0000-000000000101','pilot'),
  ('10000000-0000-0000-0000-000000000102','pilot'),
  ('10000000-0000-0000-0000-000000000108','pilot'),
  ('10000000-0000-0000-0000-000000000103','passenger'),
  ('10000000-0000-0000-0000-000000000104','passenger'),
  ('10000000-0000-0000-0000-000000000107','passenger'),
  ('00000000-0000-0000-0000-000000000003','passenger'),
  ('10000000-0000-0000-0000-000000000105','emergency_contact'),
  ('10000000-0000-0000-0000-000000000106','emergency_contact')
on conflict do nothing;

delete from public.person_certs where person_id = '10000000-0000-0000-0000-000000000101';

delete from public.person_unavailability where person_id = '10000000-0000-0000-0000-000000000103';
insert into public.person_unavailability(person_id, starts_at, ends_at, reason)
values ('10000000-0000-0000-0000-000000000103',
        timestamptz '2025-01-15 18:00:00-08',
        timestamptz '2025-01-15 19:30:00-08',
        'medical')
on conflict do nothing;

-- ==== Tests ====
with tests(name, ok_expected, err_code_expected, sql_text) as (
  values
  ('ride_ok_create', true, null,
    $$ public.save_ride(null, timestamptz '2025-01-15 09:00:00-08', 60, 'scheduled', null) $$),

  ('ride_bad_hours', false, 'ERR_DB',
    $$ public.save_ride(null, timestamptz '2025-01-15 05:00:00-08', 60, 'scheduled', null) $$),

  ('cancel_without_reason', false, 'ERR_CANCEL_REASON',
    $$ public.save_ride(null, timestamptz '2025-01-15 09:15:00-08', 60, 'cancelled', null) $$),

  ('assign_pilot_missing_role', false, 'ERR_ROLE_MISSING',
    $$ public.assign_person(
         (public.save_ride(null, timestamptz '2025-01-15 12:00:00-08', 60, 'scheduled', null)->'data'->>'ride_id')::uuid,
         '10000000-0000-0000-0000-000000000103',
         'pilot'
       ) $$),

  ('assign_inactive_pilot', false, 'ERR_STATUS',
    $$ public.assign_person(
         (public.save_ride(null, timestamptz '2025-01-15 12:30:00-08', 60, 'scheduled', null)->'data'->>'ride_id')::uuid,
         '10000000-0000-0000-0000-000000000108',
         'pilot'
       ) $$),

  ('assign_not_interested_passenger', false, 'ERR_STATUS',
    $$ public.assign_person(
         (public.save_ride(null, timestamptz '2025-01-15 13:00:00-08', 60, 'scheduled', null)->'data'->>'ride_id')::uuid,
         '10000000-0000-0000-0000-000000000104',
         'passenger'
       ) $$),

  ('assign_unavailable_passenger', false, 'ERR_UNAVAILABLE',
    $$ public.assign_person(
         (public.save_ride(null, timestamptz '2025-01-15 18:30:00-08', 60, 'scheduled', null)->'data'->>'ride_id')::uuid,
         '10000000-0000-0000-0000-000000000103',
         'passenger'
       ) $$),

  ('pilot_cert_warning_info', true, null,
    $$ public.assign_person(
         (public.save_ride(null, timestamptz '2025-01-15 09:45:00-08', 60, 'scheduled', null)->'data'->>'ride_id')::uuid,
         '10000000-0000-0000-0000-000000000101',
         'pilot'
       ) $$),

  -- Force CTE execution by referencing them in the final SELECT
  ('second_pilot_db_error', false, 'ERR_DB',
    $$ with r as (
         select (public.save_ride(null, timestamptz '2025-01-15 10:00:00-08', 60,'scheduled',null)->'data'->>'ride_id')::uuid as id
       ), a1 as (
         select public.assign_person((select id from r), '10000000-0000-0000-0000-000000000101','pilot')
       )
       select public.assign_person((select id from r), '10000000-0000-0000-0000-000000000102','pilot')
       from a1 $$),

  ('third_passenger_db_error', false, 'ERR_DB',
    $$ with r as (
         select (public.save_ride(null, timestamptz '2025-01-15 14:00:00-08', 60,'scheduled',null)->'data'->>'ride_id')::uuid as id
       ), p1 as (
         select public.assign_person((select id from r), '10000000-0000-0000-0000-000000000103','passenger')
       ), p2 as (
         select public.assign_person((select id from r), '00000000-0000-0000-0000-000000000003','passenger')
       )
       select public.assign_person((select id from r), '10000000-0000-0000-0000-000000000107','passenger')
       from p2 $$),

  ('overlap_db_error', false, 'ERR_DB',
    $$ with r1 as (
         select (public.save_ride(null, timestamptz '2025-01-15 11:00:00-08', 90,'scheduled',null)->'data'->>'ride_id')::uuid as id
       ), a1 as (
         select public.assign_person((select id from r1),'10000000-0000-0000-0000-000000000101','pilot')
       ), r2 as (
         select (public.save_ride(null, timestamptz '2025-01-15 11:30:00-08', 60,'scheduled',null)->'data'->>'ride_id')::uuid as id
       )
       select public.assign_person((select id from r2),'10000000-0000-0000-0000-000000000101','pilot')
       from a1 $$),

  ('ec_wrong_role_db_error', false, 'ERR_DB',
    $$ with r as (
         select (public.save_ride(null, timestamptz '2025-01-15 15:00:00-08', 60,'scheduled',null)->'data'->>'ride_id')::uuid as id
       )
       select public.link_emergency_contact((select id from r), '10000000-0000-0000-0000-000000000103') $$),

  ('ec_inactive_db_error', false, 'ERR_DB',
    $$ with r as (
         select (public.save_ride(null, timestamptz '2025-01-15 15:30:00-08', 60,'scheduled',null)->'data'->>'ride_id')::uuid as id
       )
       select public.link_emergency_contact((select id from r), '10000000-0000-0000-0000-000000000105') $$),

  ('ec_unavailable_db_error', false, 'ERR_DB',
    $$ with r as (
         select (public.save_ride(null, timestamptz '2025-01-15 18:30:00-08', 60,'scheduled',null)->'data'->>'ride_id')::uuid as id
       ), u as (
         insert into public.person_unavailability(person_id, starts_at, ends_at, reason)
         values('10000000-0000-0000-0000-000000000106', timestamptz '2025-01-15 18:00:00-08', timestamptz '2025-01-15 19:30:00-08', 'busy')
         on conflict do nothing
         returning 1
       )
       select public.link_emergency_contact((select id from r), '10000000-0000-0000-0000-000000000106')
       from u $$)
)

-- ==== Execute ====
, actual as (
  select
    t.name,
    public._test_exec(t.sql_text) as res,
    t.ok_expected,
    t.err_code_expected
  from tests t
)
, evaluated as (
  select
    name,
    coalesce((res->>'ok')::boolean, false) as ok_actual,
    coalesce((res->'error'->>'code')::text, null) as err_code_actual,
    ok_expected,
    err_code_expected,
    res
  from actual
)
select
  name,
  (ok_actual = ok_expected
   and coalesce(err_code_actual,'') = coalesce(err_code_expected,'')) as pass,
  ok_expected, ok_actual,
  err_code_expected, err_code_actual,
  res as actual_json
from evaluated
order by pass asc, name;

rollback;
