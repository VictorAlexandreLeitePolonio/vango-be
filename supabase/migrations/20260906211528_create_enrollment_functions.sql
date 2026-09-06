create function public.decide_fleet_join_request(
  p_request_id uuid,
  p_decision text
) returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_fleet_id uuid;
  v_request public.fleet_join_requests%rowtype;
  v_student public.students%rowtype;
  v_enrollment_id uuid;
  v_guardian record;
begin
  if v_user_id is null then
    perform private.raise_api_error('unauthenticated', 'Authentication required', 401);
  end if;
  if not private.current_user_email_confirmed() then
    perform private.raise_api_error('email_unverified', 'Email confirmation required', 403);
  end if;
  if p_decision is null or p_decision not in ('approved', 'rejected') then
    perform private.raise_api_error('invalid_input', 'Decision must be approved or rejected', 400);
  end if;

  select r.fleet_id into v_fleet_id
  from public.fleet_join_requests r
  where r.id = p_request_id;
  if not found then
    perform private.raise_api_error('not_found', 'Request not found', 404);
  end if;
  perform 1 from public.fleets f where f.id = v_fleet_id for update;
  select * into v_request
  from public.fleet_join_requests r
  where r.id = p_request_id
  for update;
  if not private.has_fleet_role(v_fleet_id, v_user_id, 'owner') then
    perform private.raise_api_error('not_found', 'Request not found', 404);
  end if;
  if v_request.status <> 'pending' then
    perform private.raise_api_error('invalid_transition', 'Request is no longer pending', 409);
  end if;

  if p_decision = 'rejected' then
    update public.fleet_join_requests
    set status = 'rejected', decided_by = v_user_id, decided_at = clock_timestamp()
    where id = p_request_id;
    insert into public.audit_events (
      fleet_id, actor_user_id, action, entity_type, entity_id, metadata
    ) values (
      v_fleet_id, v_user_id, 'join_request_rejected', 'join_request', p_request_id,
      jsonb_build_object('student_id', v_request.student_id)
    );
    return 'rejected';
  end if;

  select * into v_student
  from public.students s
  where s.id = v_request.student_id
  for update;
  if not found then
    perform private.raise_api_error('not_found', 'Student not found', 404);
  end if;
  if exists (
    select 1 from public.fleet_enrollments e
    where e.fleet_id = v_fleet_id and e.student_id = v_request.student_id and e.status = 'active'
  ) then
    perform private.raise_api_error('enrollment_conflict', 'Student is already enrolled in this fleet', 409);
  end if;

  insert into public.fleet_enrollments (
    fleet_id, student_id, source_request_id
  ) values (
    v_fleet_id, v_request.student_id, v_request.id
  ) returning id into v_enrollment_id;

  if v_student.student_type = 'adult' then
    perform private.ensure_enrollment_membership(
      v_fleet_id, v_student.profile_id, 'student', v_enrollment_id
    );
  else
    for v_guardian in
      select sg.guardian_user_id
      from public.student_guardians sg
      where sg.student_id = v_student.id and sg.status = 'active'
      order by sg.guardian_user_id
    loop
      perform private.ensure_enrollment_membership(
        v_fleet_id, v_guardian.guardian_user_id, 'guardian', v_enrollment_id
      );
    end loop;
  end if;

  update public.fleet_join_requests
  set status = 'approved', decided_by = v_user_id, decided_at = clock_timestamp()
  where id = p_request_id;
  insert into public.audit_events (
    fleet_id, actor_user_id, action, entity_type, entity_id, metadata
  ) values (
    v_fleet_id, v_user_id, 'join_request_approved', 'join_request', p_request_id,
    jsonb_build_object('student_id', v_request.student_id, 'enrollment_id', v_enrollment_id)
  );
  return 'approved';
exception
  when unique_violation then
    perform private.raise_api_error('enrollment_conflict', 'Student already has an active enrollment', 409);
    return null;
end;
$$;

create function public.end_fleet_enrollment(
  p_enrollment_id uuid,
  p_reason text
) returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_fleet_id uuid;
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

  select e.fleet_id into v_fleet_id
  from public.fleet_enrollments e
  where e.id = p_enrollment_id;
  if not found then
    perform private.raise_api_error('not_found', 'Enrollment not found', 404);
  end if;
  perform 1 from public.fleets f where f.id = v_fleet_id for update;
  select * into v_enrollment
  from public.fleet_enrollments e
  where e.id = p_enrollment_id
  for update;
  if not private.has_fleet_role(v_fleet_id, v_user_id, 'owner') then
    perform private.raise_api_error('not_found', 'Enrollment not found', 404);
  end if;
  if v_enrollment.status <> 'active' then
    perform private.raise_api_error('invalid_transition', 'Enrollment is no longer active', 409);
  end if;

  update public.fleet_enrollments
  set status = 'ended', ended_at = clock_timestamp(), ended_by = v_user_id, end_reason = btrim(p_reason)
  where id = p_enrollment_id;

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
    v_fleet_id, v_user_id, 'enrollment_ended', 'enrollment', p_enrollment_id,
    jsonb_build_object('student_id', v_enrollment.student_id, 'reason_recorded', true)
  );
  return 'ended';
end;
$$;

revoke execute on function public.decide_fleet_join_request(uuid, text) from public, anon;
revoke execute on function public.end_fleet_enrollment(uuid, text) from public, anon;
grant execute on function public.decide_fleet_join_request(uuid, text) to authenticated;
grant execute on function public.end_fleet_enrollment(uuid, text) to authenticated;
