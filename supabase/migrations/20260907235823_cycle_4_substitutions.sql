create or replace function private.assert_van_releasable(p_van_id uuid)
returns void
language plpgsql
set search_path = ''
as $$
declare
  v_now timestamptz := clock_timestamp();
begin
  if exists (
    select 1
    from public.routes r
    join public.route_schedules rs
      on rs.fleet_id = r.fleet_id and rs.route_id = r.id
    where r.van_id = p_van_id
      and r.status = 'active'
      and rs.status = 'active'
      and exists (
        select 1
        from private.schedule_windows(
          rs.id,
          (v_now at time zone rs.timezone)::date - 1,
          rs.valid_until
        ) w
        where upper(w."window") > v_now
      )
  ) or exists (
    select 1
    from public.trip_assignments ta
    join public.trips t on t.id = ta.trip_id and t.fleet_id = ta.fleet_id
    where ta.van_id = p_van_id
      and ta.valid_until is null
      and t.status in ('scheduled', 'confirmation_closed', 'active')
      and (t.status = 'active' or t.reserved_until > v_now)
  ) then
    perform private.raise_api_error('resource_in_use', 'Vehicle has current or future assignments', 409);
  end if;
end;
$$;

create or replace function private.assert_driver_releasable(
  p_fleet_id uuid,
  p_user_id uuid
) returns void
language plpgsql
set search_path = ''
as $$
declare
  v_now timestamptz := clock_timestamp();
begin
  if exists (
    select 1
    from public.routes r
    join public.route_schedules rs
      on rs.fleet_id = r.fleet_id and rs.route_id = r.id
    where r.fleet_id = p_fleet_id
      and r.driver_user_id = p_user_id
      and r.status = 'active'
      and rs.status = 'active'
      and exists (
        select 1
        from private.schedule_windows(
          rs.id,
          (v_now at time zone rs.timezone)::date - 1,
          rs.valid_until
        ) w
        where upper(w."window") > v_now
      )
  ) or exists (
    select 1
    from public.trip_assignments ta
    join public.trips t on t.id = ta.trip_id and t.fleet_id = ta.fleet_id
    where ta.fleet_id = p_fleet_id
      and ta.driver_user_id = p_user_id
      and ta.valid_until is null
      and t.status in ('scheduled', 'confirmation_closed', 'active')
      and (t.status = 'active' or t.reserved_until > v_now)
  ) then
    perform private.raise_api_error('resource_in_use', 'Driver has current or future assignments', 409);
  end if;
end;
$$;

create or replace function public.substitute_trip_resources(
  p_trip_id uuid,
  p_van_id uuid,
  p_driver_user_id uuid,
  p_reason text,
  p_command_id uuid
) returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_trip public.trips%rowtype;
  v_van public.vans%rowtype;
  v_assignment public.trip_assignments%rowtype;
  v_new_assignment_id uuid;
  v_membership_id uuid;
  v_passenger_count integer;
  v_now timestamptz;
  v_event public.trip_events%rowtype;
  v_event_id bigint;
  v_payload jsonb;
