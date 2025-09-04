-- v1.4-step3-rpcs-validations.sql
-- Purpose: Add RPCs (SECURITY DEFINER) that enforce key business rules:
--   - time window (07:00–20:00 America/Los_Angeles)
--   - status transitions
--   - exactly 1 pilot, <= 2 passengers
--   - no overlapping assignment for same person+role
--   - emergency contact must reference an assigned passenger
-- Returns JSONB envelopes: { ok, data, error }
-- Run AFTER step 1 (base schema) and step 2 (views+RLS).

begin;
set search_path = public;

-- ------------------------------------------------------------------
-- Helpers
-- ------------------------------------------------------------------

-- Convert to local time and check hour window
create or replace function is_within_operating_hours(ts timestamptz) returns boolean
language sql stable as $$
  select extract(hour from (ts at time zone 'America/Los_Angeles')) between 7 and 19;
$$;

-- Build json response helpers
create or replace function ok(data jsonb default null) returns jsonb
language sql immutable as $$
  select jsonb_build_object('ok', true, 'data', data, 'error', null);
$$;

create or replace function err(code text, message text, details text default null) returns jsonb
language sql immutable as $$
  select jsonb_build_object('ok', false, 'data', null, 'error', jsonb_build_object('code', code, 'message', message, 'details', details));
$$;

-- ------------------------------------------------------------------
-- Status transition validation
-- ------------------------------------------------------------------
create or replace function validate_status_transition(old_status ride_status, new_status ride_status)
returns boolean
language sql immutable as $$
  select case
    when old_status is null and new_status in ('tentative','scheduled','cancelled') then true
    when old_status = 'tentative' and new_status in ('scheduled','cancelled') then true
    when old_status = 'scheduled' and new_status in ('completed','cancelled') then true
    when old_status = 'completed' and new_status = 'completed' then true
    when old_status = 'cancelled' and new_status = 'cancelled' then true
    else false
  end;
$$;

