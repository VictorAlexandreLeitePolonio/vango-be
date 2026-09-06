drop index if exists public.fleet_invitations_pending_email_key;
create unique index fleet_invitations_pending_email_key
on public.fleet_invitations (fleet_id, lower(email))
where status = 'pending';

create function public.create_fleet_invitation(
  p_fleet_id uuid,
  p_email text,
  p_role text
) returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_email text := lower(btrim(p_email));
  v_token text;
begin
  if v_user_id is null then
    perform private.raise_api_error('unauthenticated', 'Authentication required', 401);
  end if;
  if not private.current_user_email_confirmed() then
    perform private.raise_api_error('email_unverified', 'Email confirmation required', 403);
  end if;
  if v_email is null or v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'
    or p_role is null or p_role not in ('guardian', 'student') then
    perform private.raise_api_error('invalid_input', 'Invalid email or invitation role', 400);
  end if;
  perform 1 from public.fleets f where f.id = p_fleet_id for update;
  if not found or not private.has_fleet_role(p_fleet_id, v_user_id, 'owner') then
    perform private.raise_api_error('not_found', 'Fleet not found', 404);
  end if;

  v_token := encode(extensions.gen_random_bytes(32), 'hex');
  insert into public.fleet_invitations (
    fleet_id, email, token_hash, role, created_by, expires_at
  ) values (
    p_fleet_id, v_email, extensions.digest(v_token, 'sha256'), p_role,
    v_user_id, clock_timestamp() + interval '14 days'
  );
  insert into public.audit_events (
    fleet_id, actor_user_id, action, entity_type, entity_id, metadata
  )
  select p_fleet_id, v_user_id, 'fleet_invitation_created', 'fleet_invitation', i.id,
         jsonb_build_object('role', p_role)
  from public.fleet_invitations i
  where i.token_hash = extensions.digest(v_token, 'sha256');
  return v_token;
exception
  when unique_violation then
    perform private.raise_api_error('invitation_conflict', 'A pending invitation already exists', 409);
    return null;
end;
$$;