begin
  if v_user_id is null then
    perform private.raise_api_error('unauthenticated', 'Authentication required', 401);
  end if;
  if not private.current_user_email_confirmed() then
    perform private.raise_api_error('email_unverified', 'Email confirmation required', 403);
  end if;
  if p_trip_id is null or p_van_id is null or p_driver_user_id is null
    or p_reason is null or btrim(p_reason) = ''
    or char_length(btrim(p_reason)) > 500 or p_command_id is null then
    perform private.raise_api_error('invalid_input', 'Trip, resources, reason and command are required', 400);
  end if;
  v_payload := jsonb_build_object(
    'van_id', p_van_id,
    'driver_user_id', p_driver_user_id,
    'reason', btrim(p_reason)
  );

  perform private.lock_planning();
  select * into v_trip from public.trips where id = p_trip_id for update;
  if not found then
    perform private.raise_api_error('not_found', 'Trip not found', 404);
  end if;
  if not private.has_fleet_role(v_trip.fleet_id, v_user_id, 'owner') then
    perform private.raise_api_error('not_found', 'Trip not found', 404);
  end if;
  select * into v_event
  from public.trip_events
  where trip_id = p_trip_id and command_id = p_command_id;
  if found then
    if v_event.kind <> 'resources_substituted'
      or v_event.actor_user_id is distinct from v_user_id
      or v_event.payload_hash <> extensions.digest(v_payload::text, 'sha256') then
      perform private.raise_api_error('idempotency_conflict', 'Command payload differs', 409);
    end if;
    return v_event.result::uuid;
  end if;
  if v_trip.status not in ('scheduled', 'confirmation_closed', 'active') then
    perform private.raise_api_error('invalid_transition', 'Trip cannot change resources', 409);
  end if;
  if p_van_id = v_trip.van_id and p_driver_user_id = v_trip.driver_user_id then
    perform private.raise_api_error('invalid_input', 'Replacement must change a resource', 400);
  end if;

  select * into v_van
  from public.vans
  where id = p_van_id and fleet_id = v_trip.fleet_id
  for update;
  if not found or v_van.status <> 'active' then
    perform private.raise_api_error('resource_in_use', 'Replacement vehicle is unavailable', 409);
  end if;
  select fm.id into v_membership_id
  from public.fleet_memberships fm
  where fm.fleet_id = v_trip.fleet_id and fm.user_id = p_driver_user_id
  for update;
  if not found or not exists (
    select 1 from public.fleet_membership_roles fmr
    where fmr.membership_id = v_membership_id and fmr.role = 'driver'
  ) or exists (
    select 1 from public.fleet_memberships fm
    where fm.id = v_membership_id and fm.status <> 'active'
  ) then
    perform private.raise_api_error('resource_in_use', 'Replacement driver is unavailable', 409);
  end if;

  select count(*) into v_passenger_count
  from public.trip_passengers p
  where p.trip_id = p_trip_id and p.removed_at is null;
  if v_van.capacity < v_passenger_count then
    perform private.raise_api_error('capacity_exceeded', 'Replacement vehicle has insufficient capacity', 409);
  end if;
  -- An active execution owns its physical resources until it finishes.  Its
  -- actual duration can exceed the planned window, so an active trip must
  -- block a replacement independently of the scheduled timestamps.
  if exists (
    select 1
    from public.trips other
    where other.id <> v_trip.id
      and other.status = 'active'
      and (other.van_id = p_van_id or other.driver_user_id = p_driver_user_id)
  ) then
    perform private.raise_api_error('resource_in_use', 'Replacement resource is in an active trip', 409);
  end if;
  if exists (
    select 1
    from public.trips other
    where other.id <> v_trip.id
      and other.status in ('scheduled', 'confirmation_closed')
      and tstzrange(other.planned_start_at, other.reserved_until, '[)') &&
          tstzrange(v_trip.planned_start_at, v_trip.reserved_until, '[)')
      and (other.van_id = p_van_id or other.driver_user_id = p_driver_user_id)
  ) then
    perform private.raise_api_error('resource_in_use', 'Replacement resource overlaps another trip', 409);
  end if;
  if exists (
    select 1
    from public.route_schedules rs
    join public.routes r on r.id = rs.route_id and r.fleet_id = rs.fleet_id
    where rs.id <> v_trip.schedule_id
      and rs.status = 'active' and r.status = 'active'
      and (r.van_id = p_van_id or r.driver_user_id = p_driver_user_id)
      -- Include the adjacent local dates: an ends_next_day schedule on the
      -- previous date can overlap this trip after timezone conversion.
      and rs.valid_from <= v_trip.service_date + 1
      and rs.valid_until >= v_trip.service_date - 1
      and exists (
        select 1
        from private.schedule_windows(
          rs.id, v_trip.service_date - 1, v_trip.service_date + 1
        ) w
        where w."window" && tstzrange(v_trip.planned_start_at, v_trip.reserved_until, '[)')
      )
  ) then
    perform private.raise_api_error('schedule_conflict', 'Replacement resource overlaps its schedule', 409);
  end if;

  select * into v_assignment
  from public.trip_assignments
  where trip_id = p_trip_id and valid_until is null
  for update;
  if not found then
    perform private.raise_api_error('invalid_transition', 'Trip has no current assignment', 409);
  end if;
  v_now := greatest(clock_timestamp(), v_assignment.valid_from);
  update public.trip_assignments
  set valid_until = v_now
  where id = v_assignment.id;
  insert into public.trip_assignments (
    fleet_id, trip_id, van_id, driver_user_id, valid_from, reason, actor_user_id
  ) values (
    v_trip.fleet_id, p_trip_id, p_van_id, p_driver_user_id,
    v_now, btrim(p_reason), v_user_id
  ) returning id into v_new_assignment_id;
  update public.trips
  set van_id = p_van_id, driver_user_id = p_driver_user_id, revision = revision + 1
  where id = p_trip_id;
  v_event_id := private.append_trip_event(
    p_trip_id, p_command_id, 'resources_substituted', v_payload, clock_timestamp()
  );
  update public.trip_events
  set result = v_new_assignment_id::text
  where id = v_event_id;
  return v_new_assignment_id;
