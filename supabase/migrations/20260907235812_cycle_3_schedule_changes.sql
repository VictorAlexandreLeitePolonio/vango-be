create or replace function public.request_schedule_change(
  p_enrollment_id uuid,
  p_directions text[],
  p_weekdays smallint[]
) returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_enrollment public.fleet_enrollments%rowtype;
  v_student public.students%rowtype;
  v_source_request public.fleet_join_requests%rowtype;
  v_request_id uuid;
  v_school_id uuid;
  v_shift text;
  v_directions text[];
  v_weekdays smallint[];
  v_constraint text;
begin
  if v_user_id is null then
    perform private.raise_api_error('unauthenticated', 'Authentication required', 401);
  end if;
  if not private.current_user_email_confirmed() then
    perform private.raise_api_error('email_unverified', 'Email confirmation required', 403);
  end if;

  perform private.lock_planning();
  select * into v_enrollment
  from public.fleet_enrollments e
  where e.id = p_enrollment_id
  for update;
  if not found then
    perform private.raise_api_error('not_found', 'Enrollment not found', 404);
  end if;
  if not private.has_fleet_role(v_enrollment.fleet_id, v_user_id, 'owner')
    and not private.can_manage_student(v_enrollment.student_id, v_user_id) then
    perform private.raise_api_error('not_found', 'Enrollment not found', 404);
  end if;
  if v_enrollment.status <> 'active' then
    perform private.raise_api_error('invalid_transition', 'Enrollment is no longer active', 409);
  end if;

  select * into v_student
  from public.students s
  where s.id = v_enrollment.student_id
  for update;
  if not found then
    perform private.raise_api_error('not_found', 'Student not found', 404);
  end if;
  select * into v_source_request
  from public.fleet_join_requests r
  where r.id = v_enrollment.source_request_id;
  v_school_id := coalesce(v_enrollment.school_id, v_source_request.school_id);
  v_shift := coalesce(v_enrollment.shift, v_source_request.shift);
  perform private.validate_request_preferences(v_shift, p_directions, p_weekdays);
  if v_school_id is null or not exists (
    select 1 from public.schools s
    join public.fleet_service_schools fss on fss.school_id = s.id
    where s.id = v_school_id and s.status = 'active'
      and fss.fleet_id = v_enrollment.fleet_id
  ) then
    perform private.raise_api_error('invalid_input', 'Enrollment school is not available', 400);
  end if;
  if exists (
    select 1 from public.fleet_join_requests r
    where r.fleet_id = v_enrollment.fleet_id
      and r.student_id = v_enrollment.student_id
      and r.status in ('pending', 'waitlisted')
  ) then
    perform private.raise_api_error('request_conflict', 'An open planning request already exists', 409);
  end if;

  select array_agg(direction order by direction) into v_directions
  from (select distinct direction from unnest(p_directions) direction) requested;
  select array_agg(day_value order by day_value) into v_weekdays
  from (select distinct day_value from unnest(p_weekdays) day_value) requested;
  insert into public.fleet_join_requests (
    fleet_id, requester_user_id, student_id, school_id, origin, shift,
    directions, weekdays, postal_code, street, street_number, address_complement,
    neighborhood, city_name, city_ibge_code, state_code, latitude, longitude,
    request_kind, enrollment_id
  ) values (
    v_enrollment.fleet_id, v_user_id, v_enrollment.student_id, v_school_id,
    'marketplace', v_shift, v_directions, v_weekdays, v_student.postal_code,
    v_student.street, v_student.street_number, v_student.address_complement,
    v_student.neighborhood, v_student.city_name, v_student.city_ibge_code,
    v_student.state_code, v_student.latitude, v_student.longitude, 'change',
    v_enrollment.id
  ) returning id into v_request_id;

  insert into public.audit_events (
    fleet_id, actor_user_id, action, entity_type, entity_id, metadata
  ) values (
    v_enrollment.fleet_id, v_user_id, 'join_request_changed', 'join_request', v_request_id,
    jsonb_build_object('request_kind', 'change', 'enrollment_id', v_enrollment.id,
      'directions', v_directions, 'weekdays', v_weekdays)
  );
  return v_request_id;
exception
  when unique_violation then
    get stacked diagnostics v_constraint = constraint_name;
    if v_constraint = 'fleet_join_requests_open_student_fleet_key' then
      perform private.raise_api_error('request_conflict', 'An open planning request already exists', 409);
    end if;
    raise;
