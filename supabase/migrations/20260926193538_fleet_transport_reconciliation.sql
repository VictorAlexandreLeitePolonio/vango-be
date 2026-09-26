-- Reserve a gap under the caller's planning/trip locks, including compact calculated orders.
create function private.reserve_reconciled_stop_position(p_trip_id uuid,p_kind text,p_school_id uuid default null)
returns integer language plpgsql security definer set search_path = '' as $$
declare
 v_direction text;
 v_route_id uuid;
 v_position integer;
 v_stop record;
begin
 select r.direction,r.id into v_direction,v_route_id from public.trips t
 join public.routes r on r.id=t.route_id where t.id=p_trip_id;
 if p_kind='school' then
   select min(s.position) into v_position from public.trip_stops s
   join public.route_schools existing_school on existing_school.route_id=v_route_id and existing_school.school_id=s.school_id
   join public.route_schools added_school on added_school.route_id=v_route_id and added_school.school_id=p_school_id
   where s.trip_id=p_trip_id and s.kind='school' and existing_school.position>added_school.position;
 end if;
 if v_position is null then
   select min(s.position) into v_position from public.trip_stops s where s.trip_id=p_trip_id
   and (s.kind='destination' or (p_kind='home' and v_direction='going' and s.kind='school')
     or (p_kind='school' and v_direction='return' and s.kind='home'));
 end if;
 if v_position is null then
   select coalesce(max(position),0)+1 into v_position from public.trip_stops where trip_id=p_trip_id;
 end if;
 -- Descending updates avoid unique-position conflicts without a fixed offset ceiling.
 for v_stop in select id,position from public.trip_stops
   where trip_id=p_trip_id and position>=v_position order by position desc
 loop
   update public.trip_stops set position=v_stop.position+1 where id=v_stop.id;
 end loop;
 return v_position;
end;
$$;
revoke execute on function private.reserve_reconciled_stop_position(uuid,text,uuid) from public,anon,authenticated;
grant execute on function private.reserve_reconciled_stop_position(uuid,text,uuid) to postgres;

create or replace function private.reconcile_enrollment_trips(
  p_enrollment_id uuid,
  p_kind text,
  p_effective_on date,
  p_now timestamptz
) returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_enrollment public.fleet_enrollments%rowtype;
  v_student public.students%rowtype;
  v_school public.schools%rowtype;
  v_trip record;
  v_passenger public.trip_passengers%rowtype;
  v_reservation record;
  v_route_direction text;
  v_home_position integer;
  v_school_position integer;
  v_changed boolean;
  v_count integer := 0;
  v_home_snapshot jsonb;
  v_school_snapshot jsonb;
