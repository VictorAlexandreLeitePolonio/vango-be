alter table public.fleet_enrollments
  add column registration_command_id uuid,
  add column registration_payload_hash bytea,
  add constraint fleet_enrollments_registration_receipt_valid check (
    (source_type = 'owner_registration'
      and registration_command_id is not null
      and registration_payload_hash is not null
      and octet_length(registration_payload_hash) = 32)
    or (source_type = 'join_request'
      and registration_command_id is null
      and registration_payload_hash is null)
  );

create unique index fleet_enrollments_registration_command_unique
  on public.fleet_enrollments (fleet_id, registration_command_id)
  where source_type = 'owner_registration';

create or replace function private.reject_fleet_enrollment_source_change()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.source_type is distinct from old.source_type
     or new.source_request_id is distinct from old.source_request_id
     or new.registration_command_id is distinct from old.registration_command_id
     or new.registration_payload_hash is distinct from old.registration_payload_hash then
    raise exception using errcode = '23514', message = 'Fleet enrollment source is immutable';
  end if;
  return new;
end;
$$;

drop trigger fleet_enrollments_source_immutable on public.fleet_enrollments;
create trigger fleet_enrollments_source_immutable
before update of source_type, source_request_id, registration_command_id, registration_payload_hash
on public.fleet_enrollments
for each row execute function private.reject_fleet_enrollment_source_change();

create function public.create_fleet_managed_student(
  p_fleet_id uuid, p_command_id uuid, p_student_type text, p_full_name text,
  p_birth_date date, p_postal_code text, p_street text, p_street_number text,
  p_address_complement text, p_neighborhood text, p_city_name text,
  p_city_ibge_code text, p_state_code text, p_latitude numeric,
  p_longitude numeric, p_school_id uuid, p_shift text,
  p_contact_full_name text, p_contact_email text, p_contact_phone text
) returns table(student_id uuid, enrollment_id uuid)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_name text := btrim(p_full_name);
  v_postal text := btrim(p_postal_code);
  v_street text := btrim(p_street);
  v_number text := btrim(p_street_number);
  v_complement text := nullif(btrim(p_address_complement), '');
  v_neighborhood text := btrim(p_neighborhood);
  v_city text := btrim(p_city_name);
  v_contact_name text := btrim(p_contact_full_name);
  v_email text := nullif(lower(btrim(p_contact_email)), '');
  v_phone text := nullif(btrim(p_contact_phone), '');
  v_hash bytea;
  v_constraint text;