-- ------------------------------------------------------------------
-- RPC: create_ride
-- ------------------------------------------------------------------
create or replace function create_ride(
  p_datetime timestamptz,
  p_duration_minutes int,
  p_origin_id uuid,
  p_destination_id uuid,
  p_status ride_status default 'tentative',
  p_cancellation_reason text default null,
  p_legacy_import boolean default false
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_id uuid;
begin
  if not is_within_operating_hours(p_datetime) and not p_legacy_import then
    return err('ERR_TIME_WINDOW','Ride time must be between 07:00–20:00 America/Los_Angeles.');
  end if;

  if p_status = 'cancelled' and coalesce(p_cancellation_reason,'') = '' then
    return err('ERR_INVALID_INPUT','cancellation_reason is required when status=cancelled');
  end if;

  insert into rides(id, date_time, duration_minutes, origin_id, destination_id, status, cancellation_reason, legacy_import, created_by, updated_by)
  values (gen_random_uuid(), p_datetime, p_duration_minutes, p_origin_id, p_destination_id, p_status, p_cancellation_reason, p_legacy_import, auth.uid(), auth.uid())
  returning id into v_id;

  return ok(jsonb_build_object('id', v_id));
exception when others then
  return err('ERR_CREATE_RIDE', sqlerrm);
end;
$$;

-- ------------------------------------------------------------------
-- RPC: update_ride (basic fields + status change with validation)
-- ------------------------------------------------------------------
create or replace function update_ride(
  p_id uuid,
  p_datetime timestamptz,
  p_duration_minutes int,
  p_origin_id uuid,
  p_destination_id uuid,
  p_status ride_status,
  p_cancellation_reason text default null,
  p_legacy_import boolean default false
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_old ride_status;
begin
  select status into v_old from rides where id = p_id;
  if v_old is null then
    return err('ERR_NOT_FOUND','Ride not found');
  end if;

  if not validate_status_transition(v_old, p_status) then
    return err('ERR_STATUS_TRANSITION', 'Invalid status transition from '||v_old||' to '||p_status);
  end if;

  if p_status = 'cancelled' and coalesce(p_cancellation_reason,'') = '' then
    return err('ERR_INVALID_INPUT','cancellation_reason is required when status=cancelled');
  end if;

  if not is_within_operating_hours(p_datetime) and not p_legacy_import then
    return err('ERR_TIME_WINDOW','Ride time must be between 07:00–20:00 America/Los_Angeles.');
  end if;

  update rides
     set date_time = p_datetime,
         duration_minutes = p_duration_minutes,
         origin_id = p_origin_id,
         destination_id = p_destination_id,
         status = p_status,
         cancellation_reason = p_cancellation_reason,
         legacy_import = p_legacy_import,
         updated_by = auth.uid()
   where id = p_id;

  return ok(jsonb_build_object('id', p_id));
exception when others then
  return err('ERR_UPDATE_RIDE', sqlerrm);
end;
$$;

-- ------------------------------------------------------------------
-- RPC: assign_person (enforces exactly 1 pilot, <=2 passengers, and no overlap)
-- ------------------------------------------------------------------
create or replace function assign_person(p_ride_id uuid, p_person_id uuid, p_role text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_dt timestamptz;
  v_dur int;
  v_pilot_count int;
  v_passenger_count int;
  v_overlap int;
begin
  if p_role not in ('pilot','passenger') then
    return err('ERR_INVALID_INPUT','role must be pilot or passenger');
  end if;

  select date_time, duration_minutes into v_dt, v_dur from rides where id = p_ride_id;
  if v_dt is null then
    return err('ERR_NOT_FOUND','Ride not found');
  end if;

  -- exactly 1 pilot
  if p_role = 'pilot' then
    select count(*) into v_pilot_count from ride_assignments where ride_id = p_ride_id and role = 'pilot';
    if v_pilot_count >= 1 then
      return err('ERR_DUPLICATE_ROLE','Ride already has a pilot');
    end if;
  end if;

  -- <= 2 passengers
  if p_role = 'passenger' then
    select count(*) into v_passenger_count from ride_assignments where ride_id = p_ride_id and role = 'passenger';
    if v_passenger_count >= 2 then
      return err('ERR_DUPLICATE_ROLE','Ride already has two passengers');
    end if;
  end if;

  -- no overlapping assignment for same person+role (approx using start & end)
  select count(*) into v_overlap
  from ride_assignments ra
  join rides r on r.id = ra.ride_id
  where ra.person_id = p_person_id
    and ra.role = p_role
    and tstzrange(r.date_time, r.date_time + make_interval(mins => r.duration_minutes), '[)')
        && tstzrange(v_dt, v_dt + make_interval(mins => v_dur), '[)');
  if v_overlap > 0 then
    return err('ERR_OVERLAP','Person already assigned to an overlapping ride for the same role');
  end if;

  insert into ride_assignments(ride_id, person_id, role) values (p_ride_id, p_person_id, p_role);
  return ok();
exception when others then
  return err('ERR_ASSIGN', sqlerrm);
end;
$$;

-- ------------------------------------------------------------------
-- RPC: unassign_person
-- ------------------------------------------------------------------
create or replace function unassign_person(p_ride_id uuid, p_person_id uuid, p_role text)
returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  delete from ride_assignments where ride_id = p_ride_id and person_id = p_person_id and role = p_role;
  return ok();
exception when others then
  return err('ERR_UNASSIGN', sqlerrm);
end;
$$;

-- ------------------------------------------------------------------
-- RPC: link_emergency_contact (must reference an assigned passenger)
-- ------------------------------------------------------------------
create or replace function link_emergency_contact(p_ride_id uuid, p_passenger_id uuid, p_contact_person_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_exists int;
begin
  select count(*) into v_exists
  from ride_assignments
  where ride_id = p_ride_id
    and person_id = p_passenger_id
    and role = 'passenger';
  if v_exists = 0 then
    return err('ERR_INVALID_INPUT','Passenger is not assigned to the ride');
  end if;

  insert into ride_assignment_contacts(ride_id, passenger_id, contact_person_id)
  values (p_ride_id, p_passenger_id, p_contact_person_id)
  on conflict (ride_id, passenger_id) do update
    set contact_person_id = excluded.contact_person_id;

  return ok();
exception when others then
  return err('ERR_CONTACT', sqlerrm);
end;
$$;

-- ------------------------------------------------------------------
-- Grants
-- ------------------------------------------------------------------
grant execute on function
  create_ride(timestamptz,int,uuid,uuid,ride_status,text,boolean),
  update_ride(uuid,timestamptz,int,uuid,uuid,ride_status,text,boolean),
  assign_person(uuid,uuid,text),
  unassign_person(uuid,uuid,text),
  link_emergency_contact(uuid,uuid,uuid),
  is_within_operating_hours(timestamptz),
  validate_status_transition(ride_status,ride_status),
  ok(jsonb),
  err(text,text,text)
to authenticated;

commit;
