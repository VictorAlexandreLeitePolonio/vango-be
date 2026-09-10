-- Cycle 6 Tasks 5: bounded GPS retention, per-passenger ETA state and
-- proximity notification evaluation.  The routing provider remains outside
-- this migration: only an already calculated, still-valid ETA can create an
-- alert.

alter table public.trip_passengers
  add column if not exists eta_at timestamptz,
  add column if not exists eta_calculated_at timestamptz,
  add column if not exists eta_valid_until timestamptz,
  add column if not exists eta_revision bigint;

do $constraint$
begin
  if not exists (
    select 1
    from pg_constraint
    where conrelid = 'public.trip_passengers'::regclass
      and conname = 'trip_passengers_eta_state_valid'
  ) then
    alter table public.trip_passengers
      add constraint trip_passengers_eta_state_valid check (
        (
          eta_at is null
          and eta_calculated_at is null
          and eta_valid_until is null
          and eta_revision is null
        )
        or (
          eta_at is not null
          and eta_calculated_at is not null
          and eta_valid_until is not null
          and eta_revision is not null
          and eta_revision > 0
          and eta_valid_until > eta_calculated_at
        )
      );
  end if;
end;
$constraint$;

create index if not exists trip_passengers_eta_valid_idx
  on public.trip_passengers (trip_id, eta_valid_until)
  where eta_at is not null;

-- Keep only facts that can be proven from retained GPS points.  In particular,
-- this summary deliberately does not claim distance or duration: sampled
-- points do not prove either value after the raw trail is removed.
create table private.trip_location_summaries (
  trip_id uuid not null,
  fleet_id uuid not null,
  assignment_id uuid not null,
  point_count integer not null,
  first_captured_at timestamptz not null,
  last_captured_at timestamptz not null,
  computed_at timestamptz not null,
  constraint trip_location_summaries_pkey primary key (trip_id, assignment_id),
  constraint trip_location_summaries_count_positive check (point_count > 0),
  constraint trip_location_summaries_capture_order check (
    last_captured_at >= first_captured_at
  )
);

create index trip_location_summaries_fleet_idx
  on private.trip_location_summaries (fleet_id, computed_at desc);

revoke all on table private.trip_location_summaries
  from public, anon, authenticated, service_role;

-- The retention clock is explicit so a job and a deterministic test use the
-- same boundary.  Captured time, rather than received time, controls expiry.
create or replace function private.expire_trip_locations(
  p_now timestamptz
) returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_points integer := 0;
  v_receipts integer := 0;
  v_current integer := 0;
begin
  if p_now is null or not isfinite(p_now) then
    perform private.raise_api_error('invalid_input', 'Clock is required', 400);
  end if;

  perform private.lock_planning();

  insert into private.trip_location_summaries as summary (
    trip_id, fleet_id, assignment_id, point_count,
    first_captured_at, last_captured_at, computed_at
  )
  select
    point.trip_id,
    point.fleet_id,
    point.assignment_id,
    count(*)::integer,
    min(point.captured_at),
    max(point.captured_at),
    p_now
  from public.trip_location_points point
  where point.captured_at < p_now - interval '30 days'
  group by point.trip_id, point.fleet_id, point.assignment_id
  on conflict (trip_id, assignment_id) do update
  set fleet_id = excluded.fleet_id,
      point_count = summary.point_count + excluded.point_count,
      first_captured_at = least(summary.first_captured_at, excluded.first_captured_at),
      last_captured_at = greatest(summary.last_captured_at, excluded.last_captured_at),
      computed_at = excluded.computed_at;

  delete from public.trip_location_points
  where captured_at < p_now - interval '30 days';
  get diagnostics v_points = row_count;

  delete from public.trip_location_receipts
  where captured_at < p_now - interval '30 days';
  get diagnostics v_receipts = row_count;

  -- A current projection is useful only while its trip is active and its
  -- capture remains inside retention.  Events, audit rows and route
  -- snapshots are intentionally outside this deletion set.
  delete from public.trip_current_locations current_location
  where current_location.captured_at < p_now - interval '30 days'
    or not exists (
      select 1
      from public.trips trip
      where trip.id = current_location.trip_id
        and trip.status = 'active'
    );
  get diagnostics v_current = row_count;

  return v_points + v_receipts + v_current;
