alter table public.audit_events
  drop constraint if exists audit_events_action_valid;

alter table public.audit_events
  add constraint audit_events_action_valid check (action in (
    'fleet_created', 'fleet_updated', 'member_roles_changed',
    'membership_status_changed', 'service_city_added', 'service_city_removed',
    'service_school_added', 'service_school_removed', 'student_updated',
    'secondary_guardian_added', 'secondary_guardian_removed',
    'join_request_created', 'join_request_cancelled', 'join_request_approved',
    'join_request_rejected', 'fleet_invitation_created',
    'fleet_invitation_accepted', 'fleet_invitation_declined',
    'fleet_invitation_cancelled', 'enrollment_ended',
    'van_created', 'van_updated', 'van_deactivated',
    'driver_invitation_created', 'driver_invitation_accepted',
    'route_created', 'route_updated', 'route_status_changed',
    'route_schedule_created', 'route_schedule_updated',
    'transport_reservation_created', 'transport_reservation_cancelled',
    'join_request_waitlisted', 'join_request_changed',
    'enrollment_school_updated', 'service_enabled', 'service_disabled',
    'fleet_student_registered', 'fleet_student_transport_assigned'
  ));

-- Allocation receipts outlive subsequent changes and never reuse registration receipts.
create table private.fleet_student_transport_commands (
 fleet_id uuid not null,
 command_id uuid not null,
 actor_user_id uuid not null references auth.users(id) on delete restrict,
 enrollment_id uuid not null,
 payload_hash bytea not null check(octet_length(payload_hash)=32),
 routing_revision bigint not null check(routing_revision>0),
 effective_on date not null check(isfinite(effective_on)),
 created_at timestamptz not null default clock_timestamp(),
 primary key(fleet_id,command_id),
 foreign key(fleet_id,enrollment_id) references public.fleet_enrollments(fleet_id,id) on delete restrict
);
create index fleet_student_transport_commands_enrollment_idx
 on private.fleet_student_transport_commands(fleet_id,enrollment_id);
create index fleet_student_transport_commands_actor_idx
 on private.fleet_student_transport_commands(actor_user_id);
alter table private.fleet_student_transport_commands enable row level security;
revoke all on private.fleet_student_transport_commands from public,anon,authenticated;

create function private.reject_transport_receipt_mutation() returns trigger
language plpgsql set search_path = '' as $$
begin
 raise exception using errcode='23514',message='Transport command receipts are immutable';
end;
$$;
revoke execute on function private.reject_transport_receipt_mutation() from public,anon,authenticated;
grant execute on function private.reject_transport_receipt_mutation() to postgres;
create trigger fleet_student_transport_commands_immutable before update or delete
 on private.fleet_student_transport_commands for each row execute function private.reject_transport_receipt_mutation();

create or replace function public.assign_fleet_student_transport(
 p_enrollment_id uuid,p_school_id uuid,p_allocations jsonb,p_effective_on date,
 p_command_id uuid,p_expected_routing_revision bigint
) returns table(command_id uuid,enrollment_id uuid,routing_revision bigint,effective_on date)
language plpgsql security definer set search_path = '' as $$
declare
 v_actor uuid := auth.uid();
 v_enrollment public.fleet_enrollments%rowtype;
 v_receipt private.fleet_student_transport_commands%rowtype;
 v_allocations jsonb;
 v_hash bytea;
 v_now timestamptz;
 v_alloc jsonb;
 v_schedule public.route_schedules%rowtype;
 v_route public.routes%rowtype;
 v_assignment uuid;
 v_revision bigint;