end;
$$;

revoke all on function private.assert_van_releasable(uuid)
  from public, anon, authenticated;
revoke all on function private.assert_driver_releasable(uuid, uuid)
  from public, anon, authenticated;
revoke all on function public.substitute_trip_resources(uuid, uuid, uuid, text, uuid)
  from public, anon;
grant execute on function private.assert_van_releasable(uuid) to postgres, supabase_admin;
grant execute on function private.assert_driver_releasable(uuid, uuid) to postgres, supabase_admin;
grant execute on function public.substitute_trip_resources(uuid, uuid, uuid, text, uuid)
  to authenticated;

-- Keep the school used by each enrollment in the operational passenger snapshot.
alter table public.trip_passengers
  add column if not exists school_id uuid;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'trip_passengers_school_fk'
      and conrelid = 'public.trip_passengers'::regclass
  ) then
    alter table public.trip_passengers
      add constraint trip_passengers_school_fk
      foreign key (school_id) references public.schools(id) on delete restrict;
  end if;
end;
$$;

update public.trip_passengers p
set school_id = e.school_id
from public.fleet_enrollments e
where e.id = p.enrollment_id and p.school_id is null;

alter table public.trip_passengers
  alter column school_id set not null;

create index if not exists trip_passengers_school_idx
  on public.trip_passengers (fleet_id, school_id, trip_id);

create or replace function private.snapshot_trip_passenger_school()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.school_id is null then
    select e.school_id into new.school_id
    from public.fleet_enrollments e
    where e.id = new.enrollment_id and e.fleet_id = new.fleet_id;
  end if;
  if new.school_id is null then
    perform private.raise_api_error('invalid_input', 'Enrollment school is required', 400);
  end if;
  return new;
end;
$$;

drop trigger if exists trip_passengers_snapshot_school on public.trip_passengers;
create trigger trip_passengers_snapshot_school
before insert on public.trip_passengers
for each row execute function private.snapshot_trip_passenger_school();

create or replace function private.generate_trips(
  p_service_date date,
  p_now timestamptz
) returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_schedule record;
  v_trip_id uuid;
  v_day_id uuid;
  v_start_at timestamptz;
  v_end_at timestamptz;
  v_deadline timestamptz;
  v_created integer := 0;
  v_command_id uuid;
  v_passenger record;
  v_stop record;
  v_home_position integer;
  v_school_position integer;
