create function public.submit_fleet_join_request(
  p_fleet_id uuid,
  p_student_id uuid,
  p_school_id uuid,
  p_shift text,
  p_directions text[],
  p_weekdays smallint[]
) returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_fleet_status text;
  v_student public.students%rowtype;
  v_school public.schools%rowtype;
  v_request_id uuid;
  v_directions text[];
  v_weekdays smallint[];
begin
  if v_user_id is null then
    perform private.raise_api_error('unauthenticated', 'Authentication required', 401);
  end if;
  if not private.current_user_email_confirmed() then
    perform private.raise_api_error('email_unverified', 'Email confirmation required', 403);
  end if;
  perform private.validate_request_preferences(p_shift, p_directions, p_weekdays);

  select f.status into v_fleet_status
  from public.fleets f
  where f.id = p_fleet_id
  for update;
  if not found then
    perform private.raise_api_error('not_found', 'Fleet not found', 404);
  end if;
  if v_fleet_status <> 'published' then
    perform private.raise_api_error('invalid_transition', 'Fleet is not accepting requests', 409);
  end if;

  select * into v_student
  from public.students s
  where s.id = p_student_id
  for update;
  if not found then
    perform private.raise_api_error('not_found', 'Student not found', 404);
  end if;
  if not private.can_manage_student(p_student_id, v_user_id) then
    perform private.raise_api_error('forbidden', 'Student management permission required', 403);
  end if;

  select * into v_school
  from public.schools s
  where s.id = p_school_id
  for update;
  if not found or v_school.status <> 'active' then
    perform private.raise_api_error('not_found', 'School not found', 404);
  end if;
  if not exists (
    select 1 from public.fleet_service_schools fss
    where fss.fleet_id = p_fleet_id and fss.school_id = p_school_id
  ) or not exists (
    select 1 from public.fleet_service_cities fsc
    where fsc.fleet_id = p_fleet_id and fsc.city_ibge_code = v_student.city_ibge_code
  ) then
    perform private.raise_api_error('invalid_input', 'Fleet does not cover the school and student city', 400);
  end if;
  if exists (
    select 1 from public.fleet_enrollments fe
    where fe.fleet_id = p_fleet_id and fe.student_id = p_student_id and fe.status = 'active'
  ) then
    perform private.raise_api_error('enrollment_conflict', 'Student is already enrolled in this fleet', 409);
  end if;
  if exists (
    select 1 from public.fleet_join_requests r
    where r.fleet_id = p_fleet_id and r.student_id = p_student_id and r.status = 'pending'
  ) then
    perform private.raise_api_error('request_conflict', 'A pending request already exists', 409);
  end if;

  select array_agg(direction order by direction)
  into v_directions
  from (select distinct direction from unnest(p_directions) direction) directions;
  select array_agg(day_value order by day_value)
  into v_weekdays
  from (select distinct day_value from unnest(p_weekdays) day_value) weekdays;

  insert into public.fleet_join_requests (
    fleet_id, requester_user_id, student_id, school_id, origin, shift,
    directions, weekdays, postal_code, street, street_number,
    address_complement, neighborhood, city_name, city_ibge_code, state_code,
    latitude, longitude
  ) values (
    p_fleet_id, v_user_id, p_student_id, p_school_id, 'marketplace', p_shift,
    v_directions, v_weekdays, v_student.postal_code, v_student.street,
    v_student.street_number, v_student.address_complement, v_student.neighborhood,
    v_student.city_name, v_student.city_ibge_code, v_student.state_code,
    v_student.latitude, v_student.longitude
  ) returning id into v_request_id;

  insert into public.audit_events (
    fleet_id, actor_user_id, action, entity_type, entity_id, metadata
  ) values (
    p_fleet_id, v_user_id, 'join_request_created', 'join_request', v_request_id,
    jsonb_build_object(
      'student_id', p_student_id,
      'school_id', p_school_id,
      'origin', 'marketplace',
      'shift', p_shift,
      'directions', to_jsonb(v_directions),
      'weekdays', to_jsonb(v_weekdays)
    )
  );

  return v_request_id;
exception
  when unique_violation then
    perform private.raise_api_error('request_conflict', 'A pending request already exists', 409);
    return null;
end;
$$;

