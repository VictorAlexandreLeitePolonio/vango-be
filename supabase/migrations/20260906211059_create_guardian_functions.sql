create function private.ensure_enrollment_membership(
  p_fleet_id uuid,
  p_user_id uuid,
  p_role text,
  p_enrollment_id uuid
) returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_membership_id uuid;
  v_status text;
begin
  select fm.id, fm.status
  into v_membership_id, v_status
  from public.fleet_memberships fm
  where fm.fleet_id = p_fleet_id
    and fm.user_id = p_user_id
  for update;

  if not found then
    insert into public.fleet_memberships (fleet_id, user_id)
    values (p_fleet_id, p_user_id)
    returning id into v_membership_id;
  elsif v_status = 'left' then
    update public.fleet_memberships
    set status = 'active', suspended_at = null, left_at = null
    where id = v_membership_id;
  end if;

  insert into public.fleet_membership_role_sources (membership_id, role, source_type, enrollment_id)
  values (v_membership_id, p_role, 'enrollment', p_enrollment_id)
  on conflict do nothing;

  perform private.sync_effective_membership_roles(v_membership_id);
  return v_membership_id;
end;
$$;

create function public.create_student_guardian_invitation(
  p_student_id uuid,
  p_email text
) returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_email text := lower(btrim(p_email));
  v_token text;
  v_student_type text;
begin
  if v_user_id is null then
    perform private.raise_api_error('unauthenticated', 'Authentication required', 401);
  end if;
  if not private.current_user_email_confirmed() then
    perform private.raise_api_error('email_unverified', 'Email confirmation required', 403);
  end if;
  if v_email is null or v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
    perform private.raise_api_error('invalid_input', 'Invalid email', 400);
  end if;

  select s.student_type into v_student_type
  from public.students s
  where s.id = p_student_id;
  if not found then
    perform private.raise_api_error('not_found', 'Student not found', 404);
  end if;
  if v_student_type <> 'minor'
    or not exists (
      select 1 from public.student_guardians sg
      where sg.student_id = p_student_id
        and sg.guardian_user_id = v_user_id
        and sg.is_primary
        and sg.status = 'active'
    ) then
    perform private.raise_api_error('forbidden', 'Primary guardian role required', 403);
  end if;
  if exists (
    select 1
    from auth.users u
    join public.student_guardians sg on sg.guardian_user_id = u.id
    where sg.student_id = p_student_id
      and sg.status = 'active'
      and lower(btrim(u.email)) = v_email
  ) then
    perform private.raise_api_error('guardian_conflict', 'User is already a guardian', 409);
  end if;

  v_token := encode(extensions.gen_random_bytes(32), 'hex');
  insert into public.student_guardian_invitations (
    student_id, email, token_hash, invited_by, expires_at
  ) values (
    p_student_id, v_email, extensions.digest(v_token, 'sha256'), v_user_id,
    clock_timestamp() + interval '14 days'
  );
  return v_token;
exception
  when unique_violation then
    perform private.raise_api_error('invitation_conflict', 'A pending invitation already exists', 409);
    return null;
end;
$$;

create function public.respond_student_guardian_invitation(
  p_token text,
  p_accept boolean
) returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_invitation public.student_guardian_invitations%rowtype;
  v_student public.students%rowtype;
  v_enrollment record;