begin
  if p_service_date is null or p_now is null or not isfinite(p_service_date) then
    perform private.raise_api_error('invalid_input', 'Service date and clock are required', 400);
  end if;
  perform private.lock_planning();

  for v_schedule in
    select rs.*, r.van_id, r.driver_user_id, r.direction
    from public.route_schedules rs
    join public.routes r on r.id = rs.route_id and r.fleet_id = rs.fleet_id
    where rs.status = 'active'
      and r.status = 'active'
      and p_service_date between rs.valid_from and rs.valid_until
      and extract(isodow from p_service_date)::smallint = any(rs.weekdays)
      and not exists (
        select 1 from public.route_service_exceptions e
        where e.fleet_id = rs.fleet_id and e.route_id = rs.route_id
          and e.service_date = p_service_date and e.enabled = false
      )
    order by rs.fleet_id, rs.id
  loop
    v_start_at := (p_service_date + v_schedule.starts_at) at time zone v_schedule.timezone;
    v_end_at := (
      p_service_date + case when v_schedule.ends_next_day then 1 else 0 end
      + v_schedule.ends_at
    ) at time zone v_schedule.timezone;
    v_deadline := v_start_at - make_interval(mins => v_schedule.confirmation_minutes);
    v_trip_id := null;

    insert into public.service_days (fleet_id, service_date)
    values (v_schedule.fleet_id, p_service_date)
    on conflict (fleet_id, service_date) do nothing;
    select id into v_day_id
    from public.service_days
    where fleet_id = v_schedule.fleet_id and service_date = p_service_date;

    insert into public.trips (
      fleet_id, service_day_id, route_id, schedule_id, service_date,
      planned_start_at, reserved_until, confirmation_deadline, status,
      van_id, driver_user_id
    ) values (
      v_schedule.fleet_id, v_day_id, v_schedule.route_id, v_schedule.id, p_service_date,
      v_start_at, v_end_at, v_deadline, 'scheduled', v_schedule.van_id,
      v_schedule.driver_user_id
    )
    on conflict (schedule_id, service_date) do nothing
    returning id into v_trip_id;
    if v_trip_id is null then
      continue;
    end if;
    v_created := v_created + 1;

    insert into public.trip_assignments (
      fleet_id, trip_id, van_id, driver_user_id, valid_from, reason
    ) values (
      v_schedule.fleet_id, v_trip_id, v_schedule.van_id, v_schedule.driver_user_id,
      p_now, 'generated'
    );

    insert into public.trip_stops (
      fleet_id, trip_id, kind, position, address_snapshot,
      latitude, longitude
    ) values (
      v_schedule.fleet_id, v_trip_id, 'origin', 1,
      jsonb_build_object('label', (select r.origin_label from public.routes r
        where r.id = v_schedule.route_id and r.fleet_id = v_schedule.fleet_id)),
      (select r.origin_latitude from public.routes r
        where r.id = v_schedule.route_id and r.fleet_id = v_schedule.fleet_id),
      (select r.origin_longitude from public.routes r
        where r.id = v_schedule.route_id and r.fleet_id = v_schedule.fleet_id)
    );

    for v_passenger in
      select tr.enrollment_id, tr.student_id, e.student_id as enrolled_student_id,
             e.school_id
      from public.transport_reservations tr
      join public.fleet_enrollments e
        on e.id = tr.enrollment_id and e.fleet_id = tr.fleet_id
      where tr.fleet_id = v_schedule.fleet_id
        and tr.schedule_id = v_schedule.id
        and tr.weekday = extract(isodow from p_service_date)::smallint
        and tr.valid_from <= p_service_date
        and tr.valid_until >= p_service_date
        and tr.status = 'active'
        and e.fleet_id = v_schedule.fleet_id
        and e.status = 'active'
    loop
      insert into public.trip_passengers (
        fleet_id, trip_id, enrollment_id, student_id, school_id
      ) values (
        v_schedule.fleet_id, v_trip_id, v_passenger.enrollment_id,
        v_passenger.enrolled_student_id, v_passenger.school_id
      ) on conflict (trip_id, enrollment_id) do nothing;
    end loop;

    for v_stop in
      select 'school'::text as kind, null::uuid as student_id, rs.school_id,
             rs.position, jsonb_build_object(
               'name', s.name, 'street', s.street, 'street_number', s.street_number,
               'neighborhood', s.neighborhood, 'city_name', s.city_name,
               'city_ibge_code', s.city_ibge_code, 'state_code', s.state_code
             ) as address_snapshot, s.latitude, s.longitude
      from public.route_schools rs
      join public.schools s on s.id = rs.school_id
      where rs.route_id = v_schedule.route_id and rs.fleet_id = v_schedule.fleet_id
      order by rs.position
    loop
      insert into public.trip_stops (
        fleet_id, trip_id, kind, student_id, school_id, position,
        address_snapshot, latitude, longitude
      ) values (
        v_schedule.fleet_id, v_trip_id, v_stop.kind, v_stop.student_id, v_stop.school_id,
        case when v_schedule.direction = 'going' then 100000 else 1000 end
          + v_stop.position,
        v_stop.address_snapshot, v_stop.latitude, v_stop.longitude
      );
    end loop;

    -- A current enrollment can point to a school that was added to the fleet
    -- after the route was designed. Keep that school in the trip snapshot.
    v_school_position := case when v_schedule.direction = 'going' then 100000 else 1000 end;
    select coalesce(max(s.position), v_school_position) + 1
      into v_school_position
    from public.trip_stops s
    where s.trip_id = v_trip_id and s.kind = 'school';
    for v_stop in
      select distinct p.school_id, s.name, s.street, s.street_number,
             s.neighborhood, s.city_name, s.city_ibge_code, s.state_code,
             s.latitude, s.longitude
      from public.trip_passengers p
      join public.schools s on s.id = p.school_id
      where p.trip_id = v_trip_id
        and not exists (
          select 1 from public.trip_stops existing
          where existing.trip_id = v_trip_id and existing.kind = 'school'
            and existing.school_id = p.school_id
        )
      order by p.school_id
    loop
      insert into public.trip_stops (
        fleet_id, trip_id, kind, school_id, position, address_snapshot,
        latitude, longitude
      ) values (
        v_schedule.fleet_id, v_trip_id, 'school', v_stop.school_id,
        v_school_position,
        jsonb_build_object(
          'name', v_stop.name, 'street', v_stop.street,
          'street_number', v_stop.street_number,
          'neighborhood', v_stop.neighborhood, 'city_name', v_stop.city_name,
          'city_ibge_code', v_stop.city_ibge_code, 'state_code', v_stop.state_code
        ), v_stop.latitude, v_stop.longitude
      );
      v_school_position := v_school_position + 1;
    end loop;

    v_home_position := case when v_schedule.direction = 'going' then 1000 else 100000 end;
    for v_stop in
      select tp.student_id, jsonb_build_object(
               'postal_code', s.postal_code, 'street', s.street,
               'street_number', s.street_number, 'address_complement', s.address_complement,
               'neighborhood', s.neighborhood, 'city_name', s.city_name,
               'city_ibge_code', s.city_ibge_code, 'state_code', s.state_code
             ) as address_snapshot, s.latitude, s.longitude
      from public.trip_passengers tp
      join public.students s on s.id = tp.student_id
      where tp.trip_id = v_trip_id and tp.removed_at is null
      order by tp.student_id
    loop
      insert into public.trip_stops (
        fleet_id, trip_id, kind, student_id, position,
        address_snapshot, latitude, longitude
      ) values (
        v_schedule.fleet_id, v_trip_id, 'home', v_stop.student_id, v_home_position,
        v_stop.address_snapshot, v_stop.latitude, v_stop.longitude
      );
      v_home_position := v_home_position + 1;
    end loop;

    insert into public.trip_stops (
      fleet_id, trip_id, kind, position, address_snapshot,
      latitude, longitude
    ) values (
      v_schedule.fleet_id, v_trip_id, 'destination', 200000,
      jsonb_build_object('label', (select r.destination_label from public.routes r
        where r.id = v_schedule.route_id and r.fleet_id = v_schedule.fleet_id)),
      (select r.destination_latitude from public.routes r
        where r.id = v_schedule.route_id and r.fleet_id = v_schedule.fleet_id),
      (select r.destination_longitude from public.routes r
        where r.id = v_schedule.route_id and r.fleet_id = v_schedule.fleet_id)
    );

    v_command_id := extensions.gen_random_uuid();
    perform private.append_trip_event(
      v_trip_id, v_command_id, 'trip_generated',
      jsonb_build_object('service_date', p_service_date), p_now
    );
  end loop;
  return v_created;
