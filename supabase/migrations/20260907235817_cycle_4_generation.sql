create table public.trip_passengers (
  id uuid primary key default extensions.gen_random_uuid(),
  fleet_id uuid not null references public.fleets(id) on delete restrict,
  trip_id uuid not null,
  enrollment_id uuid not null references public.fleet_enrollments(id) on delete restrict,
  student_id uuid not null references public.students(id) on delete restrict,
  confirmation_status text not null default 'pending',
  operation_status text not null default 'waiting',
  confirmation_by uuid references public.profiles(id) on delete set null,
  confirmation_at timestamptz,
  removed_at timestamptz,
  removal_reason text,
  constraint trip_passengers_trip_fleet_fk
    foreign key (trip_id, fleet_id)
    references public.trips(id, fleet_id)
    on delete restrict,
  constraint trip_passengers_trip_enrollment_key unique (trip_id, enrollment_id),
  constraint trip_passengers_trip_student_key unique (trip_id, student_id),
  constraint trip_passengers_confirmation_status_valid check (
    confirmation_status in ('pending', 'confirmed', 'declined', 'expired')
  ),
  constraint trip_passengers_operation_status_valid check (
    operation_status in ('waiting', 'boarded', 'dropped_off', 'absent')
  ),
  constraint trip_passengers_confirmation_dates_valid check (
    (confirmation_status = 'pending' and confirmation_by is null and confirmation_at is null)
    or (confirmation_status <> 'pending')
  ),
  constraint trip_passengers_removed_valid check (
    (removed_at is null and removal_reason is null)
    or (removed_at is not null and removal_reason is not null and btrim(removal_reason) <> '')
  )
);

create index trip_passengers_fleet_idx on public.trip_passengers (fleet_id, trip_id);
create index trip_passengers_enrollment_idx on public.trip_passengers (enrollment_id);

create table public.trip_stops (
  id uuid primary key default extensions.gen_random_uuid(),
  fleet_id uuid not null references public.fleets(id) on delete restrict,
  trip_id uuid not null,
  kind text not null,
  student_id uuid references public.students(id) on delete restrict,
  school_id uuid references public.schools(id) on delete restrict,
  position integer not null,
  address_snapshot jsonb not null default '{}'::jsonb,
  latitude numeric,
  longitude numeric,
  reached_at timestamptz,
  constraint trip_stops_trip_fleet_fk
    foreign key (trip_id, fleet_id)
    references public.trips(id, fleet_id)
    on delete restrict,
  constraint trip_stops_kind_valid check (kind in ('origin', 'school', 'home', 'destination')),
  constraint trip_stops_position_valid check (position > 0),
  constraint trip_stops_reference_valid check (
    (kind = 'school' and school_id is not null and student_id is null)
    or (kind = 'home' and student_id is not null and school_id is null)
    or (kind in ('origin', 'destination') and student_id is null and school_id is null)
  ),
  constraint trip_stops_coordinates_pair check ((latitude is null) = (longitude is null)),
  constraint trip_stops_latitude_valid check (latitude is null or latitude between -90 and 90),
  constraint trip_stops_longitude_valid check (longitude is null or longitude between -180 and 180),
  constraint trip_stops_trip_position_key unique (trip_id, position)
);

create index trip_stops_fleet_trip_idx on public.trip_stops (fleet_id, trip_id, position);

create table public.trip_assignments (
  id uuid primary key default extensions.gen_random_uuid(),
  fleet_id uuid not null references public.fleets(id) on delete restrict,
  trip_id uuid not null,
  van_id uuid,
  driver_user_id uuid references public.profiles(id) on delete restrict,
  valid_from timestamptz not null default now(),
  valid_until timestamptz,
  reason text,
  actor_user_id uuid references public.profiles(id) on delete set null,
  constraint trip_assignments_trip_fleet_fk
    foreign key (trip_id, fleet_id)
    references public.trips(id, fleet_id)
    on delete restrict,
  constraint trip_assignments_van_fleet_fk
    foreign key (fleet_id, van_id)
    references public.vans(fleet_id, id)
    on delete restrict,
  constraint trip_assignments_dates_valid check (valid_until is null or valid_until >= valid_from),
  constraint trip_assignments_reason_valid check (reason is null or btrim(reason) <> '')
);

