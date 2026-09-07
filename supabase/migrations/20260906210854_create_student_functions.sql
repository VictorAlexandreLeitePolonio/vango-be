create trigger students_set_updated_at
before update on public.students
for each row execute function private.set_updated_at();

create function public.create_minor_student(
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
  v_student_id uuid;
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
  if age(current_date, p_birth_date) >= interval '18 years' then
    perform private.raise_api_error('student_conflict', 'Minor must be under eighteen', 409);
  end if;

  insert into public.students (
    student_type, full_name, birth_date, postal_code, street, street_number,
    address_complement, neighborhood, city_name, city_ibge_code, state_code,
    latitude, longitude, created_by
  ) values (
    'minor', btrim(p_full_name), p_birth_date, btrim(p_postal_code), btrim(p_street),
    btrim(p_street_number), nullif(btrim(p_address_complement), ''), btrim(p_neighborhood),
    btrim(p_city_name), p_city_ibge_code, p_state_code, p_latitude, p_longitude, v_user_id
  ) returning id into v_student_id;

  insert into public.student_guardians (student_id, guardian_user_id, is_primary)
  values (v_student_id, v_user_id, true);

  return v_student_id;
exception
  when unique_violation then
    perform private.raise_api_error('student_conflict', 'Student conflicts with an existing record', 409);
    return null;
end;
$$;

create function public.create_adult_student(
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
  v_student_id uuid;
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
  if age(current_date, p_birth_date) < interval '18 years' then
    perform private.raise_api_error('student_conflict', 'Adult must be eighteen or older', 409);
  end if;

  insert into public.students (
    student_type, profile_id, full_name, birth_date, postal_code, street,
    street_number, address_complement, neighborhood, city_name, city_ibge_code,
    state_code, latitude, longitude, created_by
  ) values (
    'adult', v_user_id, btrim(p_full_name), p_birth_date, btrim(p_postal_code),
    btrim(p_street), btrim(p_street_number), nullif(btrim(p_address_complement), ''),
    btrim(p_neighborhood), btrim(p_city_name), p_city_ibge_code, p_state_code,
    p_latitude, p_longitude, v_user_id
  ) returning id into v_student_id;

  return v_student_id;
exception
  when unique_violation then
    perform private.raise_api_error('student_conflict', 'A student already exists for this profile', 409);
    return null;
end;
$$;

create function public.update_student(
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

  select * into v_student
  from public.students
  where id = p_student_id
  for update;
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

  update public.students
  set full_name = btrim(p_full_name),
      birth_date = p_birth_date,
      postal_code = btrim(p_postal_code),
      street = btrim(p_street),
      street_number = btrim(p_street_number),
      address_complement = nullif(btrim(p_address_complement), ''),
      neighborhood = btrim(p_neighborhood),
      city_name = btrim(p_city_name),
      city_ibge_code = p_city_ibge_code,
      state_code = p_state_code,
      latitude = p_latitude,
      longitude = p_longitude
  where id = p_student_id;

  if cardinality(v_changed_fields) > 0 then
    insert into public.audit_events (
      fleet_id, actor_user_id, action, entity_type, entity_id, metadata
    )
    select e.fleet_id,
           v_user_id,
           'student_updated',
           'student',
           p_student_id,
           jsonb_build_object('changed_fields', to_jsonb(v_changed_fields))
    from public.fleet_enrollments e
    where e.student_id = p_student_id
      and e.status = 'active';
  end if;

  return p_student_id;
end;
$$;

revoke execute on function public.create_minor_student(text, date, text, text, text, text, text, text, text, text, numeric, numeric) from public, anon;
revoke execute on function public.create_adult_student(text, date, text, text, text, text, text, text, text, text, numeric, numeric) from public, anon;
revoke execute on function public.update_student(uuid, text, date, text, text, text, text, text, text, text, text, numeric, numeric) from public, anon;
grant execute on function public.create_minor_student(text, date, text, text, text, text, text, text, text, text, numeric, numeric) to authenticated;
grant execute on function public.create_adult_student(text, date, text, text, text, text, text, text, text, text, numeric, numeric) to authenticated;
grant execute on function public.update_student(uuid, text, date, text, text, text, text, text, text, text, text, numeric, numeric) to authenticated;