end;
$$;

revoke execute on function private.snapshot_trip_passenger_school() from public, anon, authenticated;
revoke execute on function private.generate_trips(date, timestamptz)
  from public, anon, authenticated;
grant execute on function private.generate_trips(date, timestamptz)
  to postgres, supabase_admin;

alter table public.trips
  add column if not exists cancelled_by_service boolean not null default false;

create or replace function public.set_service_enabled(
  p_fleet_id uuid,
  p_route_ids uuid[],
  p_service_date date,
  p_enabled boolean,
  p_reason text
) returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_route_id uuid;
  v_trip record;
  v_count integer := 0;
  v_reason text := nullif(btrim(p_reason), '');
  v_event_id bigint;
  v_now timestamptz;
begin
  if v_user_id is null then
    perform private.raise_api_error('unauthenticated', 'Authentication required', 401);
  end if;
  if not private.current_user_email_confirmed() then
    perform private.raise_api_error('email_unverified', 'Email confirmation required', 403);
  end if;
  if p_fleet_id is null or p_service_date is null or not isfinite(p_service_date)
    or p_enabled is null then
    perform private.raise_api_error('invalid_input', 'Fleet, finite date and enabled are required', 400);
  end if;
  if p_route_ids is not null and cardinality(p_route_ids) = 0 then
    perform private.raise_api_error('invalid_input', 'Route list cannot be empty', 400);
  end if;
  if not p_enabled and v_reason is null then
    perform private.raise_api_error('invalid_input', 'A reason is required when disabling service', 400);
  end if;
  if v_reason is not null and char_length(v_reason) > 500 then
    perform private.raise_api_error('invalid_input', 'Reason is too long', 400);
  end if;
  perform private.lock_planning();
  perform 1 from public.fleets f where f.id = p_fleet_id for update;
  if not found or not private.has_fleet_role(p_fleet_id, v_user_id, 'owner') then
    perform private.raise_api_error('not_found', 'Fleet not found', 404);
  end if;
  if p_route_ids is not null and exists (
    select 1 from unnest(p_route_ids) requested(route_id)
    left join public.routes r on r.id = requested.route_id and r.fleet_id = p_fleet_id
    where r.id is null
  ) then
    perform private.raise_api_error('not_found', 'Route not found', 404);
  end if;
  v_now := clock_timestamp();
  for v_route_id in
    select r.id from public.routes r
    where r.fleet_id = p_fleet_id and (p_route_ids is null or r.id = any(p_route_ids))
    order by r.id for update
  loop
    insert into public.route_service_exceptions (
      fleet_id, route_id, service_date, enabled, reason, updated_by, updated_at
    ) values (
      p_fleet_id, v_route_id, p_service_date, p_enabled, v_reason, v_user_id, v_now
    )
    on conflict (route_id, service_date) do update
      set enabled = excluded.enabled, reason = excluded.reason,
          updated_by = excluded.updated_by, updated_at = excluded.updated_at;

    for v_trip in
      select t.id, t.status, t.started_at, t.confirmation_deadline,
             t.cancelled_by_service
      from public.trips t
      where t.fleet_id = p_fleet_id and t.route_id = v_route_id
        and t.service_date = p_service_date
      order by t.id for update
    loop
      if not p_enabled and v_trip.status in ('scheduled', 'confirmation_closed') then
        update public.trips
        set status = 'cancelled', cancelled_by_service = true, revision = revision + 1
        where id = v_trip.id;
        v_event_id := private.append_trip_event(
          v_trip.id, extensions.gen_random_uuid(), 'service_disabled',
          jsonb_build_object('service_date', p_service_date, 'reason', v_reason), v_now
        );
        update public.trip_events set result = 'cancelled' where id = v_event_id;
      elsif p_enabled and v_trip.status = 'cancelled'
        and v_trip.cancelled_by_service and v_trip.started_at is null then
        if v_trip.confirmation_deadline <= v_now then
          update public.trips
          set status = 'confirmation_closed', cancelled_by_service = false,
              revision = revision + 1
          where id = v_trip.id;
          update public.trip_passengers
          set confirmation_status = 'expired', confirmation_by = null, confirmation_at = null
          where trip_id = v_trip.id and removed_at is null;
        else
          update public.trips
          set status = 'scheduled', cancelled_by_service = false, revision = revision + 1
          where id = v_trip.id;
          update public.trip_passengers
          set confirmation_status = 'pending', confirmation_by = null, confirmation_at = null
          where trip_id = v_trip.id and removed_at is null;
        end if;
        v_event_id := private.append_trip_event(
          v_trip.id, extensions.gen_random_uuid(), 'service_enabled',
          jsonb_build_object('service_date', p_service_date, 'confirmation_closed',
            v_trip.confirmation_deadline <= v_now), v_now
        );
        update public.trip_events
        set result = case when v_trip.confirmation_deadline <= v_now
          then 'confirmation_closed' else 'scheduled' end
        where id = v_event_id;
      end if;
    end loop;

    insert into public.audit_events (
      fleet_id, actor_user_id, action, entity_type, entity_id, metadata
    ) values (
      p_fleet_id, v_user_id,
      case when p_enabled then 'service_enabled' else 'service_disabled' end,
      'route', v_route_id,
      jsonb_build_object('service_date', p_service_date, 'enabled', p_enabled)
    );
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;