end;
$$;

create or replace function private.next_change_date(
  p_request_id uuid,
  p_now timestamptz,
  p_allocations jsonb
) returns date
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_request public.fleet_join_requests%rowtype;
  v_date date;
  v_search_from date;
  v_search_until date;
  v_allocation jsonb;
  v_item jsonb;
  v_schedule public.route_schedules%rowtype;
  v_window record;
  v_old record;
  v_old_window record;
  v_open boolean;
  v_has_service boolean;
begin
  if p_request_id is null or p_now is null
    or p_allocations is null
    or jsonb_typeof(p_allocations) is distinct from 'array' then
    return null;
  end if;
  if exists (
    select 1
    from jsonb_array_elements(p_allocations) item
    where jsonb_typeof(item) is distinct from 'object'
      or jsonb_typeof(item->'schedule_id') is distinct from 'string'
      or item->>'schedule_id' !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      or jsonb_typeof(item->'weekday') is distinct from 'number'
      or item->>'weekday' !~ '^[1-7]$'
  ) then
    return null;
  end if;
  select * into v_request
  from public.fleet_join_requests r
  where r.id = p_request_id;
  if not found or v_request.status not in ('pending', 'waitlisted') then
    return null;
  end if;

  select max(greatest(rs.valid_from, (p_now at time zone rs.timezone)::date + 1)),
         min(rs.valid_until)
  into v_search_from, v_search_until
  from jsonb_array_elements(p_allocations) item
  join public.route_schedules rs
    on rs.id = (item->>'schedule_id')::uuid
   and rs.fleet_id = v_request.fleet_id
   and rs.status = 'active';
  if v_search_from is null or v_search_until is null then
    return null;
  end if;
  if v_search_from > v_search_until then
    return null;
  end if;

  -- Search the complete finite schedule intersection.  A change starts on a
  -- service date of either the new assignments or an old assignment that is
  -- being removed.  Including old weekdays is required when a direction/day
  -- is removed: its already-closed execution can still defer the whole swap.
  for v_date in
    select value::date
    from generate_series(v_search_from, v_search_until, interval '1 day') values(value)
    where extract(isodow from value)::smallint = any(v_request.weekdays)
       or (
         v_request.enrollment_id is not null
         and exists (
           select 1
           from public.route_student_schedules rss
           where rss.enrollment_id = v_request.enrollment_id
             and rss.status = 'active'
             and rss.valid_until >= value::date
             and rss.weekday = extract(isodow from value)::smallint
         )
       )
  loop
    v_allocation := p_allocations;
    v_open := true;
    v_has_service := false;
    for v_item in select value from jsonb_array_elements(v_allocation) loop
      select * into v_schedule
      from public.route_schedules rs
      where rs.id = (v_item->>'schedule_id')::uuid;
      select * into v_window
      from private.schedule_windows(v_schedule.id, v_date, v_schedule.valid_until)
        where extract(isodow from service_date)::smallint = (v_item->>'weekday')::smallint
        order by service_date
        limit 1;
      if not found then
        v_open := false;
        continue;
      end if;
      if v_window.service_date = v_date then
        v_has_service := true;
      end if;
      if p_now >= lower(v_window."window")
        - make_interval(mins => v_schedule.confirmation_minutes) then
        v_open := false;
      end if;
    end loop;
    if not v_open then
      continue;
    end if;

    -- A change also replaces the old recurring assignments.  Their first
    -- execution from the candidate effective date must still be open; this
    -- prevents dropping a direction whose deadline has already closed.
    if v_request.enrollment_id is not null then
      for v_old in
        select rss.schedule_id, rss.weekday, rss.valid_from, rss.valid_until
        from public.route_student_schedules rss
        where rss.enrollment_id = v_request.enrollment_id
          and rss.status = 'active'
          and rss.valid_until >= v_date
      loop
        select rs.* into v_schedule
        from public.route_schedules rs
        where rs.id = v_old.schedule_id;
        select * into v_old_window
        from private.schedule_windows(
          v_old.schedule_id,
          greatest(v_date, v_old.valid_from),
          least(v_old.valid_until, v_schedule.valid_until)
        )
        where extract(isodow from service_date)::smallint = v_old.weekday
          and service_date between v_old.valid_from and v_old.valid_until
        order by service_date
        limit 1;
        if found then
          if v_old_window.service_date = v_date then
            v_has_service := true;
          end if;
          if p_now >= lower(v_old_window."window")
            - make_interval(mins => v_schedule.confirmation_minutes) then
            v_open := false;
            exit;
          end if;
        end if;
      end loop;
    end if;
    if v_has_service and v_open then
      return v_date;
    end if;
  end loop;
  return null;
