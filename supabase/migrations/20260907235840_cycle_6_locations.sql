-- Cycle 6 Task 1: validated GPS ingestion and the current-position projection.

alter table public.trips
  add column if not exists broadcast_epoch bigint not null default 1;

do $constraint$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.trips'::regclass
      and conname = 'trips_broadcast_epoch_positive'
  ) then
    alter table public.trips
      add constraint trips_broadcast_epoch_positive check (broadcast_epoch > 0);
  end if;
end;
$constraint$;

create table public.trip_location_points (
  id uuid primary key default extensions.gen_random_uuid(),
  fleet_id uuid not null references public.fleets(id) on delete restrict,
  trip_id uuid not null,
  assignment_id uuid not null references public.trip_assignments(id) on delete restrict,
  sequence integer not null,
  captured_at timestamptz not null,
  received_at timestamptz not null default clock_timestamp(),
  latitude numeric not null,
  longitude numeric not null,
  accuracy numeric not null,
  speed numeric,
  heading numeric,
  payload_hash bytea not null,
  constraint trip_location_points_trip_fleet_fk
    foreign key (trip_id, fleet_id)
    references public.trips(id, fleet_id) on delete restrict,
  constraint trip_location_points_sequence_positive check (sequence > 0),
  constraint trip_location_points_latitude_valid check (latitude between -90 and 90),
  constraint trip_location_points_longitude_valid check (longitude between -180 and 180),
  constraint trip_location_points_accuracy_valid check (accuracy between 0 and 10000),
  constraint trip_location_points_speed_valid check (speed is null or speed >= 0),
  constraint trip_location_points_heading_valid check (
    heading is null or (heading >= 0 and heading < 360)
  ),
  constraint trip_location_points_assignment_sequence_key unique (assignment_id, sequence)
);

create index trip_location_points_trip_captured_idx
  on public.trip_location_points (fleet_id, trip_id, captured_at desc);
create index trip_location_points_assignment_idx
  on public.trip_location_points (assignment_id, captured_at desc);

-- Receipts make idempotency independent from the 30-second history sample.
-- A live point can update the current projection before it is copied to the
-- retained history table.
create table public.trip_location_receipts (
  fleet_id uuid not null references public.fleets(id) on delete restrict,
  trip_id uuid not null,
  assignment_id uuid not null references public.trip_assignments(id) on delete restrict,
  sequence integer not null,
  captured_at timestamptz not null,
  received_at timestamptz not null,
  payload_hash bytea not null,
  persisted boolean not null default false,
  primary key (assignment_id, sequence),
  constraint trip_location_receipts_trip_fleet_fk
    foreign key (trip_id, fleet_id)
    references public.trips(id, fleet_id) on delete restrict,
  constraint trip_location_receipts_sequence_positive check (sequence > 0)
);

create index trip_location_receipts_trip_idx
  on public.trip_location_receipts (fleet_id, trip_id, captured_at desc);

create table public.trip_current_locations (
  trip_id uuid primary key references public.trips(id) on delete restrict,
  fleet_id uuid not null references public.fleets(id) on delete restrict,
  assignment_id uuid not null references public.trip_assignments(id) on delete restrict,
  sequence integer not null,
  captured_at timestamptz not null,
  received_at timestamptz not null,
  latitude numeric not null,
  longitude numeric not null,
  accuracy numeric not null,
  speed numeric,
  heading numeric,
  payload_hash bytea not null,
  constraint trip_current_locations_trip_fleet_key
    unique (trip_id, fleet_id),
  constraint trip_current_locations_sequence_positive check (sequence > 0),
  constraint trip_current_locations_latitude_valid check (latitude between -90 and 90),
  constraint trip_current_locations_longitude_valid check (longitude between -180 and 180),
  constraint trip_current_locations_accuracy_valid check (accuracy between 0 and 10000),
  constraint trip_current_locations_speed_valid check (speed is null or speed >= 0),
  constraint trip_current_locations_heading_valid check (
    heading is null or (heading >= 0 and heading < 360)
  )
);

create index trip_current_locations_fleet_idx
  on public.trip_current_locations (fleet_id, trip_id);