revoke execute on function public.set_service_enabled(uuid, uuid[], date, boolean, text)
  from public, anon;
grant execute on function public.set_service_enabled(uuid, uuid[], date, boolean, text)
  to authenticated;

create or replace function public.respond_trip(
  p_trip_id uuid,
  p_student_id uuid,
  p_confirm boolean,
  p_command_id uuid
) returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_trip public.trips%rowtype;
  v_passenger public.trip_passengers%rowtype;
  v_kind text;
  v_result text;
  v_event_id bigint;
  v_existing public.trip_events%rowtype;
  v_payload jsonb;
begin
  if v_user_id is null then
    perform private.raise_api_error('unauthenticated', 'Authentication required', 401);
  end if;
  if not private.current_user_email_confirmed() then
    perform private.raise_api_error('email_unverified', 'Email confirmation required', 403);
  end if;
  if p_trip_id is null or p_student_id is null or p_confirm is null or p_command_id is null then
    perform private.raise_api_error('invalid_input', 'Trip, student, response and command are required', 400);
  end if;
  perform private.lock_planning();
  select * into v_trip from public.trips where id = p_trip_id for update;
  if not found then
    perform private.raise_api_error('not_found', 'Trip not found', 404);
  end if;
  select * into v_passenger
  from public.trip_passengers p
  where p.trip_id = p_trip_id and p.student_id = p_student_id
  for update;
  if not found or v_passenger.removed_at is not null then
    perform private.raise_api_error('not_found', 'Passenger not found', 404);
  end if;
  if not private.can_view_student(p_student_id, v_user_id)
    or not private.is_active_fleet_member(v_trip.fleet_id, v_user_id) then
    perform private.raise_api_error('not_found', 'Passenger not found', 404);
  end if;
  v_kind := case when p_confirm then 'student_confirmed' else 'student_declined' end;
  v_result := case when p_confirm then 'confirmed' else 'declined' end;
  v_payload := jsonb_build_object('student_id', p_student_id, 'confirm', p_confirm);
  select * into v_existing
  from public.trip_events
  where trip_id = p_trip_id and command_id = p_command_id;
  if found then
    if v_existing.kind <> v_kind or v_existing.actor_user_id is distinct from v_user_id
      or v_existing.payload_hash <> extensions.digest(v_payload::text, 'sha256') then
      perform private.raise_api_error('idempotency_conflict', 'Command payload differs', 409);
    end if;
    return v_existing.result;
  end if;
  if v_trip.status <> 'scheduled' then
    perform private.raise_api_error('confirmation_closed', 'Confirmation is closed', 409);
  end if;
  if clock_timestamp() >= v_trip.confirmation_deadline then
    perform private.raise_api_error('confirmation_closed', 'Confirmation is closed', 409);
  end if;
  if v_passenger.confirmation_status = 'expired' then
    perform private.raise_api_error('confirmation_closed', 'Confirmation is closed', 409);
  end if;
  update public.trip_passengers
  set confirmation_status = v_result,
      confirmation_by = v_user_id,
      confirmation_at = clock_timestamp()
  where id = v_passenger.id;
  v_event_id := private.append_trip_event(
    p_trip_id, p_command_id, v_kind, v_payload, clock_timestamp()
  );
  update public.trip_events set result = v_result where id = v_event_id;
  return v_result;