end;
$$;

-- The two-argument helper remains the read-only preview used by queue and UI
-- callers.  Approval calls the three-argument form below with the exact set
-- chosen by the owner, so a different allocation cannot bypass a closed
-- confirmation deadline.
create or replace function private.next_change_date(
  p_request_id uuid,
  p_now timestamptz
) returns date
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_allocation jsonb;
  v_effective_on date;
  v_search_from date;
  v_search_until date;
  v_change_date date;
begin
  if p_request_id is null or p_now is null then
    return null;
  end if;
  select min(greatest(rs.valid_from, (p_now at time zone rs.timezone)::date + 1)),
         max(rs.valid_until)
  into v_search_from, v_search_until
  from public.fleet_join_requests r
  join public.routes rt
    on rt.fleet_id = r.fleet_id
   and rt.direction = any(r.directions)
   and rt.shift = r.shift
   and rt.status = 'active'
  join public.route_schools rsch
    on rsch.fleet_id = rt.fleet_id
   and rsch.route_id = rt.id
   and rsch.school_id = r.school_id
  join public.route_schedules rs
    on rs.fleet_id = rt.fleet_id
   and rs.route_id = rt.id
   and rs.status = 'active'
  where r.id = p_request_id;
  if v_search_from is null or v_search_until is null
    or v_search_from > v_search_until then
    return null;
  end if;
  -- A direction can become serviceable later than another one. Search the
  -- complete finite intersection instead of testing only the earliest
  -- schedule boundary, which could be before a required direction exists.
  for v_effective_on in
    select value::date
    from generate_series(v_search_from, v_search_until, interval '1 day') values(value)
  loop
    v_allocation := private.find_request_allocation(p_request_id, v_effective_on);
    if v_allocation is not null then
      v_change_date := private.next_change_date(p_request_id, p_now, v_allocation);
      if v_change_date is not null then
        return v_change_date;
      end if;
    end if;
  end loop;
  return null;
end;
$$;

create or replace function public.update_enrollment_school(
  p_enrollment_id uuid,
  p_school_id uuid
) returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_enrollment public.fleet_enrollments%rowtype;
begin
  if v_user_id is null then
    perform private.raise_api_error('unauthenticated', 'Authentication required', 401);
  end if;
  if not private.current_user_email_confirmed() then
    perform private.raise_api_error('email_unverified', 'Email confirmation required', 403);
  end if;
  if p_school_id is null then
    perform private.raise_api_error('invalid_input', 'School is required', 400);
  end if;
  perform private.lock_planning();
  select * into v_enrollment
  from public.fleet_enrollments e
  where e.id = p_enrollment_id
  for update;
  if not found then
    perform private.raise_api_error('not_found', 'Enrollment not found', 404);
  end if;
  if not private.has_fleet_role(v_enrollment.fleet_id, v_user_id, 'owner')
    and not private.can_manage_student(v_enrollment.student_id, v_user_id) then
    perform private.raise_api_error('not_found', 'Enrollment not found', 404);
  end if;
  if v_enrollment.status <> 'active' then
    perform private.raise_api_error('invalid_transition', 'Enrollment is no longer active', 409);
  end if;
  if not exists (
    select 1 from public.schools s
    join public.fleet_service_schools fss on fss.school_id = s.id
    where s.id = p_school_id and s.status = 'active'
      and fss.fleet_id = v_enrollment.fleet_id
  ) then
    perform private.raise_api_error('not_found', 'School not found', 404);
  end if;
  if v_enrollment.school_id is distinct from p_school_id then
    update public.fleet_enrollments
    set school_id = p_school_id, routing_revision = routing_revision + 1
    where id = p_enrollment_id;
    insert into public.audit_events (
      fleet_id, actor_user_id, action, entity_type, entity_id, metadata
    ) values (
      v_enrollment.fleet_id, v_user_id, 'enrollment_school_updated', 'enrollment',
      p_enrollment_id, jsonb_build_object('changed_fields', jsonb_build_array('school_id'))
    );
  end if;
  return p_enrollment_id;
