-- DB4 may have an earlier C3 reservation import.  These declarations are
-- idempotent against the released C3 schema and keep the contract intact.
alter table public.route_student_schedules
  add column if not exists status text not null default 'active';
alter table public.route_student_schedules
  add column if not exists cancelled_at timestamptz;
alter table public.route_student_schedules
  add column if not exists cancellation_reason text;

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
  v_event_id bigint;
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
      v_event_id := private.append_trip_event(
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
        and t.status in ('scheduled', 'confirmation_closed')
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
        v_home_position := case when v_route_direction = 'going' then 1000 else 100000 end;
        select coalesce(max(s.position), v_home_position - 1) + 1 into v_home_position
        from public.trip_stops s
        where s.trip_id = v_reservation.trip_id and s.kind = 'home';
        insert into public.trip_stops (
          fleet_id, trip_id, kind, student_id, position, address_snapshot,
          latitude, longitude
        ) values (
          v_enrollment.fleet_id, v_reservation.trip_id, 'home', v_enrollment.student_id,
          v_home_position, v_home_snapshot, v_student.latitude, v_student.longitude
        ) on conflict (trip_id, position) do nothing;
        v_school_position := case when v_route_direction = 'going' then 100000 else 1000 end;
        select coalesce(max(s.position), v_school_position - 1) + 1 into v_school_position
        from public.trip_stops s
        where s.trip_id = v_reservation.trip_id and s.kind = 'school';
        if not exists (
          select 1 from public.trip_stops s where s.trip_id = v_reservation.trip_id
            and s.kind = 'school' and s.school_id = v_enrollment.school_id
        ) then
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

create or replace function private.reconcile_student_trip_changes()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_enrollment record;
begin
  if OLD.postal_code is distinct from NEW.postal_code
    or OLD.street is distinct from NEW.street
    or OLD.street_number is distinct from NEW.street_number
    or OLD.address_complement is distinct from NEW.address_complement
    or OLD.neighborhood is distinct from NEW.neighborhood
    or OLD.city_name is distinct from NEW.city_name
    or OLD.city_ibge_code is distinct from NEW.city_ibge_code
    or OLD.state_code is distinct from NEW.state_code
    or OLD.latitude is distinct from NEW.latitude
    or OLD.longitude is distinct from NEW.longitude then
    for v_enrollment in
      select e.id from public.fleet_enrollments e
      where e.student_id = NEW.id and e.status = 'active' order by e.id
    loop
      perform private.reconcile_enrollment_trips(
        v_enrollment.id, 'address', current_date, clock_timestamp()
      );
    end loop;
  end if;
  return NEW;
end;
$$;

create or replace function private.reconcile_enrollment_school_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if OLD.school_id is distinct from NEW.school_id and NEW.status = 'active' then
    perform private.reconcile_enrollment_trips(
      NEW.id, 'school', current_date, clock_timestamp()
    );
  end if;
  return NEW;
end;
$$;

drop trigger if exists students_reconcile_trip_snapshots on public.students;
create trigger students_reconcile_trip_snapshots
after update of postal_code, street, street_number, address_complement,
  neighborhood, city_name, city_ibge_code, state_code, latitude, longitude
on public.students
for each row execute function private.reconcile_student_trip_changes();

drop trigger if exists enrollments_reconcile_school on public.fleet_enrollments;
create trigger enrollments_reconcile_school
after update of school_id on public.fleet_enrollments
for each row execute function private.reconcile_enrollment_school_change();

create or replace function private.reconcile_approved_schedule_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if OLD.status is distinct from NEW.status
    and NEW.status = 'approved'
    and NEW.request_kind in ('change', 'new')
    and NEW.enrollment_id is not null then
    perform private.reconcile_enrollment_trips(
      NEW.enrollment_id, 'schedule',
      coalesce(NEW.effective_on, current_date), clock_timestamp()
    );
  end if;
  return NEW;
end;
$$;

drop trigger if exists join_requests_reconcile_schedule on public.fleet_join_requests;
create trigger join_requests_reconcile_schedule
after update of status on public.fleet_join_requests
for each row execute function private.reconcile_approved_schedule_change();

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
  v_now timestamptz := clock_timestamp();
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

  perform private.reconcile_enrollment_trips(
    p_enrollment_id, 'ended', current_date, v_now
  );
  update public.trip_passengers
  set removal_reason = btrim(p_reason)
  where enrollment_id = p_enrollment_id and removed_at = v_now;

  update public.fleet_enrollments
  set status = 'ended', ended_at = v_now, ended_by = v_user_id,
      end_reason = btrim(p_reason)
  where id = p_enrollment_id;
  update public.fleet_join_requests
  set status = 'cancelled', decided_by = v_user_id, decided_at = v_now
  where enrollment_id = p_enrollment_id and status in ('pending', 'waitlisted');
  -- Release today's unstarted capacity as well as future capacity.  Keeping
  -- the rows cancelled preserves the recurring reservation audit trail.
  update public.transport_reservations
  set status = 'cancelled', cancelled_at = v_now,
      cancellation_reason = btrim(p_reason)
  where enrollment_id = p_enrollment_id and status = 'active'
    and valid_until >= current_date;
  update public.route_student_schedules
  set status = 'cancelled', cancelled_at = v_now,
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

revoke all on function private.reconcile_enrollment_trips(uuid, text, date, timestamptz)
  from public, anon, authenticated;
revoke all on function private.reconcile_student_trip_changes() from public, anon, authenticated;
revoke all on function private.reconcile_enrollment_school_change() from public, anon, authenticated;
revoke all on function private.reconcile_approved_schedule_change() from public, anon, authenticated;
revoke all on function public.end_fleet_enrollment(uuid, text) from public, anon;
grant execute on function private.reconcile_enrollment_trips(uuid, text, date, timestamptz)
  to postgres, supabase_admin;
grant execute on function public.end_fleet_enrollment(uuid, text) to authenticated;