alter table public.trip_location_points enable row level security;
alter table public.trip_location_receipts enable row level security;
alter table public.trip_current_locations enable row level security;
revoke all on public.trip_location_points from public, anon, authenticated, service_role;
revoke all on public.trip_location_receipts from public, anon, authenticated, service_role;
revoke all on public.trip_current_locations from public, anon, authenticated, service_role;

create or replace function private.can_track_trip(
  p_trip_id uuid,
  p_user_id uuid
) returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.trips t
    where t.id = p_trip_id
      and t.status = 'active'
      and (
        private.has_fleet_role(t.fleet_id, p_user_id, 'owner')
        or (
          private.has_fleet_role(t.fleet_id, p_user_id, 'driver')
          and exists (
            select 1
            from public.trip_assignments a
            where a.trip_id = t.id
              and a.valid_until is null
              and a.driver_user_id = p_user_id
          )
        )
        or (
          private.is_active_fleet_member(t.fleet_id, p_user_id)
          and (
            private.has_fleet_role(t.fleet_id, p_user_id, 'guardian')
            or private.has_fleet_role(t.fleet_id, p_user_id, 'student')
          )
          and exists (
            select 1
            from public.trip_passengers p
            join public.fleet_enrollments e
              on e.id = p.enrollment_id and e.fleet_id = p.fleet_id
            where p.trip_id = t.id
              and p.fleet_id = t.fleet_id
              and p.confirmation_status = 'confirmed'
              and p.operation_status in ('waiting', 'boarded')
              and p.removed_at is null
              and e.status = 'active'
              and private.can_view_student(p.student_id, p_user_id)
          )
        )
      )
  );
$$;

revoke all on function private.can_track_trip(uuid, uuid)
  from public, anon, authenticated;
grant execute on function private.can_track_trip(uuid, uuid)
  to postgres, supabase_admin;

create or replace function private.publish_current_location(
  p_trip_id uuid
) returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_trip public.trips%rowtype;
  v_location public.trip_current_locations%rowtype;
  v_topic text;
begin
  select * into v_trip
  from public.trips
  where id = p_trip_id
  for update;
  if not found or v_trip.status <> 'active' then
    return;
  end if;

  select * into v_location
  from public.trip_current_locations
  where trip_id = p_trip_id;
  if not found then
    return;
  end if;

  v_topic := 'trip:' || v_trip.id::text || ':v' || v_trip.broadcast_epoch::text;
  perform realtime.send(
    jsonb_build_object(
      'latitude', v_location.latitude,
      'longitude', v_location.longitude,
      'accuracy', v_location.accuracy,
      'speed', v_location.speed,
      'heading', v_location.heading,
      'captured_at', v_location.captured_at,
      'received_at', v_location.received_at,
      'sequence', v_location.sequence
    ),
    'location',
    v_topic,
    true
  );
end;
$$;

revoke all on function private.publish_current_location(uuid)
  from public, anon, authenticated;
grant execute on function private.publish_current_location(uuid)
  to postgres, supabase_admin;
grant execute on function realtime.send(jsonb, text, text, boolean)
  to supabase_admin;