create function public.cancel_fleet_join_request(p_request_id uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_request public.fleet_join_requests%rowtype;
begin
  if v_user_id is null then
    perform private.raise_api_error('unauthenticated', 'Authentication required', 401);
  end if;
  if not private.current_user_email_confirmed() then
    perform private.raise_api_error('email_unverified', 'Email confirmation required', 403);
  end if;

  select * into v_request
  from public.fleet_join_requests r
  where r.id = p_request_id and r.requester_user_id = v_user_id
  for update;
  if not found then
    perform private.raise_api_error('not_found', 'Request not found', 404);
  end if;
  if v_request.status <> 'pending' then
    perform private.raise_api_error('invalid_transition', 'Request is no longer pending', 409);
  end if;

  update public.fleet_join_requests
  set status = 'cancelled', decided_by = v_user_id, decided_at = clock_timestamp()
  where id = p_request_id;

  insert into public.audit_events (
    fleet_id, actor_user_id, action, entity_type, entity_id, metadata
  ) values (
    v_request.fleet_id, v_user_id, 'join_request_cancelled', 'join_request', p_request_id,
    jsonb_build_object('student_id', v_request.student_id)
  );
  return 'cancelled';
end;
$$;

create function public.list_fleet_join_requests(
  p_fleet_id uuid,
  p_status text,
  p_limit integer,
  p_offset integer
) returns table (
  id uuid,
  student_id uuid,
  student_full_name text,
  school_id uuid,
  school_name text,
  origin text,
  status text,
  shift text,
  directions text[],
  weekdays smallint[],
  postal_code text,
  street text,
  street_number text,
  address_complement text,
  neighborhood text,
  city_name text,
  city_ibge_code text,
  state_code text,
  latitude numeric,
  longitude numeric,
  created_at timestamptz,
  decided_at timestamptz
)
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  if p_limit is null or p_limit < 1 or p_limit > 50 or p_offset is null or p_offset < 0 then
    perform private.raise_api_error('invalid_input', 'Invalid pagination', 400);
  end if;
  if p_status is not null and p_status not in ('pending', 'approved', 'rejected', 'cancelled') then
    perform private.raise_api_error('invalid_input', 'Invalid request status', 400);
  end if;
  if not private.has_fleet_role(p_fleet_id, auth.uid(), 'owner') then
    perform private.raise_api_error('not_found', 'Fleet not found', 404);
  end if;

  return query
  select r.id,
         r.student_id,
         s.full_name,
         r.school_id,
         school.name,
         r.origin,
         r.status,
         r.shift,
         r.directions,
         r.weekdays,
         case when r.status = 'pending' or exists (
           select 1 from public.fleet_enrollments e
           where e.source_request_id = r.id and e.status = 'active'
         ) then r.postal_code end,
         case when r.status = 'pending' or exists (
           select 1 from public.fleet_enrollments e
           where e.source_request_id = r.id and e.status = 'active'
         ) then r.street end,
         case when r.status = 'pending' or exists (
           select 1 from public.fleet_enrollments e
           where e.source_request_id = r.id and e.status = 'active'
         ) then r.street_number end,
         case when r.status = 'pending' or exists (
           select 1 from public.fleet_enrollments e
           where e.source_request_id = r.id and e.status = 'active'
         ) then r.address_complement end,
         case when r.status = 'pending' or exists (
           select 1 from public.fleet_enrollments e
           where e.source_request_id = r.id and e.status = 'active'
         ) then r.neighborhood end,
         case when r.status = 'pending' or exists (
           select 1 from public.fleet_enrollments e
           where e.source_request_id = r.id and e.status = 'active'
         ) then r.city_name end,
         case when r.status = 'pending' or exists (
           select 1 from public.fleet_enrollments e
           where e.source_request_id = r.id and e.status = 'active'
         ) then r.city_ibge_code end,
         case when r.status = 'pending' or exists (
           select 1 from public.fleet_enrollments e
           where e.source_request_id = r.id and e.status = 'active'
         ) then r.state_code end,
         case when r.status = 'pending' or exists (
           select 1 from public.fleet_enrollments e
           where e.source_request_id = r.id and e.status = 'active'
         ) then r.latitude end,
         case when r.status = 'pending' or exists (
           select 1 from public.fleet_enrollments e
           where e.source_request_id = r.id and e.status = 'active'
         ) then r.longitude end,
         r.created_at,
         r.decided_at
  from public.fleet_join_requests r
  join public.students s on s.id = r.student_id
  join public.schools school on school.id = r.school_id
  where r.fleet_id = p_fleet_id
    and (p_status is null or r.status = p_status)
  order by r.created_at desc, r.id desc
  limit p_limit offset p_offset;
end;
$$;

revoke execute on function public.submit_fleet_join_request(uuid, uuid, uuid, text, text[], smallint[]) from public, anon;
revoke execute on function public.cancel_fleet_join_request(uuid) from public, anon;
revoke execute on function public.list_fleet_join_requests(uuid, text, integer, integer) from public, anon;
grant execute on function public.submit_fleet_join_request(uuid, uuid, uuid, text, text[], smallint[]) to authenticated;
grant execute on function public.cancel_fleet_join_request(uuid) to authenticated;
grant execute on function public.list_fleet_join_requests(uuid, text, integer, integer) to authenticated;