begin
  if v_user_id is null then
    perform private.raise_api_error('unauthenticated', 'Authentication required', 401);
  end if;
  if not private.current_user_email_confirmed() then
    perform private.raise_api_error('email_unverified', 'Email confirmation required', 403);
  end if;
  if p_token is null or btrim(p_token) = '' then
    perform private.raise_api_error('not_found', 'Invitation not found', 404);
  end if;

  select * into v_invitation
  from public.student_guardian_invitations i
  where i.token_hash = extensions.digest(p_token, 'sha256')
  for update;
  if not found then
    perform private.raise_api_error('not_found', 'Invitation not found', 404);
  end if;
  if v_invitation.status <> 'pending' then
    perform private.raise_api_error('invalid_transition', 'Invitation is no longer pending', 409);
  end if;
  if clock_timestamp() > v_invitation.expires_at then
    update public.student_guardian_invitations
    set status = 'expired', responded_at = clock_timestamp(), responded_by = v_user_id
    where id = v_invitation.id;
    return 'expired';
  end if;
  if private.current_user_email() is distinct from v_invitation.email then
    perform private.raise_api_error('invitation_email_mismatch', 'Authenticated email does not match invitation', 403);
  end if;

  if not p_accept then
    update public.student_guardian_invitations
    set status = 'declined', responded_at = clock_timestamp(), responded_by = v_user_id
    where id = v_invitation.id;
    return 'declined';
  end if;

  select * into v_student
  from public.students s
  where s.id = v_invitation.student_id
  for update;
  if not found or v_student.student_type <> 'minor' then
    perform private.raise_api_error('guardian_conflict', 'Student cannot have guardians', 409);
  end if;
  if exists (
    select 1 from public.student_guardians sg
    where sg.student_id = v_student.id
      and sg.guardian_user_id = v_user_id
      and sg.is_primary
  ) then
    perform private.raise_api_error('guardian_conflict', 'Primary guardian cannot become secondary', 409);
  end if;

  insert into public.student_guardians (student_id, guardian_user_id, is_primary, status, joined_at, removed_at)
  values (v_student.id, v_user_id, false, 'active', clock_timestamp(), null)
  on conflict (student_id, guardian_user_id)
  do update set status = 'active', is_primary = false, joined_at = clock_timestamp(), removed_at = null;

  for v_enrollment in
    select e.id, e.fleet_id
    from public.fleet_enrollments e
    where e.student_id = v_student.id and e.status = 'active'
    order by e.fleet_id, e.id
  loop
    perform private.ensure_enrollment_membership(
      v_enrollment.fleet_id, v_user_id, 'guardian', v_enrollment.id
    );
    insert into public.audit_events (
      fleet_id, actor_user_id, action, entity_type, entity_id, metadata
    ) values (
      v_enrollment.fleet_id, v_user_id, 'secondary_guardian_added', 'student_guardian',
      v_student.id, jsonb_build_object('student_id', v_student.id, 'guardian_user_id', v_user_id)
    );
  end loop;

  update public.student_guardian_invitations
  set status = 'accepted', responded_at = clock_timestamp(), responded_by = v_user_id
  where id = v_invitation.id;
  return 'accepted';
end;
$$;

create function public.remove_student_guardian(
  p_student_id uuid,
  p_guardian_user_id uuid
) returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_guardian public.student_guardians%rowtype;
  v_enrollment record;
begin
  if v_user_id is null then
    perform private.raise_api_error('unauthenticated', 'Authentication required', 401);
  end if;
  if not private.current_user_email_confirmed() then
    perform private.raise_api_error('email_unverified', 'Email confirmation required', 403);
  end if;
  if not exists (
    select 1 from public.student_guardians sg
    where sg.student_id = p_student_id
      and sg.guardian_user_id = v_user_id
      and sg.is_primary
      and sg.status = 'active'
  ) then
    perform private.raise_api_error('forbidden', 'Primary guardian role required', 403);
  end if;

  select * into v_guardian
  from public.student_guardians sg
  where sg.student_id = p_student_id
    and sg.guardian_user_id = p_guardian_user_id
  for update;
  if not found then
    perform private.raise_api_error('not_found', 'Guardian not found', 404);
  end if;
  if v_guardian.is_primary then
    perform private.raise_api_error('guardian_conflict', 'Primary guardian cannot be removed', 409);
  end if;
  if v_guardian.status <> 'active' then
    perform private.raise_api_error('invalid_transition', 'Guardian is already removed', 409);
  end if;

  update public.student_guardians
  set status = 'removed', removed_at = clock_timestamp()
  where student_id = p_student_id and guardian_user_id = p_guardian_user_id;

  for v_enrollment in
    select e.id, e.fleet_id, fm.id as membership_id
    from public.fleet_enrollments e
    join public.fleet_memberships fm
      on fm.fleet_id = e.fleet_id and fm.user_id = p_guardian_user_id
    where e.student_id = p_student_id and e.status = 'active'
    order by e.fleet_id, e.id
  loop
    delete from public.fleet_membership_role_sources sources
    where sources.membership_id = v_enrollment.membership_id
      and sources.role = 'guardian'
      and sources.source_type = 'enrollment'
      and sources.enrollment_id = v_enrollment.id;
    perform private.sync_effective_membership_roles(v_enrollment.membership_id);
    insert into public.audit_events (
      fleet_id, actor_user_id, action, entity_type, entity_id, metadata
    ) values (
      v_enrollment.fleet_id, v_user_id, 'secondary_guardian_removed', 'student_guardian',
      p_student_id, jsonb_build_object('student_id', p_student_id, 'guardian_user_id', p_guardian_user_id)
    );
  end loop;

  return 'removed';
end;
$$;

revoke execute on function private.ensure_enrollment_membership(uuid, uuid, text, uuid) from public, anon, authenticated;
revoke execute on function public.create_student_guardian_invitation(uuid, text) from public, anon;
revoke execute on function public.respond_student_guardian_invitation(text, boolean) from public, anon;
revoke execute on function public.remove_student_guardian(uuid, uuid) from public, anon;
grant execute on function public.create_student_guardian_invitation(uuid, text) to authenticated;
grant execute on function public.respond_student_guardian_invitation(text, boolean) to authenticated;
grant execute on function public.remove_student_guardian(uuid, uuid) to authenticated;