end;
$$;

revoke all on function private.expire_trip_locations(timestamptz)
  from public, anon, authenticated;
grant execute on function private.expire_trip_locations(timestamptz)
  to postgres, supabase_admin;

-- Keep the schedule real and inspectable while rollout is coordinated.  The
-- job is intentionally inactive; activation is a separate operational step
-- in the configured Cron database.  Re-running the migration leaves exactly
-- one job with this name.
create extension if not exists pg_cron;

do $job_setup$
declare
  v_job record;
  v_job_id bigint;
begin
  for v_job in
    select jobid
    from cron.job
    where jobname = 'vango-location-retention'
  loop
    perform cron.unschedule(v_job.jobid);
  end loop;
  v_job_id := cron.schedule(
    'vango-location-retention',
    '0 3 * * *',
    $cron_command$select private.expire_trip_locations(clock_timestamp());$cron_command$
  );
  perform cron.alter_job(v_job_id, active := false);
end;
$job_setup$;

-- C5's generic actionability check is extended for the one C6 category.  A
-- queued proximity message becomes unusable after the trip/passenger state or
-- the ETA validity changes, so a worker cannot send a stale alert.
create or replace function private.notification_actionable(
  p_notification_id uuid,
  p_user_id uuid,
  p_now timestamptz
) returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_notification public.notifications%rowtype;
  v_trip public.trips%rowtype;
  v_student_id uuid;
begin
  if p_notification_id is null or p_user_id is null or p_now is null
    or not isfinite(p_now) then
    return false;
  end if;
  select n.* into v_notification
  from public.notifications n
  where n.id = p_notification_id;
  if not found or v_notification.expires_at <= p_now
    or not private.can_read_notification(p_notification_id, p_user_id) then
    return false;
  end if;

  if v_notification.entity_type = 'trip' then
    select t.* into v_trip
    from public.trips t
    where t.id = v_notification.entity_id
      and t.fleet_id = v_notification.fleet_id;
    if not found then
      return false;
    end if;
    if v_notification.category = 'confirmation_reminder' then
      if (v_notification.body->>'student_id') !~
        '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' then
        return false;
      end if;
      v_student_id := (v_notification.body->>'student_id')::uuid;
      return v_trip.status = 'scheduled'
        and p_now < v_trip.confirmation_deadline
        and exists (
          select 1
          from public.trip_passengers tp
          where tp.trip_id = v_trip.id and tp.student_id = v_student_id
            and tp.removed_at is null and tp.confirmation_status = 'pending'
            and (
              exists (
                select 1
                from public.student_guardians sg
                where sg.student_id = tp.student_id
                  and sg.guardian_user_id = p_user_id
                  and sg.status = 'active'
              )
              or exists (
                select 1
                from public.students s
                where s.id = tp.student_id and s.profile_id = p_user_id
              )
            )
        );
    elsif v_notification.category = 'confirmation_available' then
      return v_trip.status = 'scheduled' and p_now < v_trip.confirmation_deadline;
    elsif v_notification.category = 'trip_started' then
      return v_trip.status = 'active' and v_trip.started_at is not null;
    elsif v_notification.category = 'proximity' then
      if (v_notification.body->>'student_id') !~
        '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' then
        return false;
      end if;
      if v_notification.body->>'eta_revision' is null
        or not pg_catalog.pg_input_is_valid(
          v_notification.body->>'eta_revision', 'bigint'
        )
        or v_notification.body->>'eta_at' is null
        or not pg_catalog.pg_input_is_valid(
          v_notification.body->>'eta_at', 'timestamptz'
        ) then
        return false;
      end if;
      v_student_id := (v_notification.body->>'student_id')::uuid;
      return v_trip.status = 'active'
        and exists (
          select 1
          from public.trip_passengers tp
          join public.fleet_enrollments enrollment
            on enrollment.id = tp.enrollment_id
           and enrollment.fleet_id = tp.fleet_id
          join public.routes route on route.id = v_trip.route_id
           and route.fleet_id = v_trip.fleet_id
          where tp.trip_id = v_trip.id
            and tp.student_id = v_student_id
            and tp.removed_at is null
            and tp.confirmation_status = 'confirmed'
            and tp.operation_status in ('waiting', 'boarded')
            and enrollment.status = 'active'
            and tp.eta_at is not null
            and tp.eta_calculated_at is not null
            and tp.eta_calculated_at <= p_now
            and tp.eta_valid_until > p_now
            and tp.eta_at >= p_now
            and tp.eta_revision = v_trip.route_revision
            and (v_notification.body->>'eta_revision')::bigint = tp.eta_revision
            and (v_notification.body->>'eta_at')::timestamptz = tp.eta_at
            and exists (
              select 1
              from public.trip_route_calculations calculation
              where calculation.trip_id = v_trip.id
                and calculation.revision = tp.eta_revision
                and calculation.status = 'calculated'
                and calculation.result is not null
                and calculation.applied_at is not null
            )
            and tp.eta_at <= p_now
              + make_interval(mins => coalesce(route.proximity_minutes, 10))
        );
    elsif v_notification.category in ('boarded', 'dropped_off', 'absent', 'school_arrival', 'arrival') then
      return p_now < v_notification.expires_at;
    end if;
  end if;

  return true;