create unique index trip_assignments_current_trip_key
  on public.trip_assignments (trip_id)
  where valid_until is null;
create index trip_assignments_resource_idx
  on public.trip_assignments (fleet_id, van_id, driver_user_id, valid_until);

create table public.trip_events (
  id bigint generated always as identity primary key,
  fleet_id uuid not null references public.fleets(id) on delete restrict,
  trip_id uuid not null,
  command_id uuid not null,
  event_sequence bigint not null,
  kind text not null,
  actor_user_id uuid references public.profiles(id) on delete set null,
  occurred_at timestamptz not null,
  received_at timestamptz not null default now(),
  payload jsonb not null default '{}'::jsonb,
  payload_hash bytea not null,
  result text not null default 'applied',
  constraint trip_events_trip_fleet_fk
    foreign key (trip_id, fleet_id)
    references public.trips(id, fleet_id)
    on delete restrict,
  constraint trip_events_trip_command_key unique (trip_id, command_id),
  constraint trip_events_trip_sequence_key unique (trip_id, event_sequence),
  constraint trip_events_sequence_positive check (event_sequence > 0),
  constraint trip_events_kind_not_blank check (btrim(kind) <> ''),
  constraint trip_events_payload_object check (jsonb_typeof(payload) = 'object')
);

create index trip_events_fleet_trip_idx on public.trip_events (fleet_id, trip_id, event_sequence);

alter table public.trip_passengers enable row level security;
alter table public.trip_stops enable row level security;
alter table public.trip_assignments enable row level security;
alter table public.trip_events enable row level security;

revoke all on public.trip_passengers from anon, authenticated;
revoke all on public.trip_stops from anon, authenticated;
revoke all on public.trip_assignments from anon, authenticated;
revoke all on public.trip_events from anon, authenticated;

create function private.append_trip_event(
  p_trip_id uuid,
  p_command_id uuid,
  p_kind text,
  p_payload jsonb,
  p_occurred_at timestamptz
) returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_trip public.trips%rowtype;
  v_event public.trip_events%rowtype;
  v_hash bytea;
  v_actor uuid := auth.uid();
  v_sequence bigint;
  v_event_id bigint;
begin
  if p_trip_id is null or p_command_id is null or p_kind is null or btrim(p_kind) = ''
    or p_payload is null or jsonb_typeof(p_payload) <> 'object' or p_occurred_at is null then
    perform private.raise_api_error('invalid_input', 'Invalid trip event', 400);
  end if;
  v_hash := extensions.digest(p_payload::text, 'sha256');

  select * into v_trip from public.trips where id = p_trip_id for update;
  if not found then
    perform private.raise_api_error('not_found', 'Trip not found', 404);
  end if;

  select * into v_event
  from public.trip_events
  where trip_id = p_trip_id and command_id = p_command_id;
  if found then
    if v_event.kind <> p_kind or v_event.actor_user_id is distinct from v_actor
      or v_event.payload_hash <> v_hash then
      perform private.raise_api_error('idempotency_conflict', 'Command payload differs', 409);
    end if;
    return v_event.id;
  end if;

  update public.trips
  set event_sequence = event_sequence + 1
  where id = p_trip_id
  returning event_sequence into v_sequence;

  insert into public.trip_events (
    fleet_id, trip_id, command_id, event_sequence, kind, actor_user_id,
    occurred_at, payload, payload_hash
  ) values (
    v_trip.fleet_id, p_trip_id, p_command_id, v_sequence, p_kind, v_actor,
    p_occurred_at, p_payload, v_hash
  ) returning id into v_event_id;
  return v_event_id;
end;
$$;