begin
 if v_actor is null then perform private.raise_api_error('unauthenticated','Authentication required',401); end if;
 perform private.lock_planning();
 if not private.current_user_email_confirmed() then
   perform private.raise_api_error('email_unverified','Email confirmation required',403);
 end if;
 select * into v_enrollment from public.fleet_enrollments e where e.id=p_enrollment_id for update;
 if not found or not private.has_fleet_role(v_enrollment.fleet_id,v_actor,'owner') then
   perform private.raise_api_error('not_found','Enrollment not found',404);
 end if;
 if p_command_id is null or p_school_id is null or p_expected_routing_revision is null
   or p_expected_routing_revision<1 or p_effective_on is null or not isfinite(p_effective_on) then
   perform private.raise_api_error('invalid_input','Command, school, revision and finite date are required',400);
 end if;
 v_allocations := private.normalize_fleet_transport_allocations(p_allocations);
 v_hash := extensions.digest(convert_to(jsonb_build_object(
   'version',1,'enrollment_id',p_enrollment_id,'school_id',p_school_id,'allocations',v_allocations,
   'effective_on',p_effective_on,'expected_revision',p_expected_routing_revision)::text,'UTF8'),'sha256');
 select * into v_receipt from private.fleet_student_transport_commands c
 where c.fleet_id=v_enrollment.fleet_id and c.command_id=p_command_id;
 if found then
   if v_receipt.actor_user_id<>v_actor or v_receipt.payload_hash<>v_hash then
     perform private.raise_api_error('idempotency_conflict','Command already used with different input',409);
   end if;
   return query select v_receipt.command_id,v_receipt.enrollment_id,v_receipt.routing_revision,v_receipt.effective_on;
   return;
 end if;
 if v_enrollment.routing_revision<>p_expected_routing_revision then
   perform private.raise_api_error('revision_conflict','Enrollment programming has changed',409);
 end if;
 if v_enrollment.status<>'active' or v_enrollment.source_type<>'owner_registration'
   or not exists(select 1 from public.students s where s.id=v_enrollment.student_id and s.registration_origin='fleet_owner_created') then
   perform private.raise_api_error('invalid_transition','Enrollment cannot receive direct allocation',409);
 end if;
 if v_enrollment.school_id is distinct from p_school_id or v_enrollment.shift is null
   or not exists(select 1 from public.schools s join public.fleet_service_schools fss on fss.school_id=s.id
     where s.id=p_school_id and fss.fleet_id=v_enrollment.fleet_id and s.status='active'
       and s.latitude between -90 and 90 and s.longitude between -180 and 180) then
   perform private.raise_api_error('invalid_input','Enrollment school and shift must match available coverage',400);
 end if;
 -- Direct commands classify a valid schedule's unavailable date separately from malformed resources.
 if exists(select 1 from jsonb_array_elements(v_allocations) a
   join public.route_schedules rs on rs.id=(a->>'schedule_id')::uuid
   where rs.fleet_id=v_enrollment.fleet_id and rs.status='active'
     and p_effective_on not between rs.valid_from and rs.valid_until) then
   perform private.raise_api_error('effective_date_conflict','Effective date is outside schedule validity',409);
 end if;
 v_now := clock_timestamp();
 v_allocations := private.validate_transport_allocations(v_enrollment.fleet_id,v_enrollment.student_id,
   p_enrollment_id,p_school_id,v_enrollment.shift,v_allocations,p_effective_on);
 if not private.transport_change_date_is_open(v_enrollment.fleet_id,p_enrollment_id,v_allocations,p_effective_on,v_now) then
   perform private.raise_api_error('effective_date_conflict','Effective date is no longer open',409);
 end if;
 -- Keep earlier service dates, including executions that end overnight on D.
 update public.route_student_schedules rss set valid_until=p_effective_on-1
 where rss.enrollment_id=p_enrollment_id and rss.status='active' and rss.valid_from<p_effective_on and rss.valid_until>=p_effective_on;
 update public.route_student_schedules rss set status='cancelled',cancelled_at=v_now,cancellation_reason='superseded by owner allocation'
 where rss.enrollment_id=p_enrollment_id and rss.status='active' and rss.valid_from>=p_effective_on;
 update public.transport_reservations tr set valid_until=p_effective_on-1
 where tr.enrollment_id=p_enrollment_id and tr.status='active' and tr.valid_from<p_effective_on and tr.valid_until>=p_effective_on;
 update public.transport_reservations tr set status='cancelled',cancelled_at=v_now,cancellation_reason='superseded by owner allocation'
 where tr.enrollment_id=p_enrollment_id and tr.status='active' and tr.valid_from>=p_effective_on;
 for v_alloc in select value from jsonb_array_elements(v_allocations) loop
   select * into v_schedule from public.route_schedules where id=(v_alloc->>'schedule_id')::uuid;
   select * into v_route from public.routes where id=v_schedule.route_id;
   insert into public.route_student_schedules(fleet_id,enrollment_id,route_id,schedule_id,weekday,direction,valid_from,valid_until)
   values(v_enrollment.fleet_id,p_enrollment_id,v_route.id,v_schedule.id,(v_alloc->>'weekday')::smallint,
     v_alloc->>'direction',p_effective_on,v_schedule.valid_until) returning id into v_assignment;
   insert into public.transport_reservations(fleet_id,enrollment_id,student_id,route_student_schedule_id,
     route_id,schedule_id,van_id,weekday,direction,valid_from,valid_until)
   values(v_enrollment.fleet_id,p_enrollment_id,v_enrollment.student_id,v_assignment,v_route.id,v_schedule.id,
     v_route.van_id,(v_alloc->>'weekday')::smallint,v_alloc->>'direction',p_effective_on,v_schedule.valid_until);
 end loop;
 update public.fleet_enrollments e set routing_revision=e.routing_revision+1
 where e.id=p_enrollment_id returning e.routing_revision into v_revision;
 perform private.reconcile_enrollment_trips(p_enrollment_id,'schedule',p_effective_on,v_now);
 insert into public.audit_events(fleet_id,actor_user_id,action,entity_type,entity_id,metadata)
 values(v_enrollment.fleet_id,v_actor,'fleet_student_transport_assigned','enrollment',p_enrollment_id,
   jsonb_build_object('command_id',p_command_id,'effective_on',p_effective_on,'allocation_count',jsonb_array_length(v_allocations),
     'previous_revision',v_enrollment.routing_revision,'routing_revision',v_revision));
 insert into private.fleet_student_transport_commands(fleet_id,command_id,actor_user_id,enrollment_id,payload_hash,routing_revision,effective_on)
 values(v_enrollment.fleet_id,p_command_id,v_actor,p_enrollment_id,v_hash,v_revision,p_effective_on);
 return query select p_command_id,p_enrollment_id,v_revision,p_effective_on;
exception when sqlstate 'PGRST' then raise;
 when others then perform private.raise_api_error('allocation_failed','Allocation could not be completed',500);
end;
$$;
revoke execute on function public.assign_fleet_student_transport(uuid,uuid,jsonb,date,uuid,bigint) from public,anon;
grant execute on function public.assign_fleet_student_transport(uuid,uuid,jsonb,date,uuid,bigint) to authenticated;

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
    update public.fleet_enrollments set routing_revision = routing_revision + 1 where id = v_enrollment_id;
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