end;
$$;

-- The evaluator is called when a current provider ETA is accepted.  It is
-- deliberately private and clock-driven; offline GPS and manual ordering do
-- not call it.  The planning lock plus the trip row lock make the state check
-- immediately before enqueue deterministic with trip operations.
create or replace function private.evaluate_trip_proximity(
  p_trip_id uuid,
  p_now timestamptz
) returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_trip public.trips%rowtype;
  v_passenger public.trip_passengers%rowtype;
  v_route_minutes integer := 10;
  v_recipient_ids uuid[];
  v_notification_id uuid;
  v_event_key text;
  v_expires_at timestamptz;
  v_eligible boolean;
  v_count integer := 0;
begin
  if p_trip_id is null or p_now is null or not isfinite(p_now) then
    perform private.raise_api_error('invalid_input', 'Trip and clock are required', 400);
  end if;

  perform private.lock_planning();
  select * into v_trip
  from public.trips t
  where t.id = p_trip_id
  for update;
  if not found or v_trip.status <> 'active' then
    return 0;
  end if;

  select coalesce(r.proximity_minutes, 10)
  into v_route_minutes
  from public.routes r
  where r.id = v_trip.route_id and r.fleet_id = v_trip.fleet_id;
  v_route_minutes := greatest(1, least(60, coalesce(v_route_minutes, 10)));

  for v_passenger in
    select p.*
    from public.trip_passengers p
    where p.trip_id = v_trip.id
      and p.removed_at is null
      and p.confirmation_status = 'confirmed'
      and p.operation_status in ('waiting', 'boarded')
      and p.eta_at is not null
      and p.eta_calculated_at is not null
      and p.eta_calculated_at <= p_now
      and p.eta_valid_until > p_now
      and p.eta_at >= p_now
      and p.eta_revision = v_trip.route_revision
      and p.eta_at <= p_now + make_interval(mins => v_route_minutes)
      and exists (
        select 1
        from public.fleet_enrollments e
        where e.id = p.enrollment_id
          and e.fleet_id = p.fleet_id
          and e.status = 'active'
      )
      and exists (
        select 1
        from public.trip_route_calculations calculation
        where calculation.trip_id = v_trip.id
          and calculation.revision = p.eta_revision
          and calculation.status = 'calculated'
          and calculation.result is not null
          and calculation.applied_at is not null
      )
    order by p.student_id
    for update
  loop
    v_event_key := 'trip:' || v_trip.id::text || ':'
      || v_passenger.student_id::text || ':approaching';
    if exists (
      select 1 from public.notifications n
      where n.fleet_id = v_trip.fleet_id and n.event_key = v_event_key
    ) then
      continue;
    end if;

    -- Re-read the mutable eligibility immediately before enqueueing.  This
    -- also makes the intended state check clear to future delivery changes.
    select exists (
      select 1
      from public.trip_passengers p
      join public.fleet_enrollments e
        on e.id = p.enrollment_id and e.fleet_id = p.fleet_id
      where p.id = v_passenger.id
        and p.trip_id = v_trip.id
        and p.removed_at is null
        and p.confirmation_status = 'confirmed'
        and p.operation_status in ('waiting', 'boarded')
        and e.status = 'active'
        and p.eta_at is not null
        and p.eta_calculated_at <= p_now
        and p.eta_valid_until > p_now
        and p.eta_at >= p_now
        and p.eta_revision = v_trip.route_revision
        and p.eta_at <= p_now + make_interval(mins => v_route_minutes)
        and exists (
          select 1
          from public.trip_route_calculations calculation
          where calculation.trip_id = v_trip.id
            and calculation.revision = p.eta_revision
            and calculation.status = 'calculated'
            and calculation.result is not null
            and calculation.applied_at is not null
        )
    ) into v_eligible;
    if not v_eligible then
      continue;
    end if;

    v_recipient_ids := private.notification_student_recipients(
      v_trip.id, v_passenger.student_id
    );
    if cardinality(coalesce(v_recipient_ids, '{}'::uuid[])) = 0 then
      continue;
    end if;

    v_expires_at := least(
      v_passenger.eta_valid_until,
      p_now + interval '24 hours'
    );
    v_notification_id := private.create_notification(
      v_trip.fleet_id,
      v_event_key,
      'proximity',
      'trip',
      v_trip.id,
      jsonb_build_object(
        'trip_id', v_trip.id,
        'student_id', v_passenger.student_id,
        'eta_at', v_passenger.eta_at,
        'eta_revision', v_passenger.eta_revision
      ),
      p_now,
      v_expires_at,
      v_recipient_ids
    );

    -- C5 delivery workers call this check again.  The local check prevents a
    -- concurrent role/guardian change from leaving an unusable notification
    -- behind when no recipient can still read it.
    if not exists (
      select 1
      from unnest(v_recipient_ids) as recipients(user_id)
      where private.notification_actionable(
        v_notification_id, recipients.user_id, p_now
      )
    ) then
      delete from public.notifications where id = v_notification_id;
      continue;
    end if;
    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