begin
  if p_enrollment_id is null or p_kind is null or p_kind not in ('schedule', 'address', 'school', 'ended')
    or p_effective_on is null or not isfinite(p_effective_on) or p_now is null then
    perform private.raise_api_error('invalid_input', 'Invalid reconciliation request', 400);
  end if;

  perform private.lock_planning();
  select * into v_enrollment
  from public.fleet_enrollments e
  where e.id = p_enrollment_id
  for update;
  if not found then
    perform private.raise_api_error('not_found', 'Enrollment not found', 404);
  end if;
  select * into v_student
  from public.students s
  where s.id = v_enrollment.student_id
  for update;
  if not found then
    perform private.raise_api_error('not_found', 'Student not found', 404);
  end if;

  -- Ending an enrollment is atomic with this check.  A passenger who is
  -- confirmed and still waiting/boarded is part of the active operation.
  if p_kind = 'ended' and exists (
    select 1
    from public.trips t
    join public.trip_passengers p
      on p.trip_id = t.id and p.fleet_id = t.fleet_id
    where t.fleet_id = v_enrollment.fleet_id
      and p.enrollment_id = p_enrollment_id
      and t.status = 'active'
      and p.removed_at is null
      and p.confirmation_status = 'confirmed'
      and p.operation_status in ('waiting', 'boarded')
  ) then
    perform private.raise_api_error('trip_active', 'Enrollment participates in an active trip', 409);
  end if;

  if p_kind in ('schedule', 'address', 'school') then
    if v_enrollment.school_id is null then
      perform private.raise_api_error('invalid_input', 'Enrollment school is required', 400);
    end if;
    select * into v_school
    from public.schools s
    where s.id = v_enrollment.school_id;
    if not found then
      perform private.raise_api_error('not_found', 'Enrollment school not found', 404);
    end if;
    v_home_snapshot := jsonb_build_object(
      'postal_code', v_student.postal_code, 'street', v_student.street,
      'street_number', v_student.street_number, 'address_complement', v_student.address_complement,
      'neighborhood', v_student.neighborhood, 'city_name', v_student.city_name,
      'city_ibge_code', v_student.city_ibge_code, 'state_code', v_student.state_code
    );
    v_school_snapshot := jsonb_build_object(
      'name', v_school.name, 'street', v_school.street, 'street_number', v_school.street_number,
      'neighborhood', v_school.neighborhood, 'city_name', v_school.city_name,
      'city_ibge_code', v_school.city_ibge_code, 'state_code', v_school.state_code
    );
  end if;

  -- Lock trips in a stable order after the planning lock.  Only executions
  -- that have not started can receive a new snapshot or lose participation.
  for v_trip in
    select t.*
    from public.trips t
    join public.trip_passengers p
      on p.trip_id = t.id and p.fleet_id = t.fleet_id
    where p.enrollment_id = p_enrollment_id
      and t.started_at is null
      and t.status in ('scheduled', 'confirmation_closed')
      and (p_kind = 'ended' or t.service_date >= p_effective_on)
    order by t.id
  loop
    perform 1 from public.trips t where t.id = v_trip.id for update;
    select * into v_passenger
    from public.trip_passengers p
    where p.trip_id = v_trip.id and p.enrollment_id = p_enrollment_id
    for update;
    if not found then
      continue;
    end if;
    v_changed := false;

    if p_kind = 'ended' then
      if v_passenger.removed_at is null then
        update public.trip_passengers
        set removed_at = p_now, removal_reason = 'enrollment ended'
        where id = v_passenger.id;
        v_changed := true;
      end if;
    elsif p_kind = 'schedule' then
      if v_trip.status <> 'scheduled' or p_now >= v_trip.confirmation_deadline
        or v_passenger.operation_status <> 'waiting' then continue; end if;
      if not exists (
        select 1
        from public.transport_reservations tr
        where tr.enrollment_id = p_enrollment_id
          and tr.fleet_id = v_trip.fleet_id
          and tr.schedule_id = v_trip.schedule_id
          and tr.weekday = extract(isodow from v_trip.service_date)::smallint
          and tr.status = 'active'
          and tr.valid_from <= v_trip.service_date
          and tr.valid_until >= v_trip.service_date
      ) then
        if v_passenger.removed_at is null then
          update public.trip_passengers
          set removed_at = p_now, removal_reason = 'superseded by schedule change'
          where id = v_passenger.id;
          v_changed := true;
        end if;
      elsif v_passenger.removed_at is not null
        and v_passenger.removal_reason = 'superseded by schedule change' then
        -- Reinstatement keeps passenger/stop identities, but old consent is not reused.
        update public.trip_passengers
        set removed_at = null, removal_reason = null, confirmation_status = 'pending',
            confirmation_by = null, confirmation_at = null
        where id = v_passenger.id;
        v_changed := true;
      end if;
    else
      if p_kind = 'school' and v_passenger.school_id is distinct from v_enrollment.school_id then
        update public.trip_passengers
        set school_id = v_enrollment.school_id
        where id = v_passenger.id;
        v_changed := true;
      end if;
      if p_kind = 'address' then
        update public.trip_stops
        set address_snapshot = v_home_snapshot,
            latitude = v_student.latitude, longitude = v_student.longitude
        where trip_id = v_trip.id and kind = 'home' and student_id = v_student.id;
        if found then
          v_changed := true;
        end if;
      end if;
      if p_kind = 'school' then
        update public.trip_stops
        set address_snapshot = v_school_snapshot,
            latitude = v_school.latitude, longitude = v_school.longitude
        where trip_id = v_trip.id and kind = 'school'
          and school_id = v_enrollment.school_id;
        if found then
          v_changed := true;
        else
          select r.direction into v_route_direction
          from public.routes r
          where r.id = v_trip.route_id and r.fleet_id = v_trip.fleet_id;
          select coalesce(max(s.position),
            case when v_route_direction = 'going' then 100000 else 1000 end) + 1
          into v_school_position
          from public.trip_stops s
          where s.trip_id = v_trip.id and s.kind = 'school';
          insert into public.trip_stops (
            fleet_id, trip_id, kind, school_id, position, address_snapshot,
            latitude, longitude
          ) values (
            v_trip.fleet_id, v_trip.id, 'school', v_enrollment.school_id,
            v_school_position, v_school_snapshot, v_school.latitude, v_school.longitude
          );
          v_changed := true;
        end if;
      end if;
    end if;

    if v_changed then
      update public.trips
      set revision = revision + 1
      where id = v_trip.id;
      perform private.append_trip_event(
        v_trip.id, extensions.gen_random_uuid(), 'trip_reconciled',
        jsonb_build_object(
          'enrollment_id', p_enrollment_id, 'kind', p_kind,
          'effective_on', p_effective_on
        ), p_now
      );
      v_count := v_count + 1;
    end if;
  end loop;

  -- A schedule change may create a trip for a new schedule on a date that was
  -- already materialized.  Add this enrollment to that existing execution.
  if p_kind = 'schedule' then
    for v_reservation in
      select tr.*, t.id as trip_id, t.confirmation_deadline
      from public.transport_reservations tr
      join public.trips t
        on t.fleet_id = tr.fleet_id and t.schedule_id = tr.schedule_id
       and t.service_date >= greatest(tr.valid_from, p_effective_on)
       and t.service_date <= tr.valid_until
      where tr.enrollment_id = p_enrollment_id
        and tr.status = 'active'
        and tr.valid_until >= p_effective_on
        and t.started_at is null
        and t.status = 'scheduled' and p_now < t.confirmation_deadline
        and extract(isodow from t.service_date)::smallint = tr.weekday
        and not exists (
          select 1 from public.trip_passengers p
          where p.trip_id = t.id and p.enrollment_id = p_enrollment_id
        )
      order by t.id
    loop
      perform 1 from public.trips t where t.id = v_reservation.trip_id for update;
      insert into public.trip_passengers (
        fleet_id, trip_id, enrollment_id, student_id, school_id,
        confirmation_status
      ) values (
        v_enrollment.fleet_id, v_reservation.trip_id, p_enrollment_id,
        v_enrollment.student_id, v_enrollment.school_id,
        case when v_reservation.confirmation_deadline <= p_now
          then 'expired' else 'pending' end
      ) on conflict (trip_id, enrollment_id) do nothing;
      if found then
        select r.direction into v_route_direction
        from public.routes r
        where r.id = v_reservation.route_id and r.fleet_id = v_reservation.fleet_id;
        if not exists(select 1 from public.trip_stops where trip_id=v_reservation.trip_id
          and kind='home' and student_id=v_enrollment.student_id) then
          v_home_position := private.reserve_reconciled_stop_position(v_reservation.trip_id,'home');
          insert into public.trip_stops(fleet_id,trip_id,kind,student_id,position,address_snapshot,latitude,longitude)
          values(v_enrollment.fleet_id,v_reservation.trip_id,'home',v_enrollment.student_id,
            v_home_position,v_home_snapshot,v_student.latitude,v_student.longitude);
        end if;
        if not exists (
          select 1 from public.trip_stops s where s.trip_id = v_reservation.trip_id
            and s.kind = 'school' and s.school_id = v_enrollment.school_id
        ) then
          v_school_position := private.reserve_reconciled_stop_position(v_reservation.trip_id,'school',v_enrollment.school_id);
          select * into v_school from public.schools s where s.id = v_enrollment.school_id;
          insert into public.trip_stops (
            fleet_id, trip_id, kind, school_id, position, address_snapshot,
            latitude, longitude
          ) values (
            v_enrollment.fleet_id, v_reservation.trip_id, 'school', v_enrollment.school_id,
            v_school_position, jsonb_build_object(
              'name', v_school.name, 'street', v_school.street,
              'street_number', v_school.street_number,
              'neighborhood', v_school.neighborhood, 'city_name', v_school.city_name,
              'city_ibge_code', v_school.city_ibge_code, 'state_code', v_school.state_code
            ), v_school.latitude, v_school.longitude
          );
        end if;
        update public.trips set revision = revision + 1 where id = v_reservation.trip_id;
        perform private.append_trip_event(
          v_reservation.trip_id, extensions.gen_random_uuid(), 'trip_reconciled',
          jsonb_build_object('enrollment_id', p_enrollment_id, 'kind', p_kind,
            'effective_on', p_effective_on), p_now
        );
        v_count := v_count + 1;
      end if;
    end loop;
  end if;
  return v_count;
end;
$$;