begin
  if v_actor is null then
    perform private.raise_api_error('unauthenticated', 'Authentication required', 401);
  end if;
  if not private.current_user_email_confirmed() then
    perform private.raise_api_error('email_unverified', 'Email confirmation required', 403);
  end if;
  if not private.has_fleet_role(p_fleet_id, v_actor, 'owner') then
    perform private.raise_api_error('forbidden', 'Fleet owner permission required', 403);
  end if;
  if p_command_id is null or p_student_type not in ('minor', 'adult')
     or p_student_type is null or p_shift not in ('morning', 'afternoon', 'evening', 'full_time')
     or p_shift is null or v_contact_name is null or v_contact_name = ''
     or (v_email is null and v_phone is null)
     or p_latitude is null or p_longitude is null
     or p_latitude::text in ('NaN', 'Infinity', '-Infinity')
     or p_longitude::text in ('NaN', 'Infinity', '-Infinity')
     or p_latitude not between -90 and 90
     or p_longitude not between -180 and 180
     or p_birth_date is null
     or (p_student_type = 'minor' and age(current_date, p_birth_date) >= interval '18 years')
     or (p_student_type = 'adult' and age(current_date, p_birth_date) < interval '18 years')
     or not exists (
       select 1 from public.schools s
       join public.fleet_service_schools fss on fss.school_id = s.id
       where s.id = p_school_id and s.status = 'active' and fss.fleet_id = p_fleet_id
     ) then
    perform private.raise_api_error('invalid_input', 'Invalid registration fields', 400);
  end if;

  perform private.validate_student_fields(
    v_name, p_birth_date, v_postal, v_street, v_number, v_complement,
    v_neighborhood, v_city, p_city_ibge_code, p_state_code, p_latitude, p_longitude
  );

  v_hash := extensions.digest(jsonb_build_object(
    'student_type', p_student_type, 'full_name', v_name, 'birth_date', p_birth_date,
    'postal_code', v_postal, 'street', v_street, 'street_number', v_number,
    'address_complement', v_complement, 'neighborhood', v_neighborhood,
    'city_name', v_city, 'city_ibge_code', p_city_ibge_code, 'state_code', p_state_code,
    'latitude', p_latitude, 'longitude', p_longitude, 'school_id', p_school_id,
    'shift', p_shift, 'contact_full_name', v_contact_name,
    'contact_email', v_email, 'contact_phone', v_phone
  )::text, 'sha256');

  select e.student_id, e.id into student_id, enrollment_id
  from public.fleet_enrollments e
  join public.students s on s.id = e.student_id
  where e.fleet_id = p_fleet_id and e.registration_command_id = p_command_id
    and e.source_type = 'owner_registration';
  if found then
    if not exists (
      select 1 from public.fleet_enrollments e
      join public.students s on s.id = e.student_id
      where e.id = enrollment_id and s.created_by = v_actor
        and e.registration_payload_hash = v_hash
    ) then
      perform private.raise_api_error('idempotency_conflict', 'Registration command conflict', 409);
    end if;
    return next;
    return;
  end if;

  begin
    insert into public.students (
      student_type, registration_origin, full_name, birth_date, postal_code,
      street, street_number, address_complement, neighborhood, city_name,
      city_ibge_code, state_code, latitude, longitude, created_by
    ) values (
      p_student_type, 'fleet_owner_created', v_name, p_birth_date, v_postal,
      v_street, v_number, v_complement, v_neighborhood, v_city,
      p_city_ibge_code, p_state_code, p_latitude, p_longitude, v_actor
    ) returning id into student_id;

    insert into public.fleet_enrollments (
      fleet_id, student_id, source_type, source_request_id, school_id, shift,
      registration_command_id, registration_payload_hash
    ) values (
      p_fleet_id, student_id, 'owner_registration', null, p_school_id, p_shift,
      p_command_id, v_hash
    ) returning id into enrollment_id;
  exception when unique_violation then
    get stacked diagnostics v_constraint = constraint_name;
    if v_constraint <> 'fleet_enrollments_registration_command_unique' then
      raise;
    end if;
    select e.student_id, e.id into student_id, enrollment_id
    from public.fleet_enrollments e
    where e.fleet_id = p_fleet_id and e.registration_command_id = p_command_id
      and e.source_type = 'owner_registration';
    if not found or not exists (
      select 1 from public.fleet_enrollments e
      join public.students s on s.id = e.student_id
      where e.id = enrollment_id and s.created_by = v_actor
        and e.registration_payload_hash = v_hash
    ) then
      perform private.raise_api_error('idempotency_conflict', 'Registration command conflict', 409);
    end if;
    return next;
    return;
  end;

  insert into public.fleet_student_contacts (
    fleet_id, enrollment_id, contact_type, full_name, email, phone, is_primary
  ) values (
    p_fleet_id, enrollment_id,
    case when p_student_type = 'minor' then 'guardian' else 'student' end,
    v_contact_name, v_email, v_phone, true
  );
  insert into public.audit_events (
    fleet_id, actor_user_id, action, entity_type, entity_id, metadata
  ) values (
    p_fleet_id, v_actor, 'fleet_student_registered', 'student', student_id,
    jsonb_build_object('school_id', p_school_id, 'shift', p_shift, 'student_type', p_student_type)
  );
  return next;
exception when others then
  if sqlstate = 'PGRST' then
    raise;
  end if;
  perform private.raise_api_error('registration_failed', 'Registration failed', 500);
end;
$$;

revoke execute on function public.create_fleet_managed_student(
  uuid, uuid, text, text, date, text, text, text, text, text,
  text, text, text, numeric, numeric, uuid, text, text, text, text
) from public, anon;
grant execute on function public.create_fleet_managed_student(
  uuid, uuid, text, text, date, text, text, text, text, text,
  text, text, text, numeric, numeric, uuid, text, text, text, text
) to authenticated;

create function public.list_fleet_students(p_fleet_id uuid)
returns table(
  enrollment_id uuid, student_id uuid, student_type text, full_name text,
  postal_code text, street text, street_number text, address_complement text,
  neighborhood text, city_name text, state_code text, school_id uuid,
  school_name text, shift text
)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not exists (select 1 from public.fleets f where f.id = p_fleet_id)
     or not private.has_fleet_role(p_fleet_id, auth.uid(), 'owner') then
    perform private.raise_api_error('not_found', 'Fleet not found', 404);
  end if;
  return query
    select e.id, s.id, s.student_type, s.full_name, s.postal_code,
      s.street, s.street_number, s.address_complement, s.neighborhood,
      s.city_name, s.state_code, e.school_id, sc.name, e.shift
    from public.fleet_enrollments e
    join public.students s on s.id = e.student_id
    left join public.schools sc on sc.id = e.school_id
    where e.fleet_id = p_fleet_id and e.status = 'active'
    order by lower(s.full_name), s.id;
end;
$$;

revoke execute on function public.list_fleet_students(uuid) from public, anon;
grant execute on function public.list_fleet_students(uuid) to authenticated;