create or replace function public.ingest_trip_locations(
  p_trip_id uuid,
  p_assignment_id uuid,
  p_points jsonb,
  p_live boolean
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_trip public.trips%rowtype;
  v_assignment public.trip_assignments%rowtype;
  v_point jsonb;
  v_sequence integer;
  v_captured_at timestamptz;
  v_latitude numeric;
  v_longitude numeric;
  v_accuracy numeric;
  v_speed numeric;
  v_heading numeric;
  v_hash bytea;
  v_existing_hash bytea;
  v_receipt_found boolean;
  v_now timestamptz;
  v_seen_sequences integer[] := '{}'::integer[];
  v_new_points jsonb[] := '{}'::jsonb[];
  v_new_count integer := 0;
  v_duplicate_count integer := 0;
  v_ignored_count integer := 0;
  v_current_updated integer := 0;
  v_should_persist boolean;
  v_current public.trip_current_locations%rowtype;
begin
  if v_user_id is null then
    perform private.raise_api_error('unauthenticated', 'Authentication required', 401);
  end if;
  if p_trip_id is null or p_assignment_id is null or p_live is null then
    perform private.raise_api_error('invalid_input', 'Trip, assignment and mode are required', 400);
  end if;
  if p_points is null or jsonb_typeof(p_points) <> 'array'
    or jsonb_array_length(p_points) = 0 or jsonb_array_length(p_points) > 200 then
    perform private.raise_api_error('invalid_input', 'GPS batch must contain 1 to 200 points', 400);
  end if;
  if not private.current_user_email_confirmed() then
    perform private.raise_api_error('email_unverified', 'Email confirmation required', 403);
  end if;

  perform private.lock_planning();
  v_now := clock_timestamp();
  select * into v_trip
  from public.trips
  where id = p_trip_id
  for update;
  if not found then
    perform private.raise_api_error('not_found', 'Trip not found', 404);
  end if;

  select * into v_assignment
  from public.trip_assignments
  where id = p_assignment_id and trip_id = p_trip_id and fleet_id = v_trip.fleet_id
  for update;
  if not found or v_assignment.driver_user_id <> v_user_id
    or not private.has_fleet_role(v_trip.fleet_id, v_user_id, 'driver') then
    perform private.raise_api_error('not_found', 'Trip assignment not found', 404);
  end if;
  if p_live and (
    v_trip.status <> 'active'
    or v_trip.started_at is null
    or v_assignment.valid_until is not null
  ) then
    perform private.raise_api_error('invalid_transition', 'Live GPS requires an active trip assignment', 409);
  end if;

  for v_point in select value from jsonb_array_elements(p_points)
  loop
    if jsonb_typeof(v_point) is distinct from 'object'
      or not (v_point ? 'sequence')
      or jsonb_typeof(v_point->'sequence') is distinct from 'number'
      or not pg_input_is_valid(v_point->>'sequence', 'integer')
      or not (v_point ? 'captured_at')
      or jsonb_typeof(v_point->'captured_at') is distinct from 'string'
      or not pg_input_is_valid(v_point->>'captured_at', 'timestamptz')
      or not (v_point ? 'latitude')
      or jsonb_typeof(v_point->'latitude') is distinct from 'number'
      or not pg_input_is_valid(v_point->>'latitude', 'numeric')
      or not (v_point ? 'longitude')
      or jsonb_typeof(v_point->'longitude') is distinct from 'number'
      or not pg_input_is_valid(v_point->>'longitude', 'numeric')
      or not (v_point ? 'accuracy')
      or jsonb_typeof(v_point->'accuracy') is distinct from 'number'
      or not pg_input_is_valid(v_point->>'accuracy', 'numeric')
      or (v_point ? 'speed' and jsonb_typeof(v_point->'speed') not in ('number', 'null'))
      or (v_point ? 'speed' and jsonb_typeof(v_point->'speed') = 'number'
        and not pg_input_is_valid(v_point->>'speed', 'numeric'))
      or (v_point ? 'heading' and jsonb_typeof(v_point->'heading') not in ('number', 'null'))
      or (v_point ? 'heading' and jsonb_typeof(v_point->'heading') = 'number'
        and not pg_input_is_valid(v_point->>'heading', 'numeric')) then
      perform private.raise_api_error('invalid_input', 'Invalid GPS point', 400);
    end if;

    v_sequence := (v_point->>'sequence')::integer;
    v_captured_at := (v_point->>'captured_at')::timestamptz;
    v_latitude := (v_point->>'latitude')::numeric;
    v_longitude := (v_point->>'longitude')::numeric;
    v_accuracy := (v_point->>'accuracy')::numeric;
    v_speed := case when v_point ? 'speed' and jsonb_typeof(v_point->'speed') = 'number'
      then (v_point->>'speed')::numeric else null end;
    v_heading := case when v_point ? 'heading' and jsonb_typeof(v_point->'heading') = 'number'
      then (v_point->>'heading')::numeric else null end;

    if v_sequence <= 0 or v_sequence = any(v_seen_sequences)
      or v_latitude < -90 or v_latitude > 90
      or v_longitude < -180 or v_longitude > 180
      or v_accuracy < 0 or v_accuracy > 10000
      or (v_speed is not null and (v_speed < 0 or v_speed = 'NaN'::numeric))
      or (v_heading is not null and (v_heading < 0 or v_heading >= 360 or v_heading = 'NaN'::numeric))
      or not isfinite(v_captured_at)
      or v_captured_at < v_now - interval '30 days'
      or v_captured_at > v_now + interval '2 minutes'
      or (p_live and v_captured_at < v_now - interval '30 seconds')
      or v_trip.started_at is null
      or v_captured_at < v_trip.started_at
      or (v_trip.ended_at is not null and v_captured_at > v_trip.ended_at) then
      perform private.raise_api_error('invalid_input', 'GPS point is outside the allowed range', 400);
    end if;
    v_seen_sequences := array_append(v_seen_sequences, v_sequence);

    if not exists (
      select 1 from public.trip_assignments a
      where a.id = p_assignment_id and a.trip_id = p_trip_id
        and a.valid_from <= v_captured_at
        and (a.valid_until is null or v_captured_at < a.valid_until)
    ) then
      perform private.raise_api_error('invalid_input', 'GPS capture is outside its assignment', 400);
    end if;

    v_hash := extensions.digest(v_point::text, 'sha256');
    v_receipt_found := false;
    select payload_hash, true
    into v_existing_hash, v_receipt_found
    from public.trip_location_receipts
    where assignment_id = p_assignment_id and sequence = v_sequence;
    if v_receipt_found then
      if v_existing_hash <> v_hash then
        perform private.raise_api_error('idempotency_conflict', 'GPS payload differs', 409);
      end if;
      v_duplicate_count := v_duplicate_count + 1;
    else
      v_new_count := v_new_count + 1;
      v_new_points := array_append(v_new_points, v_point);
    end if;
  end loop;

  select * into v_current
  from public.trip_current_locations
  where trip_id = p_trip_id;
  if p_live and v_new_count > 0 and found
    and v_current.received_at > v_now - interval '1 second' then
    perform private.raise_api_error('rate_limited', 'GPS update is too frequent', 429);
  end if;

  foreach v_point in array v_new_points
  loop
    v_sequence := (v_point->>'sequence')::integer;
    v_captured_at := (v_point->>'captured_at')::timestamptz;
    v_latitude := (v_point->>'latitude')::numeric;
    v_longitude := (v_point->>'longitude')::numeric;
    v_accuracy := (v_point->>'accuracy')::numeric;
    v_speed := case when v_point ? 'speed' and jsonb_typeof(v_point->'speed') = 'number'
      then (v_point->>'speed')::numeric else null end;
    v_heading := case when v_point ? 'heading' and jsonb_typeof(v_point->'heading') = 'number'
      then (v_point->>'heading')::numeric else null end;
    v_hash := extensions.digest(v_point::text, 'sha256');

    -- Keep every receipt for idempotency, but retain at most one history
    -- sample per fixed 30-second capture bucket.  A fixed bucket is symmetric
    -- for ascending and descending offline batches: a newer point cannot hide
    -- an older unsampled interval merely because it arrived first.
    v_should_persist := not exists (
      select 1
      from public.trip_location_points history
      where history.assignment_id = p_assignment_id
        and date_bin('30 seconds', history.captured_at, 'epoch'::timestamptz)
          = date_bin('30 seconds', v_captured_at, 'epoch'::timestamptz)
    );
    if v_should_persist then
      insert into public.trip_location_points (
        fleet_id, trip_id, assignment_id, sequence, captured_at, received_at,
        latitude, longitude, accuracy, speed, heading, payload_hash
      ) values (
        v_trip.fleet_id, p_trip_id, p_assignment_id, v_sequence, v_captured_at, v_now,
        v_latitude, v_longitude, v_accuracy, v_speed, v_heading, v_hash
      ) on conflict (assignment_id, sequence) do nothing;
      update public.trip_location_receipts
      set persisted = true
      where assignment_id = p_assignment_id and sequence = v_sequence;
    end if;
    insert into public.trip_location_receipts (
      fleet_id, trip_id, assignment_id, sequence, captured_at, received_at,
      payload_hash, persisted
    ) values (
      v_trip.fleet_id, p_trip_id, p_assignment_id, v_sequence, v_captured_at, v_now,
      v_hash, v_should_persist
    ) on conflict (assignment_id, sequence) do nothing;

    if p_live then
      select * into v_current
      from public.trip_current_locations
      where trip_id = p_trip_id;
      if not found
        or v_captured_at > v_current.captured_at
        or (v_captured_at = v_current.captured_at and v_sequence > v_current.sequence) then
        insert into public.trip_current_locations (
          trip_id, fleet_id, assignment_id, sequence, captured_at, received_at,
          latitude, longitude, accuracy, speed, heading, payload_hash
        ) values (
          p_trip_id, v_trip.fleet_id, p_assignment_id, v_sequence, v_captured_at, v_now,
          v_latitude, v_longitude, v_accuracy, v_speed, v_heading, v_hash
        ) on conflict (trip_id) do update set
          fleet_id = excluded.fleet_id,
          assignment_id = excluded.assignment_id,
          sequence = excluded.sequence,
          captured_at = excluded.captured_at,
          received_at = excluded.received_at,
          latitude = excluded.latitude,
          longitude = excluded.longitude,
          accuracy = excluded.accuracy,
          speed = excluded.speed,
          heading = excluded.heading,
          payload_hash = excluded.payload_hash
        where excluded.captured_at > public.trip_current_locations.captured_at
          or (excluded.captured_at = public.trip_current_locations.captured_at
            and excluded.sequence > public.trip_current_locations.sequence);
        if found then
          v_current_updated := v_current_updated + 1;
        end if;
      else
        v_ignored_count := v_ignored_count + 1;
      end if;
    else
      v_ignored_count := v_ignored_count + 1;
    end if;
  end loop;

  if p_live and v_current_updated > 0 then
    perform private.publish_current_location(p_trip_id);
  end if;

  return jsonb_build_object(
    'accepted', v_new_count,
    'duplicates', v_duplicate_count,
    'ignored', v_ignored_count,
    'current_updated', v_current_updated
  );
end;
$$;

revoke all on function public.ingest_trip_locations(uuid, uuid, jsonb, boolean)
  from public, anon;
grant execute on function public.ingest_trip_locations(uuid, uuid, jsonb, boolean)
  to authenticated, service_role;

-- Preserve a recent last-known sample at an operational event, even if its
-- regular bucket was already sampled. This does not invent an event position
-- or attach today's GPS to a historical offline fact.
create function private.persist_event_location()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.payload->>'offline' = 'true' then
    return new;
  end if;
  insert into public.trip_location_points(
    fleet_id,trip_id,assignment_id,sequence,captured_at,received_at,
    latitude,longitude,accuracy,speed,heading,payload_hash
  )
  select c.fleet_id,c.trip_id,c.assignment_id,c.sequence,c.captured_at,c.received_at,
    c.latitude,c.longitude,c.accuracy,c.speed,c.heading,r.payload_hash
  from public.trip_current_locations c
  join public.trip_location_receipts r
    on r.assignment_id=c.assignment_id and r.sequence=c.sequence
  where c.trip_id=new.trip_id and c.fleet_id=new.fleet_id
    and c.captured_at <= new.occurred_at
    and c.captured_at >= new.occurred_at-interval '30 seconds'
    and c.captured_at >= clock_timestamp()-interval '30 seconds'
  on conflict (assignment_id,sequence) do nothing;

  update public.trip_location_receipts r set persisted=true
  from public.trip_current_locations c
  where c.trip_id=new.trip_id and c.fleet_id=new.fleet_id
    and r.assignment_id=c.assignment_id and r.sequence=c.sequence
    and not r.persisted
    and exists(select 1 from public.trip_location_points p
      where p.assignment_id=r.assignment_id and p.sequence=r.sequence);
  return new;
end;
$$;
revoke all on function private.persist_event_location() from public,anon,authenticated;
grant execute on function private.persist_event_location() to postgres,supabase_admin;
create trigger trip_events_preserve_location after insert on public.trip_events
for each row execute function private.persist_event_location();