end;
$$;

create or replace function public.end_fleet_enrollment(
  p_enrollment_id uuid,
  p_reason text
) returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_enrollment public.fleet_enrollments%rowtype;
  v_membership record;
begin
  if v_user_id is null then
    perform private.raise_api_error('unauthenticated', 'Authentication required', 401);
  end if;
  if not private.current_user_email_confirmed() then
    perform private.raise_api_error('email_unverified', 'Email confirmation required', 403);
  end if;
  if p_reason is null or btrim(p_reason) = '' or char_length(btrim(p_reason)) > 500 then
    perform private.raise_api_error('invalid_input', 'A reason of up to 500 characters is required', 400);
  end if;
  perform private.lock_planning();
  select * into v_enrollment
  from public.fleet_enrollments e
  where e.id = p_enrollment_id
  for update;
  if not found then
    perform private.raise_api_error('not_found', 'Enrollment not found', 404);
  end if;
  if not private.has_fleet_role(v_enrollment.fleet_id, v_user_id, 'owner')
    and not private.can_manage_student(v_enrollment.student_id, v_user_id) then
    perform private.raise_api_error('not_found', 'Enrollment not found', 404);
  end if;
  if v_enrollment.status <> 'active' then
    perform private.raise_api_error('invalid_transition', 'Enrollment is no longer active', 409);
  end if;

  update public.fleet_enrollments
  set status = 'ended', ended_at = clock_timestamp(), ended_by = v_user_id,
      end_reason = btrim(p_reason)
  where id = p_enrollment_id;
  update public.fleet_join_requests
  set status = 'cancelled', decided_by = v_user_id, decided_at = clock_timestamp()
  where enrollment_id = p_enrollment_id and status in ('pending', 'waitlisted');
  update public.transport_reservations
  set status = 'cancelled', cancelled_at = clock_timestamp(),
      cancellation_reason = btrim(p_reason)
  where enrollment_id = p_enrollment_id and status = 'active'
    and valid_until >= current_date;
  update public.route_student_schedules
  set status = 'cancelled', cancelled_at = clock_timestamp(),
      cancellation_reason = btrim(p_reason)
  where enrollment_id = p_enrollment_id and status = 'active'
    and valid_until >= current_date;

  for v_membership in
    select distinct sources.membership_id
    from public.fleet_membership_role_sources sources
    where sources.enrollment_id = p_enrollment_id
  loop
    delete from public.fleet_membership_role_sources
    where membership_id = v_membership.membership_id
      and enrollment_id = p_enrollment_id;
    perform private.sync_effective_membership_roles(v_membership.membership_id);
  end loop;

  insert into public.audit_events (
    fleet_id, actor_user_id, action, entity_type, entity_id, metadata
  ) values (
    v_enrollment.fleet_id, v_user_id, 'enrollment_ended', 'enrollment', p_enrollment_id,
    jsonb_build_object('student_id', v_enrollment.student_id, 'reason_recorded', true)
  );
  return 'ended';
end;
$$;

create or replace function public.update_student(
  p_student_id uuid,
  p_full_name text,
  p_birth_date date,
  p_postal_code text,
  p_street text,
  p_street_number text,
  p_address_complement text,
  p_neighborhood text,
  p_city_name text,
  p_city_ibge_code text,
  p_state_code text,
  p_latitude numeric,
  p_longitude numeric
) returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_student public.students%rowtype;
  v_changed_fields text[];
  v_address_changed boolean := false;