end;
$$;

create or replace function public.override_trip_participation(
  p_trip_id uuid,
  p_student_id uuid,
  p_confirm boolean,
  p_reason text,
  p_command_id uuid
) returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_trip public.trips%rowtype;
  v_passenger public.trip_passengers%rowtype;
  v_result text;
  v_event_id bigint;
  v_existing public.trip_events%rowtype;
  v_payload jsonb;
begin
  if v_user_id is null then
    perform private.raise_api_error('unauthenticated', 'Authentication required', 401);
  end if;
  if not private.current_user_email_confirmed() then
    perform private.raise_api_error('email_unverified', 'Email confirmation required', 403);
  end if;
  if p_trip_id is null or p_student_id is null or p_confirm is null
    or p_reason is null or btrim(p_reason) = ''
    or char_length(btrim(p_reason)) > 500 or p_command_id is null then
    perform private.raise_api_error('invalid_input', 'Student, response, reason and command are required', 400);
  end if;
  v_result := case when p_confirm then 'confirmed' else 'declined' end;
  v_payload := jsonb_build_object(
    'student_id', p_student_id, 'confirm', p_confirm, 'reason', btrim(p_reason)
  );
  perform private.lock_planning();
  select * into v_trip from public.trips where id = p_trip_id for update;
  if not found then
    perform private.raise_api_error('not_found', 'Trip not found', 404);
  end if;
  if not private.has_fleet_role(v_trip.fleet_id, v_user_id, 'owner') then
    perform private.raise_api_error('not_found', 'Trip not found', 404);
  end if;
  select * into v_passenger from public.trip_passengers p
  where p.trip_id = p_trip_id and p.student_id = p_student_id for update;
  if not found or v_passenger.removed_at is not null then
    perform private.raise_api_error('not_found', 'Passenger not found', 404);
  end if;
  select * into v_existing from public.trip_events
  where trip_id = p_trip_id and command_id = p_command_id;
  if found then
    if v_existing.kind <> 'participation_overridden'
      or v_existing.actor_user_id is distinct from v_user_id
      or v_existing.payload_hash <> extensions.digest(v_payload::text, 'sha256') then
      perform private.raise_api_error('idempotency_conflict', 'Command payload differs', 409);
    end if;
    return v_existing.result;
  end if;
  if v_trip.status not in ('scheduled', 'confirmation_closed') then
    perform private.raise_api_error('trip_active', 'Trip has already started', 409);
  end if;
  if v_trip.status = 'scheduled' and clock_timestamp() < v_trip.confirmation_deadline then
    perform private.raise_api_error('confirmation_open', 'Confirmation window is still open', 409);
  end if;
  update public.trip_passengers
  set confirmation_status = v_result,
      confirmation_by = v_user_id,
      confirmation_at = clock_timestamp()
  where id = v_passenger.id;
  update public.trips set revision = revision + 1 where id = p_trip_id;
  v_event_id := private.append_trip_event(
    p_trip_id, p_command_id, 'participation_overridden', v_payload, clock_timestamp()
  );
  update public.trip_events set result = v_result where id = v_event_id;
  return v_result;
end;
$$;

revoke execute on function public.respond_trip(uuid, uuid, boolean, uuid)
  from public, anon;
revoke execute on function public.override_trip_participation(uuid, uuid, boolean, text, uuid)
  from public, anon;
grant execute on function public.respond_trip(uuid, uuid, boolean, uuid) to authenticated;
grant execute on function public.override_trip_participation(uuid, uuid, boolean, text, uuid)
  to authenticated;