revoke all on function private.evaluate_trip_proximity(uuid, timestamptz)
  from public, anon, authenticated;
grant execute on function private.evaluate_trip_proximity(uuid, timestamptz)
  to postgres, supabase_admin;

-- Extend the existing tracking projection with valid, per-passenger ETA
-- records.  With no provider ETA the JSON value remains NULL, preserving the
-- explicit manual-mode contract.
create or replace function public.get_trip_tracking(
  p_trip_id uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_trip public.trips%rowtype;
  v_current public.trip_current_locations%rowtype;
  v_current_found boolean;
  v_operator boolean;
  v_current_json jsonb;
  v_stops jsonb;
  v_schools jsonb;
  v_eta jsonb;
  v_stale boolean;
  v_topic text;
  v_now timestamptz := clock_timestamp();
begin
  if v_user_id is null then
    perform private.raise_api_error('unauthenticated', 'Authentication required', 401);
  end if;
  if not private.current_user_email_confirmed() then
    perform private.raise_api_error('email_unverified', 'Email confirmation required', 403);
  end if;
  if p_trip_id is null then
    perform private.raise_api_error('invalid_input', 'Trip is required', 400);
  end if;
  select * into v_trip from public.trips where id = p_trip_id;
  if not found or not private.can_track_trip(p_trip_id, v_user_id) then
    perform private.raise_api_error('not_found', 'Trip tracking not found', 404);
  end if;

  v_operator := private.has_fleet_role(v_trip.fleet_id, v_user_id, 'owner')
    or (v_trip.driver_user_id = v_user_id
      and private.has_fleet_role(v_trip.fleet_id, v_user_id, 'driver'));

  select * into v_current from public.trip_current_locations
  where trip_id = p_trip_id;
  v_current_found := found;
  v_stale := not v_current_found
    or v_current.captured_at < v_now - interval '30 seconds';
  v_current_json := case when v_current_found then jsonb_build_object(
    'latitude', v_current.latitude,
    'longitude', v_current.longitude,
    'accuracy', v_current.accuracy,
    'speed', v_current.speed,
    'heading', v_current.heading,
    'captured_at', v_current.captured_at,
    'received_at', v_current.received_at,
    'sequence', v_current.sequence
  ) else 'null'::jsonb end;

  select coalesce(jsonb_agg(
    jsonb_build_object(
      'id', s.id,
      'kind', s.kind,
      'student_id', s.student_id,
      'school_id', s.school_id,
      'position', s.position,
      'latitude', s.latitude,
      'longitude', s.longitude
    ) order by s.position
  ), '[]'::jsonb)
  into v_stops
  from public.trip_stops s
  where s.trip_id = p_trip_id
    and (
      v_operator
      or (
        s.kind = 'home'
        and exists (
          select 1
          from public.trip_passengers p
          where p.trip_id = p_trip_id
            and p.student_id = s.student_id
            and p.removed_at is null
            and p.confirmation_status = 'confirmed'
            and p.operation_status in ('waiting', 'boarded')
            and private.can_view_student(p.student_id, v_user_id)
        )
      )
    );

  select coalesce(jsonb_agg(
    jsonb_build_object(
      'id', s.id,
      'school_id', s.school_id,
      'position', s.position,
      'latitude', s.latitude,
      'longitude', s.longitude
    ) order by s.position
  ), '[]'::jsonb)
  into v_schools
  from public.trip_stops s
  where s.trip_id = p_trip_id and s.kind = 'school';

  select jsonb_agg(
    jsonb_build_object(
      'student_id', p.student_id,
      'eta_at', p.eta_at,
      'calculated_at', p.eta_calculated_at,
      'valid_until', p.eta_valid_until,
      'revision', p.eta_revision
    ) order by p.student_id
  )
  into v_eta
  from public.trip_passengers p
  join public.fleet_enrollments e
    on e.id = p.enrollment_id and e.fleet_id = p.fleet_id
  where p.trip_id = p_trip_id
    and p.removed_at is null
    and p.confirmation_status = 'confirmed'
    and p.operation_status in ('waiting', 'boarded')
    and e.status = 'active'
    and p.eta_at is not null
    and p.eta_calculated_at is not null
    and p.eta_calculated_at <= v_now
    and p.eta_valid_until > v_now
    and p.eta_revision = v_trip.route_revision
    and exists (
      select 1
      from public.trip_route_calculations calculation
      where calculation.trip_id = p.trip_id
        and calculation.revision = p.eta_revision
        and calculation.status = 'calculated'
        and calculation.result is not null
        and calculation.applied_at is not null
    )
    and (v_operator or private.can_view_student(p.student_id, v_user_id));

  v_topic := 'trip:' || p_trip_id::text || ':v' || v_trip.broadcast_epoch::text;
  return jsonb_build_object(
    'trip_id', p_trip_id,
    'topic', v_topic,
    'epoch', v_trip.broadcast_epoch,
    'last_position', v_current_json,
    'stale', v_stale,
    'own_stops', case when v_operator then '[]'::jsonb else v_stops end,
    'schools', v_schools,
    'eta', v_eta
  ) || case when v_operator then jsonb_build_object('operational_stops', v_stops)
    else '{}'::jsonb end;
end;
$$;

revoke all on function public.get_trip_tracking(uuid) from public, anon;
grant execute on function public.get_trip_tracking(uuid) to authenticated, service_role;
