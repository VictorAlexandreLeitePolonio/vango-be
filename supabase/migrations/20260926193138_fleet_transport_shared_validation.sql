-- Canonicalize explicit day/direction pairs without manufacturing a Cartesian product.
create or replace function private.normalize_fleet_transport_allocations(p_allocations jsonb)
returns jsonb language plpgsql volatile set search_path = '' as $$
declare
  v_item jsonb;
  v_id uuid;
  v_day integer;
  v_result jsonb := '[]'::jsonb;
begin
  if jsonb_typeof(p_allocations) is distinct from 'array' then
    perform private.raise_api_error('invalid_input', 'Allocations must be an array', 400);
  end if;
  if jsonb_array_length(p_allocations) not between 1 and 14 then
    perform private.raise_api_error('invalid_input', 'One to fourteen explicit pairs are required', 400);
  end if;
  for v_item in select value from jsonb_array_elements(p_allocations) loop
    if jsonb_typeof(v_item) is distinct from 'object'
      or not (v_item ?& array['schedule_id','weekday','direction'])
      or v_item - array['schedule_id','weekday','direction'] <> '{}'::jsonb
      or jsonb_typeof(v_item->'schedule_id') is distinct from 'string'
      or jsonb_typeof(v_item->'weekday') is distinct from 'number'
      or jsonb_typeof(v_item->'direction') is distinct from 'string'
      or v_item->>'direction' not in ('going','return') then
      perform private.raise_api_error('invalid_input', 'Invalid allocation item', 400);
    end if;
    begin
      v_id := (v_item->>'schedule_id')::uuid;
      if (v_item->>'weekday')::numeric <> trunc((v_item->>'weekday')::numeric) then
        perform private.raise_api_error('invalid_input', 'Weekday must be an integer', 400);
      end if;
      v_day := (v_item->>'weekday')::integer;
    exception when invalid_text_representation or numeric_value_out_of_range then
      perform private.raise_api_error('invalid_input', 'Invalid allocation identifier or weekday', 400);
    end;
    if v_day not between 1 and 7 or exists (
      select 1 from jsonb_array_elements(v_result) chosen
      where (chosen->>'weekday')::integer = v_day
        and chosen->>'direction' = v_item->>'direction'
    ) then
      perform private.raise_api_error('invalid_input', 'Each valid weekday and direction must occur once', 400);
    end if;
    v_result := v_result || jsonb_build_array(jsonb_build_object(
      'schedule_id', v_id, 'weekday', v_day, 'direction', v_item->>'direction'));
  end loop;
  return (select jsonb_agg(value order by (value->>'weekday')::integer,
                          value->>'direction', value->>'schedule_id')
          from jsonb_array_elements(v_result));
end;
$$;
revoke execute on function private.normalize_fleet_transport_allocations(jsonb) from public, anon, authenticated;
grant execute on function private.normalize_fleet_transport_allocations(jsonb) to postgres;