revoke all on function private.append_trip_event(uuid, uuid, text, jsonb, timestamptz)
  from public, anon, authenticated;
grant execute on function private.append_trip_event(uuid, uuid, text, jsonb, timestamptz)
  to postgres, supabase_admin;

create function private.generate_trips(
  p_service_date date,
  p_now timestamptz
) returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_schedule record;
  v_trip_id uuid;
  v_day_id uuid;
  v_start_at timestamptz;
  v_end_at timestamptz;
  v_deadline timestamptz;
  v_created integer := 0;
  v_command_id uuid;
  v_passenger record;
  v_stop record;
  v_home_position integer;
begin
  if p_service_date is null or p_now is null then
    perform private.raise_api_error('invalid_input', 'Service date and clock are required', 400);
  end if;
  perform private.lock_planning();

  for v_schedule in
    select rs.*, r.van_id, r.driver_user_id, r.direction
    from public.route_schedules rs
    join public.routes r on r.id = rs.route_id and r.fleet_id = rs.fleet_id
    where rs.status = 'active'
      and r.status = 'active'
      and p_service_date between rs.valid_from and rs.valid_until
      and extract(isodow from p_service_date)::smallint = any(rs.weekdays)
      and not exists (
        select 1 from public.route_service_exceptions e
        where e.fleet_id = rs.fleet_id and e.route_id = rs.route_id
          and e.service_date = p_service_date and e.enabled = false
      )
    order by rs.fleet_id, rs.id
  loop
    v_start_at := (p_service_date + v_schedule.starts_at) at time zone v_schedule.timezone;
    v_end_at := (
      p_service_date + case when v_schedule.ends_next_day then 1 else 0 end
      + v_schedule.ends_at
    ) at time zone v_schedule.timezone;
    v_deadline := v_start_at - make_interval(mins => v_schedule.confirmation_minutes);
    v_trip_id := null;

    insert into public.service_days (fleet_id, service_date)
    values (v_schedule.fleet_id, p_service_date)
    on conflict (fleet_id, service_date) do nothing;
    select id into v_day_id
    from public.service_days
    where fleet_id = v_schedule.fleet_id and service_date = p_service_date;

    insert into public.trips (
      fleet_id, service_day_id, route_id, schedule_id, service_date,
      planned_start_at, reserved_until, confirmation_deadline, status,
      van_id, driver_user_id
    ) values (
      v_schedule.fleet_id, v_day_id, v_schedule.route_id, v_schedule.id, p_service_date,
      v_start_at, v_end_at, v_deadline, 'scheduled', v_schedule.van_id,
      v_schedule.driver_user_id
    )
    on conflict (schedule_id, service_date) do nothing
    returning id into v_trip_id;

    if v_trip_id is null then
      continue;
    end if;
    v_created := v_created + 1;

    insert into public.trip_assignments (
      fleet_id, trip_id, van_id, driver_user_id, valid_from, reason
    ) values (
      v_schedule.fleet_id, v_trip_id, v_schedule.van_id, v_schedule.driver_user_id,
      p_now, 'generated'
    );

    insert into public.trip_stops (
      fleet_id, trip_id, kind, position, address_snapshot,
      latitude, longitude
    ) values (
      v_schedule.fleet_id, v_trip_id, 'origin', 1,
      jsonb_build_object('label', (select r.origin_label from public.routes r
        where r.id = v_schedule.route_id and r.fleet_id = v_schedule.fleet_id)),
      (select r.origin_latitude from public.routes r
        where r.id = v_schedule.route_id and r.fleet_id = v_schedule.fleet_id),
      (select r.origin_longitude from public.routes r
        where r.id = v_schedule.route_id and r.fleet_id = v_schedule.fleet_id)
    );

    for v_passenger in
      select tr.enrollment_id, tr.student_id, e.student_id as enrolled_student_id
      from public.transport_reservations tr
      join public.fleet_enrollments e
        on e.id = tr.enrollment_id and e.fleet_id = tr.fleet_id
      where tr.fleet_id = v_schedule.fleet_id
        and tr.schedule_id = v_schedule.id
        and tr.weekday = extract(isodow from p_service_date)::smallint
        and tr.valid_from <= p_service_date
        and tr.valid_until >= p_service_date
        and tr.status = 'active'
        and e.fleet_id = v_schedule.fleet_id
        and e.status = 'active'
    loop
      insert into public.trip_passengers (
        fleet_id, trip_id, enrollment_id, student_id
      ) values (
        v_schedule.fleet_id, v_trip_id, v_passenger.enrollment_id,
        v_passenger.enrolled_student_id
      ) on conflict (trip_id, enrollment_id) do nothing;
    end loop;

    for v_stop in
      select 'school'::text as kind, null::uuid as student_id, rs.school_id,
             rs.position, jsonb_build_object(
               'name', s.name, 'street', s.street, 'street_number', s.street_number,
               'neighborhood', s.neighborhood, 'city_name', s.city_name,
               'city_ibge_code', s.city_ibge_code, 'state_code', s.state_code
             ) as address_snapshot, s.latitude, s.longitude
      from public.route_schools rs
      join public.schools s on s.id = rs.school_id
      where rs.route_id = v_schedule.route_id and rs.fleet_id = v_schedule.fleet_id
      order by rs.position
    loop
      insert into public.trip_stops (
        fleet_id, trip_id, kind, student_id, school_id, position,
        address_snapshot, latitude, longitude
      ) values (
        v_schedule.fleet_id, v_trip_id, v_stop.kind, v_stop.student_id, v_stop.school_id,
               case when v_schedule.direction = 'going' then 100000 else 1000 end
                 + v_stop.position,
               v_stop.address_snapshot, v_stop.latitude, v_stop.longitude
      );
    end loop;

  v_home_position := case when v_schedule.direction = 'going' then 1000 else 100000 end;
    for v_stop in
      select tp.student_id, jsonb_build_object(
               'postal_code', s.postal_code, 'street', s.street,
               'street_number', s.street_number, 'address_complement', s.address_complement,
               'neighborhood', s.neighborhood, 'city_name', s.city_name,
               'city_ibge_code', s.city_ibge_code, 'state_code', s.state_code
             ) as address_snapshot, s.latitude, s.longitude
      from public.trip_passengers tp
      join public.students s on s.id = tp.student_id
      where tp.trip_id = v_trip_id and tp.removed_at is null
      order by tp.student_id
    loop
      insert into public.trip_stops (
        fleet_id, trip_id, kind, student_id, position,
        address_snapshot, latitude, longitude
      ) values (
        v_schedule.fleet_id, v_trip_id, 'home', v_stop.student_id, v_home_position,
        v_stop.address_snapshot, v_stop.latitude, v_stop.longitude
      );
      v_home_position := v_home_position + 1;
    end loop;

    insert into public.trip_stops (
      fleet_id, trip_id, kind, position, address_snapshot,
      latitude, longitude
    ) values (
      v_schedule.fleet_id, v_trip_id, 'destination', 200000,
      jsonb_build_object('label', (select r.destination_label from public.routes r
        where r.id = v_schedule.route_id and r.fleet_id = v_schedule.fleet_id)),
      (select r.destination_latitude from public.routes r
        where r.id = v_schedule.route_id and r.fleet_id = v_schedule.fleet_id),
      (select r.destination_longitude from public.routes r
        where r.id = v_schedule.route_id and r.fleet_id = v_schedule.fleet_id)
    );

    v_command_id := extensions.gen_random_uuid();
    perform private.append_trip_event(
      v_trip_id, v_command_id, 'trip_generated',
      jsonb_build_object('service_date', p_service_date), p_now
    );
  end loop;
  return v_created;
end;
$$;

revoke all on function private.generate_trips(date, timestamptz)
  from public, anon, authenticated;
grant execute on function private.generate_trips(date, timestamptz)
  to postgres, supabase_admin;