begin
  if v_user_id is null then
    perform private.raise_api_error('unauthenticated', 'Authentication required', 401);
  end if;
  if not private.current_user_email_confirmed() then
    perform private.raise_api_error('email_unverified', 'Email confirmation required', 403);
  end if;
  perform private.validate_student_fields(
    p_full_name, p_birth_date, p_postal_code, p_street, p_street_number,
    p_address_complement, p_neighborhood, p_city_name, p_city_ibge_code,
    p_state_code, p_latitude, p_longitude
  );
  perform private.lock_planning();
  select * into v_student from public.students where id = p_student_id for update;
  if not found then
    perform private.raise_api_error('not_found', 'Student not found', 404);
  end if;
  if not private.can_manage_student(p_student_id, v_user_id) then
    perform private.raise_api_error('forbidden', 'Student management permission required', 403);
  end if;
  if v_student.student_type = 'minor' and age(current_date, p_birth_date) >= interval '18 years' then
    perform private.raise_api_error('student_conflict', 'Minor must be under eighteen', 409);
  end if;
  if v_student.student_type = 'adult' and age(current_date, p_birth_date) < interval '18 years' then
    perform private.raise_api_error('student_conflict', 'Adult must be eighteen or older', 409);
  end if;

  v_changed_fields := array_remove(array[
    case when v_student.full_name is distinct from btrim(p_full_name) then 'full_name' end,
    case when v_student.birth_date is distinct from p_birth_date then 'birth_date' end,
    case when v_student.postal_code is distinct from btrim(p_postal_code) then 'postal_code' end,
    case when v_student.street is distinct from btrim(p_street) then 'street' end,
    case when v_student.street_number is distinct from btrim(p_street_number) then 'street_number' end,
    case when v_student.address_complement is distinct from nullif(btrim(p_address_complement), '') then 'address_complement' end,
    case when v_student.neighborhood is distinct from btrim(p_neighborhood) then 'neighborhood' end,
    case when v_student.city_name is distinct from btrim(p_city_name) then 'city_name' end,
    case when v_student.city_ibge_code is distinct from p_city_ibge_code then 'city_ibge_code' end,
    case when v_student.state_code is distinct from p_state_code then 'state_code' end,
    case when v_student.latitude is distinct from p_latitude then 'latitude' end,
    case when v_student.longitude is distinct from p_longitude then 'longitude' end
  ], null);
  v_address_changed := coalesce(v_changed_fields && array[
    'postal_code', 'street', 'street_number', 'address_complement', 'neighborhood',
    'city_name', 'city_ibge_code', 'state_code', 'latitude', 'longitude'
  ], false);

  update public.students
  set full_name = btrim(p_full_name), birth_date = p_birth_date,
      postal_code = btrim(p_postal_code), street = btrim(p_street),
      street_number = btrim(p_street_number),
      address_complement = nullif(btrim(p_address_complement), ''),
      neighborhood = btrim(p_neighborhood), city_name = btrim(p_city_name),
      city_ibge_code = p_city_ibge_code, state_code = p_state_code,
      latitude = p_latitude, longitude = p_longitude
  where id = p_student_id;

  if v_address_changed then
    update public.fleet_enrollments
    set routing_revision = routing_revision + 1
    where student_id = p_student_id and status = 'active';
  end if;
  if cardinality(v_changed_fields) > 0 then
    insert into public.audit_events (
      fleet_id, actor_user_id, action, entity_type, entity_id, metadata
    )
    select e.fleet_id, v_user_id, 'student_updated', 'student', p_student_id,
      jsonb_build_object('changed_fields', to_jsonb(v_changed_fields),
        'routing_revision_incremented', v_address_changed)
    from public.fleet_enrollments e
    where e.student_id = p_student_id and e.status = 'active';
  end if;
  return p_student_id;
end;
$$;

revoke execute on function private.next_change_date(uuid, timestamptz) from public, anon, authenticated;
revoke execute on function private.next_change_date(uuid, timestamptz, jsonb) from public, anon, authenticated;
grant execute on function private.next_change_date(uuid, timestamptz) to postgres;
grant execute on function private.next_change_date(uuid, timestamptz, jsonb) to postgres;
revoke execute on function public.request_schedule_change(uuid, text[], smallint[]) from public, anon;
revoke execute on function public.update_enrollment_school(uuid, uuid) from public, anon;
revoke execute on function public.end_fleet_enrollment(uuid, text) from public, anon;
revoke execute on function public.update_student(uuid, text, date, text, text, text, text, text, text, text, text, numeric, numeric) from public, anon;
grant execute on function public.request_schedule_change(uuid, text[], smallint[]) to authenticated;
grant execute on function public.update_enrollment_school(uuid, uuid) to authenticated;
grant execute on function public.end_fleet_enrollment(uuid, text) to authenticated;
grant execute on function public.update_student(uuid, text, date, text, text, text, text, text, text, text, text, numeric, numeric) to authenticated;