-- Shared domain validation holds the planning lock through the caller's transaction.
create or replace function private.validate_transport_allocations(
  p_fleet_id uuid, p_student_id uuid, p_enrollment_id uuid, p_school_id uuid,
  p_shift text, p_allocations jsonb, p_effective_on date
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_alloc jsonb;
  v_schedule public.route_schedules%rowtype;
  v_route public.routes%rowtype;
  v_van public.vans%rowtype;
  v_schedule_id uuid;
  v_weekday smallint;
  v_direction text;
  v_selected jsonb := '[]'::jsonb;
begin
  perform private.lock_planning();
  if jsonb_typeof(p_allocations) is distinct from 'array'
    or p_effective_on is null or not isfinite(p_effective_on) then
    perform private.raise_api_error('invalid_input', 'Allocations and a finite date are required', 400);
  end if;
  if jsonb_array_length(p_allocations) = 0 then
    perform private.raise_api_error('invalid_input', 'Allocations cannot be empty', 400);
  end if;
  for v_alloc in select value from jsonb_array_elements(p_allocations) loop
    if jsonb_typeof(v_alloc) is distinct from 'object'
      or jsonb_typeof(v_alloc->'schedule_id') is distinct from 'string'
      or jsonb_typeof(v_alloc->'weekday') is distinct from 'number' then
      perform private.raise_api_error('invalid_input', 'Invalid allocation item', 400);
    end if;
    begin
      v_schedule_id := (v_alloc->>'schedule_id')::uuid;
      v_weekday := (v_alloc->>'weekday')::smallint;
    exception when others then
      perform private.raise_api_error('invalid_input', 'Invalid allocation item', 400);
    end;
    if v_schedule_id is null or v_weekday is null
      or v_weekday not between 1 and 7
      or (v_alloc->>'weekday')::numeric <> v_weekday
      or ((v_alloc ? 'direction') and v_alloc->>'direction' is null) then
      perform private.raise_api_error('invalid_input', 'Invalid allocation item', 400);
    end if;
    select rs.* into v_schedule
    from public.route_schedules rs
    where rs.id = v_schedule_id and rs.fleet_id = p_fleet_id
      and rs.status = 'active' and v_weekday = any(rs.weekdays)
      and p_effective_on between rs.valid_from and rs.valid_until
    for update;
    if not found then perform private.raise_api_error('invalid_input', 'Allocation schedule is not available', 400); end if;
    select r.* into v_route
    from public.routes r
    join public.route_schools rsch on rsch.route_id = r.id and rsch.fleet_id = r.fleet_id
    where r.id = v_schedule.route_id and r.fleet_id = p_fleet_id
      and r.shift = p_shift and r.status = 'active'
      and rsch.school_id = p_school_id;
    if not found then perform private.raise_api_error('invalid_input', 'Allocation route does not meet request', 400); end if;
    if not private.has_fleet_role(p_fleet_id, v_route.driver_user_id, 'driver') then
      perform private.raise_api_error('invalid_input', 'Route driver is not active', 400);
    end if;
    v_direction := v_route.direction;
    if (v_alloc ? 'direction') and v_alloc->>'direction' is distinct from v_direction then
      perform private.raise_api_error('invalid_input', 'Allocation direction does not match route', 400);
    end if;
    if exists (
      select 1 from jsonb_array_elements(v_selected) chosen(value)
      where chosen.value->>'direction' = v_direction
        and (chosen.value->>'weekday')::smallint = v_weekday
    ) then
      perform private.raise_api_error('invalid_input', 'Each requested direction and weekday must be allocated once', 400);
    end if;
    select * into v_van from public.vans v
    where v.id = v_route.van_id and v.fleet_id = p_fleet_id and v.status = 'active'
    for update;
    if not found then perform private.raise_api_error('not_found', 'Vehicle not found', 404); end if;
    if not private.reservation_has_capacity(
      v_schedule.id, v_weekday, p_effective_on, v_van.capacity, p_enrollment_id
    ) then
      perform private.raise_api_error('capacity_exceeded', 'No seats remain for the requested execution', 409);
    end if;
    if private.student_schedule_conflicts(
      p_student_id, v_schedule.id, v_weekday,
      p_effective_on, p_enrollment_id
    ) then
      perform private.raise_api_error('schedule_conflict', 'Student has a conflicting reservation', 409);
    end if;
    if private.allocation_set_conflicts(
      v_selected, v_schedule.id, v_weekday, p_effective_on
    ) then
      perform private.raise_api_error('schedule_conflict', 'Allocations conflict with each other', 409);
    end if;
    v_selected := v_selected || jsonb_build_array(jsonb_build_object(
      'schedule_id', v_schedule.id, 'weekday', v_weekday, 'direction', v_direction
    ));
  end loop;
  return v_selected;
end;
$$;
revoke execute on function private.validate_transport_allocations(uuid,uuid,uuid,uuid,text,jsonb,date) from public, anon, authenticated;
grant execute on function private.validate_transport_allocations(uuid,uuid,uuid,uuid,text,jsonb,date) to postgres;

create or replace function private.apply_request_allocation(
  p_request_id uuid,
  p_allocations jsonb,
  p_effective_on date
) returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_request public.fleet_join_requests%rowtype;
  v_student public.students%rowtype;
  v_alloc jsonb;
  v_schedule public.route_schedules%rowtype;
  v_route public.routes%rowtype;
  v_enrollment_id uuid;
  v_rss_id uuid;
  v_schedule_id uuid;
  v_weekday smallint;
  v_direction text;
  v_expected integer;
  v_seen integer := 0;
  v_selected jsonb := '[]'::jsonb;
  v_guardian record;
  v_constraint text;
begin
  perform private.lock_planning();
  if p_allocations is null or jsonb_typeof(p_allocations) is distinct from 'array'
    or p_effective_on is null or not isfinite(p_effective_on) then
    perform private.raise_api_error('invalid_input', 'Complete allocation and effective date are required', 400);
  end if;
  select * into v_request from public.fleet_join_requests
  where id = p_request_id for update;
  if not found then perform private.raise_api_error('not_found', 'Request not found', 404); end if;
  if v_request.status not in ('pending', 'waitlisted') then
    perform private.raise_api_error('invalid_transition', 'Request is no longer open', 409);
  end if;
  if p_effective_on < current_date then
    perform private.raise_api_error('invalid_input', 'Effective date cannot be in the past', 400);
  end if;
  if v_request.request_kind = 'new' and v_request.enrollment_id is not null then
    perform private.raise_api_error('invalid_input', 'Initial request cannot reference enrollment', 400);
  end if;

  v_expected := cardinality(v_request.directions) * cardinality(v_request.weekdays);
  if jsonb_array_length(p_allocations) <> v_expected then
    perform private.raise_api_error('allocation_required', 'Every requested day and direction needs an allocation', 409);
  end if;
  select * into v_student from public.students s where s.id = v_request.student_id for update;
  if not found then perform private.raise_api_error('not_found', 'Student not found', 404); end if;

  v_selected := private.validate_transport_allocations(
    v_request.fleet_id, v_request.student_id, v_request.enrollment_id,
    v_request.school_id, v_request.shift, p_allocations, p_effective_on);
  for v_alloc in select value from jsonb_array_elements(v_selected) loop
    if not (v_alloc->>'direction' = any(v_request.directions))
      or not ((v_alloc->>'weekday')::smallint = any(v_request.weekdays)) then
      perform private.raise_api_error('invalid_input', 'Allocation pair was not requested', 400);
    end if;
    v_seen := v_seen + 1;
  end loop;
  if v_seen <> v_expected then
    perform private.raise_api_error('allocation_required', 'Every requested day and direction needs an allocation', 409);
  end if;

  if v_request.request_kind = 'new' then
    if exists (
      select 1 from public.fleet_enrollments e
      where e.fleet_id = v_request.fleet_id and e.student_id = v_request.student_id and e.status = 'active'
    ) then
      perform private.raise_api_error('enrollment_conflict', 'Student is already enrolled in this fleet', 409);
    end if;
    insert into public.fleet_enrollments (
      fleet_id, student_id, source_request_id, school_id, shift
    ) values (
      v_request.fleet_id, v_request.student_id, v_request.id, v_request.school_id, v_request.shift
    ) returning id into v_enrollment_id;
    if v_student.student_type = 'adult' then
      perform private.ensure_enrollment_membership(
        v_request.fleet_id, v_student.profile_id, 'student', v_enrollment_id
      );
    else
      for v_guardian in
        select sg.guardian_user_id
        from public.student_guardians sg
        where sg.student_id = v_student.id and sg.status = 'active'
        order by sg.guardian_user_id
      loop
        perform private.ensure_enrollment_membership(
          v_request.fleet_id, v_guardian.guardian_user_id, 'guardian', v_enrollment_id
        );
      end loop;
    end if;
  else
    v_enrollment_id := v_request.enrollment_id;
    if v_enrollment_id is null then
      perform private.raise_api_error('invalid_input', 'Change request requires an enrollment', 400);
    end if;
    perform 1
    from public.fleet_enrollments e
    where e.id = v_enrollment_id and e.fleet_id = v_request.fleet_id and e.status = 'active'
    for update;
    if not found then perform private.raise_api_error('not_found', 'Enrollment not found', 404); end if;
    update public.route_student_schedules
    set valid_until = p_effective_on - 1
    where enrollment_id = v_enrollment_id and status = 'active'
      and valid_from < p_effective_on and valid_until >= p_effective_on;
    update public.route_student_schedules
    set status = 'cancelled', cancelled_at = clock_timestamp(),
        cancellation_reason = 'superseded by approved schedule change'
    where enrollment_id = v_enrollment_id and status = 'active'
      and valid_from >= p_effective_on;
    update public.transport_reservations
    set valid_until = p_effective_on - 1
    where enrollment_id = v_enrollment_id and status = 'active'
      and valid_from < p_effective_on and valid_until >= p_effective_on;
    update public.transport_reservations
    set status = 'cancelled', cancelled_at = clock_timestamp(),
        cancellation_reason = 'superseded by approved schedule change'
    where enrollment_id = v_enrollment_id and status = 'active' and valid_from >= p_effective_on;
  end if;

  for v_alloc in select value from jsonb_array_elements(v_selected) loop
    v_schedule_id := (v_alloc->>'schedule_id')::uuid;
    v_weekday := (v_alloc->>'weekday')::smallint;
    v_direction := v_alloc->>'direction';
    select rs.* into v_schedule from public.route_schedules rs
    where rs.id = v_schedule_id and rs.fleet_id = v_request.fleet_id;
    select r.* into v_route from public.routes r
    where r.id = v_schedule.route_id and r.fleet_id = v_request.fleet_id;
    insert into public.route_student_schedules (
      fleet_id, enrollment_id, route_id, schedule_id, weekday, direction, valid_from, valid_until
    ) values (
      v_request.fleet_id, v_enrollment_id, v_route.id, v_schedule.id, v_weekday,
      v_direction, p_effective_on, v_schedule.valid_until
    ) returning id into v_rss_id;
    insert into public.transport_reservations (
      fleet_id, enrollment_id, student_id, route_student_schedule_id, route_id,
      schedule_id, van_id, weekday, direction, valid_from, valid_until
    ) values (
      v_request.fleet_id, v_enrollment_id, v_request.student_id, v_rss_id, v_route.id,
      v_schedule.id, v_route.van_id, v_weekday, v_direction, p_effective_on, v_schedule.valid_until
    );
  end loop;

  update public.fleet_join_requests
  set status = 'approved', enrollment_id = v_enrollment_id, effective_on = p_effective_on,
      decided_by = auth.uid(), decided_at = clock_timestamp()
  where id = p_request_id;
  insert into public.audit_events (
    fleet_id, actor_user_id, action, entity_type, entity_id, metadata
  ) values (
    v_request.fleet_id, auth.uid(), 'join_request_approved', 'join_request', p_request_id,
    jsonb_build_object('enrollment_id', v_enrollment_id, 'allocation_count', v_expected,
      'effective_on', p_effective_on)
  );
  return v_enrollment_id;
exception
  when unique_violation then
    get stacked diagnostics v_constraint = constraint_name;
    if v_constraint in ('fleet_enrollments_active_student_fleet_key',
      'fleet_enrollments_source_request_unique', 'route_student_schedules_fleet_id_id_key') then
      perform private.raise_api_error('enrollment_conflict', 'Student already has an active enrollment', 409);
    end if;
    raise;
end;
$$;
create or replace function private.reservation_has_capacity(
  p_schedule_id uuid,
  p_weekday smallint,
  p_effective_on date,
  p_capacity integer,
  p_exclude_enrollment_id uuid default null
) returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_candidate record;
  v_candidate_van_id uuid;
  v_reserved integer;
  v_seen boolean := false;
begin
  if p_capacity is null or p_capacity < 1 then
    return false;
  end if;
  select r.van_id into v_candidate_van_id
  from public.route_schedules rs
  join public.routes r on r.id = rs.route_id and r.fleet_id = rs.fleet_id
  where rs.id = p_schedule_id;
  if v_candidate_van_id is null then
    return false;
  end if;

  -- Capacity is per physical execution: every reservation using the same van
  -- must be compared by its real window, including schedules in another route.
  for v_candidate in
    select service_date, "window"
    from private.schedule_windows(p_schedule_id, p_effective_on, null)
    where extract(isodow from service_date)::smallint = p_weekday
  loop
    v_seen := true;
    select count(distinct tr.id)::integer into v_reserved
    from public.transport_reservations tr
    join public.routes existing_route
      on existing_route.id = tr.route_id and existing_route.fleet_id = tr.fleet_id
    join public.route_schedules existing_schedule
      on existing_schedule.id = tr.schedule_id
     and existing_schedule.fleet_id = tr.fleet_id
    join lateral private.schedule_windows(
      existing_schedule.id,
      v_candidate.service_date - 1,
      v_candidate.service_date + 1
    ) existing_window on true
    where existing_route.van_id = v_candidate_van_id
      and tr.status = 'active'
      and tr.valid_from <= v_candidate.service_date + 1
      and tr.valid_until >= v_candidate.service_date - 1
      and existing_window.service_date between tr.valid_from and tr.valid_until
      and extract(isodow from existing_window.service_date)::smallint = tr.weekday
      and existing_window."window" && v_candidate."window"
      and (p_exclude_enrollment_id is null or tr.enrollment_id <> p_exclude_enrollment_id
        or existing_window.service_date < p_effective_on);
    if v_reserved >= p_capacity then
      return false;
    end if;
  end loop;
  return v_seen;
end;
$$;

create or replace function private.student_schedule_conflicts(
  p_student_id uuid,
  p_schedule_id uuid,
  p_weekday smallint,
  p_effective_on date,
  p_exclude_enrollment_id uuid default null
) returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_candidate public.route_schedules%rowtype;
  v_existing record;
  v_from date;
  v_until date;
begin
  select rs.* into v_candidate from public.route_schedules rs where rs.id = p_schedule_id;
  if not found then return true; end if;
  for v_existing in
    select tr.enrollment_id, tr.schedule_id, tr.fleet_id, tr.weekday, tr.valid_from, tr.valid_until
    from public.transport_reservations tr
    where tr.student_id = p_student_id
      and tr.status = 'active'
      and tr.valid_until >= p_effective_on - 1

  loop
    v_from := greatest(p_effective_on, v_existing.valid_from, v_candidate.valid_from) - 1;
    v_until := least(v_existing.valid_until, v_candidate.valid_until) + 1;
    if v_from <= v_until and exists (
      select 1
      from private.schedule_windows(v_candidate.id, v_from, v_until) left_window
      join private.schedule_windows(v_existing.schedule_id, v_from, v_until) right_window
        on left_window."window" && right_window."window"
      where extract(isodow from left_window.service_date)::smallint = p_weekday
        and extract(isodow from right_window.service_date)::smallint = v_existing.weekday
        and left_window.service_date >= p_effective_on
        and left_window.service_date between v_candidate.valid_from and v_candidate.valid_until
        and right_window.service_date between v_existing.valid_from and v_existing.valid_until
        and (p_exclude_enrollment_id is null or v_existing.enrollment_id <> p_exclude_enrollment_id
          or right_window.service_date < p_effective_on)
    ) then
      return true;
    end if;
  end loop;
  return false;
end;
$$;