create function public.get_fleet_invitation(p_token text)
returns table (
  fleet_id uuid,
  fleet_name text,
  fleet_slug text,
  fleet_logo_path text,
  role text,
  status text,
  expires_at timestamptz
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  if p_token is null or btrim(p_token) = '' then
    return;
  end if;
  select i.id into v_id
  from public.fleet_invitations i
  where i.token_hash = extensions.digest(p_token, 'sha256')
  for update;
  if not found then
    return;
  end if;
  if exists (
    select 1 from public.fleet_invitations i
    where i.id = v_id and i.status = 'pending' and clock_timestamp() > i.expires_at
  ) then
    update public.fleet_invitations
    set status = 'expired', responded_at = clock_timestamp()
    where id = v_id;
  end if;

  return query
  select f.id, f.name, f.slug, f.logo_path, i.role, i.status, i.expires_at
  from public.fleet_invitations i
  join public.fleets f on f.id = i.fleet_id
  where i.id = v_id;
end;
$$;

create function public.accept_fleet_invitation(
  p_token text,
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
  v_invitation public.fleet_invitations%rowtype;
  v_fleet_status text;
  v_student public.students%rowtype;
  v_school public.schools%rowtype;
  v_request_id uuid;
  v_enrollment_id uuid;
  v_guardian record;
begin
  if v_user_id is null then
    perform private.raise_api_error('unauthenticated', 'Authentication required', 401);
  end if;
  if not private.current_user_email_confirmed() then
    perform private.raise_api_error('email_unverified', 'Email confirmation required', 403);
  end if;
  perform private.validate_request_preferences(p_shift, p_directions, p_weekdays);
  if p_token is null or btrim(p_token) = '' then
    perform private.raise_api_error('not_found', 'Invitation not found', 404);
  end if;

  select * into v_invitation
  from public.fleet_invitations i
  where i.token_hash = extensions.digest(p_token, 'sha256')
  for update;
  if not found then
    perform private.raise_api_error('not_found', 'Invitation not found', 404);
  end if;
  if v_invitation.status <> 'pending' then
    if v_invitation.status = 'expired' then
      return null;
    end if;
    perform private.raise_api_error('invalid_transition', 'Invitation is no longer pending', 409);
  end if;
  if clock_timestamp() > v_invitation.expires_at then
    update public.fleet_invitations
    set status = 'expired', responded_at = clock_timestamp(), responded_by = v_user_id
    where id = v_invitation.id;
    return null;
  end if;
  if private.current_user_email() is distinct from v_invitation.email then
    perform private.raise_api_error('invitation_email_mismatch', 'Authenticated email does not match invitation', 403);
  end if;

  select f.status into v_fleet_status
  from public.fleets f
  where f.id = v_invitation.fleet_id
  for update;
  if not found or v_fleet_status <> 'published' then
    perform private.raise_api_error('invalid_transition', 'Fleet is not accepting enrollments', 409);
  end if;
  select * into v_student
  from public.students s
  where s.id = p_student_id
  for update;
  if not found then
    perform private.raise_api_error('not_found', 'Student not found', 404);
  end if;
  if v_invitation.role = 'student' then
    if v_student.student_type <> 'adult' or v_student.profile_id <> v_user_id then
      perform private.raise_api_error('forbidden', 'Student invitation requires the invited adult student', 403);
    end if;
  else
    if v_student.student_type <> 'minor'
      or not exists (
        select 1 from public.student_guardians sg
        where sg.student_id = v_student.id
          and sg.guardian_user_id = v_user_id
          and sg.is_primary
          and sg.status = 'active'
      ) then
      perform private.raise_api_error('forbidden', 'Guardian invitation requires a managed minor', 403);
    end if;
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
    where fss.fleet_id = v_invitation.fleet_id and fss.school_id = p_school_id
  ) or not exists (
    select 1 from public.fleet_service_cities fsc
    where fsc.fleet_id = v_invitation.fleet_id and fsc.city_ibge_code = v_student.city_ibge_code
  ) then
    perform private.raise_api_error('invalid_input', 'Fleet does not cover the school and student city', 400);
  end if;
  if exists (
    select 1 from public.fleet_enrollments e
    where e.fleet_id = v_invitation.fleet_id and e.student_id = v_student.id and e.status = 'active'
  ) then
    perform private.raise_api_error('enrollment_conflict', 'Student is already enrolled in this fleet', 409);
  end if;

  insert into public.fleet_join_requests (
    fleet_id, requester_user_id, student_id, school_id, origin, fleet_invitation_id,
    shift, directions, weekdays, postal_code, street, street_number,
    address_complement, neighborhood, city_name, city_ibge_code, state_code,
    latitude, longitude, status, decided_by, decided_at
  ) values (
    v_invitation.fleet_id, v_user_id, v_student.id, p_school_id, 'invitation', v_invitation.id,
    p_shift, (select array_agg(direction order by direction) from (select distinct direction from unnest(p_directions) direction) directions),
    (select array_agg(day_value order by day_value) from (select distinct day_value from unnest(p_weekdays) day_value) weekdays),
    v_student.postal_code, v_student.street, v_student.street_number,
    v_student.address_complement, v_student.neighborhood, v_student.city_name,
    v_student.city_ibge_code, v_student.state_code, v_student.latitude, v_student.longitude,
    'approved', v_user_id, clock_timestamp()
  ) returning id into v_request_id;

  insert into public.fleet_enrollments (fleet_id, student_id, source_request_id)
  values (v_invitation.fleet_id, v_student.id, v_request_id)
  returning id into v_enrollment_id;

  if v_student.student_type = 'adult' then
    perform private.ensure_enrollment_membership(
      v_invitation.fleet_id, v_student.profile_id, 'student', v_enrollment_id
    );
  else
    for v_guardian in
      select sg.guardian_user_id
      from public.student_guardians sg
      where sg.student_id = v_student.id and sg.status = 'active'
      order by sg.guardian_user_id
    loop
      perform private.ensure_enrollment_membership(
        v_invitation.fleet_id, v_guardian.guardian_user_id, 'guardian', v_enrollment_id
      );
    end loop;
  end if;

  update public.fleet_invitations
  set status = 'accepted', responded_by = v_user_id, responded_at = clock_timestamp()
  where id = v_invitation.id;
  insert into public.audit_events (
    fleet_id, actor_user_id, action, entity_type, entity_id, metadata
  ) values
    (
      v_invitation.fleet_id, v_user_id, 'fleet_invitation_accepted', 'fleet_invitation', v_invitation.id,
      jsonb_build_object('role', v_invitation.role, 'student_id', v_student.id)
    ),
    (
      v_invitation.fleet_id, v_user_id, 'join_request_approved', 'join_request', v_request_id,
      jsonb_build_object('origin', 'invitation', 'enrollment_id', v_enrollment_id)
    );
  return v_enrollment_id;
exception
  when unique_violation then
    perform private.raise_api_error('enrollment_conflict', 'Student already has an active enrollment', 409);
    return null;
end;
$$;

create function public.decline_fleet_invitation(p_token text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_invitation public.fleet_invitations%rowtype;
begin
  if v_user_id is null then
    perform private.raise_api_error('unauthenticated', 'Authentication required', 401);
  end if;
  if not private.current_user_email_confirmed() then
    perform private.raise_api_error('email_unverified', 'Email confirmation required', 403);
  end if;
  select * into v_invitation
  from public.fleet_invitations i
  where i.token_hash = extensions.digest(p_token, 'sha256')
  for update;
  if not found then
    perform private.raise_api_error('not_found', 'Invitation not found', 404);
  end if;
  if v_invitation.status <> 'pending' then
    perform private.raise_api_error('invalid_transition', 'Invitation is no longer pending', 409);
  end if;
  if clock_timestamp() > v_invitation.expires_at then
    update public.fleet_invitations set status = 'expired', responded_by = v_user_id, responded_at = clock_timestamp() where id = v_invitation.id;
    return 'expired';
  end if;
  if private.current_user_email() is distinct from v_invitation.email then
    perform private.raise_api_error('invitation_email_mismatch', 'Authenticated email does not match invitation', 403);
  end if;
  update public.fleet_invitations
  set status = 'declined', responded_by = v_user_id, responded_at = clock_timestamp()
  where id = v_invitation.id;
  insert into public.audit_events (fleet_id, actor_user_id, action, entity_type, entity_id, metadata)
  values (v_invitation.fleet_id, v_user_id, 'fleet_invitation_declined', 'fleet_invitation', v_invitation.id, '{}'::jsonb);
  return 'declined';
end;
$$;

create function public.cancel_fleet_invitation(p_invitation_id uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_invitation public.fleet_invitations%rowtype;
begin
  if v_user_id is null then
    perform private.raise_api_error('unauthenticated', 'Authentication required', 401);
  end if;
  if not private.current_user_email_confirmed() then
    perform private.raise_api_error('email_unverified', 'Email confirmation required', 403);
  end if;
  select * into v_invitation
  from public.fleet_invitations i
  where i.id = p_invitation_id
  for update;
  if not found or not private.has_fleet_role(v_invitation.fleet_id, v_user_id, 'owner') then
    perform private.raise_api_error('not_found', 'Invitation not found', 404);
  end if;
  if v_invitation.status <> 'pending' then
    perform private.raise_api_error('invalid_transition', 'Invitation is no longer pending', 409);
  end if;
  if clock_timestamp() > v_invitation.expires_at then
    update public.fleet_invitations set status = 'expired', responded_by = v_user_id, responded_at = clock_timestamp() where id = v_invitation.id;
    return 'expired';
  end if;
  update public.fleet_invitations
  set status = 'cancelled', responded_by = v_user_id, responded_at = clock_timestamp()
  where id = v_invitation.id;
  insert into public.audit_events (fleet_id, actor_user_id, action, entity_type, entity_id, metadata)
  values (v_invitation.fleet_id, v_user_id, 'fleet_invitation_cancelled', 'fleet_invitation', v_invitation.id, '{}'::jsonb);
  return 'cancelled';
end;
$$;

revoke execute on function public.create_fleet_invitation(uuid, text, text) from public, anon;
revoke execute on function public.get_fleet_invitation(text) from public;
revoke execute on function public.accept_fleet_invitation(text, uuid, uuid, text, text[], smallint[]) from public, anon;
revoke execute on function public.decline_fleet_invitation(text) from public, anon;
revoke execute on function public.cancel_fleet_invitation(uuid) from public, anon;
grant execute on function public.create_fleet_invitation(uuid, text, text) to authenticated;
grant execute on function public.get_fleet_invitation(text) to anon, authenticated;
grant execute on function public.accept_fleet_invitation(text, uuid, uuid, text, text[], smallint[]) to authenticated;
grant execute on function public.decline_fleet_invitation(text) to authenticated;
grant execute on function public.cancel_fleet_invitation(uuid) to authenticated;
