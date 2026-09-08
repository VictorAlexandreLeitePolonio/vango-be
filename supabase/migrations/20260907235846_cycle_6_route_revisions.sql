-- Cycle 6 Task 4: versioned route inputs and provider-independent CAS.
-- This migration stores only a normalized result supplied by the internal
-- service role.  It does not call or emulate a maps provider.

alter table public.trips
  add column if not exists route_revision bigint not null default 1;

do $constraint$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.trips'::regclass
      and conname = 'trips_route_revision_positive'
  ) then
    alter table public.trips
      add constraint trips_route_revision_positive check (route_revision > 0);
  end if;
end;
$constraint$;

create table public.trip_route_calculations (
  id uuid primary key default extensions.gen_random_uuid(),
  trip_id uuid not null,
  fleet_id uuid not null references public.fleets(id) on delete restrict,
  revision bigint not null,
  status text not null default 'pending',
  input jsonb not null,
  input_hash bytea not null,
  applied_input_hash bytea,
  result jsonb,
  created_at timestamptz not null default clock_timestamp(),
  applied_at timestamptz,
  error_code text,
  constraint trip_route_calculations_trip_fleet_fk
    foreign key (trip_id, fleet_id)
    references public.trips(id, fleet_id) on delete restrict,
  constraint trip_route_calculations_revision_positive check (revision > 0),
  constraint trip_route_calculations_status_valid check (
    status in ('pending', 'manual', 'calculated', 'failed', 'superseded')
  ),
  constraint trip_route_calculations_result_status_valid check (
    (status in ('pending', 'manual', 'failed') and result is null)
    or status = 'superseded'
    or (status = 'calculated' and result is not null)
  ),
  constraint trip_route_calculations_applied_status_valid check (
    (status = 'calculated' and applied_at is not null)
    or status = 'superseded'
    or (status <> 'calculated' and applied_at is null)
  ),
  constraint trip_route_calculations_input_object check (jsonb_typeof(input) = 'object'),
  constraint trip_route_calculations_hash_nonempty check (octet_length(input_hash) > 0),
  constraint trip_route_calculations_applied_hash_nonempty check (
    applied_input_hash is null or octet_length(applied_input_hash) > 0
  )
);

create unique index trip_route_calculations_trip_revision_key
  on public.trip_route_calculations (trip_id, revision);
create index trip_route_calculations_pending_idx
  on public.trip_route_calculations (fleet_id, trip_id, status, revision desc);

alter table public.trip_route_calculations enable row level security;
revoke all on public.trip_route_calculations from public, anon, authenticated, service_role;

create or replace function private.build_trip_route_input(
  p_trip_id uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_trip public.trips%rowtype;
  v_route public.routes%rowtype;
  v_input jsonb;
  v_points jsonb;
  v_passengers jsonb;
  v_schools jsonb;
begin
  select * into v_trip from public.trips where id = p_trip_id;
  if not found then
    return null;
  end if;
  select * into v_route
  from public.routes
  where id = v_trip.route_id and fleet_id = v_trip.fleet_id;
  select coalesce(jsonb_agg(
    jsonb_build_object(
      'id', s.id,
      'kind', s.kind,
      'student_id', s.student_id,
      'school_id', s.school_id,
      'address_snapshot', s.address_snapshot,
      'latitude', s.latitude,
      'longitude', s.longitude,
      'position', s.position,
      'reached_at', s.reached_at
    ) order by s.position, s.id
  ), '[]'::jsonb)
  into v_points
  from public.trip_stops s
  where s.trip_id = p_trip_id;
  select coalesce(jsonb_agg(
    jsonb_build_object(
      'enrollment_id', p.enrollment_id,
      'student_id', p.student_id,
      'school_id', p.school_id,
      'confirmation_status', p.confirmation_status,
      'operation_status', p.operation_status,
      'removed_at', p.removed_at
    ) order by p.student_id
  ), '[]'::jsonb)
  into v_passengers
  from public.trip_passengers p
  where p.trip_id = p_trip_id;
  select coalesce(jsonb_agg(
    jsonb_build_object(
      'school_id', s.school_id,
      'position', s.position
    ) order by s.position
  ), '[]'::jsonb)
  into v_schools
  from public.trip_stops s
  where s.trip_id = p_trip_id and s.kind = 'school';
  v_input := jsonb_build_object(
    'trip_id', v_trip.id,
    'revision', v_trip.route_revision,
    'trip_revision', v_trip.revision,
    'departure_at', v_trip.planned_start_at,
    'direction', v_route.direction,
    'route_id', v_route.id,
    'route_routing_revision', v_route.routing_revision,
    'origin', jsonb_build_object(
      'latitude', v_route.origin_latitude,
      'longitude', v_route.origin_longitude,
      'label', v_route.origin_label
    ),
    'destination', jsonb_build_object(
      'latitude', v_route.destination_latitude,
      'longitude', v_route.destination_longitude,
      'label', v_route.destination_label
    ),
    'points', v_points,
    'passengers', v_passengers,
    'school_order', v_schools
  );
  return v_input;
end;
$$;

revoke all on function private.build_trip_route_input(uuid)
  from public, anon, authenticated;
grant execute on function private.build_trip_route_input(uuid)
  to postgres, supabase_admin, service_role;

-- An active trip may receive a route calculation only for an explicitly
-- authorized operational change. A reported incident is the durable
-- authorization; a stop-reorder event is the equivalent owner/driver detour
-- record. Ordinary tracking or passenger updates never open this path.
create or replace function private.trip_has_authorized_route_change(
  p_trip_id uuid
) returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.trip_incidents incident
    where incident.trip_id = p_trip_id
      and incident.resolved_at is null
  )
  or exists (
    select 1
    from public.trip_events event
    join public.trips trip on trip.id = event.trip_id
    where event.trip_id = p_trip_id
      and event.kind = 'stops_reordered'
      and (
        private.has_fleet_role(trip.fleet_id, event.actor_user_id, 'owner')
        or (
          event.actor_user_id = trip.driver_user_id
          and private.has_fleet_role(trip.fleet_id, event.actor_user_id, 'driver')
        )
      )
  );
$$;

revoke all on function private.trip_has_authorized_route_change(uuid)
  from public, anon, authenticated;
grant execute on function private.trip_has_authorized_route_change(uuid)
  to postgres, supabase_admin, service_role;

create or replace function public.request_trip_route_calculation(
  p_trip_id uuid
) returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_trip public.trips%rowtype;
  v_input jsonb;
  v_input_hash bytea;
  v_existing public.trip_route_calculations%rowtype;
  v_has_existing boolean;
  v_revision bigint;
  v_active_exception boolean;
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
  perform private.lock_planning();
  select * into v_trip from public.trips where id = p_trip_id for update;
  if not found then
    perform private.raise_api_error('not_found', 'Trip not found', 404);
  end if;
  if not (
    private.has_fleet_role(v_trip.fleet_id, v_user_id, 'owner')
    or (v_trip.driver_user_id = v_user_id
      and private.has_fleet_role(v_trip.fleet_id, v_user_id, 'driver'))
  ) then
    perform private.raise_api_error('not_found', 'Trip not found', 404);
  end if;
  v_active_exception := v_trip.status = 'active'
    and private.trip_has_authorized_route_change(p_trip_id);
  if v_trip.status not in ('scheduled', 'confirmation_closed')
    and not v_active_exception then
    perform private.raise_api_error('trip_active', 'Active trip keeps its route snapshot', 409);
  end if;
  v_input := private.build_trip_route_input(p_trip_id);
  v_input_hash := extensions.digest(v_input::text, 'sha256');
  select * into v_existing
  from public.trip_route_calculations
  where trip_id = p_trip_id
  order by revision desc
  limit 1
  for update;
  v_has_existing := found;
  if v_has_existing
    and v_existing.status in ('pending', 'manual')
    and v_existing.input_hash = v_input_hash then
    return v_existing.revision;
  end if;
  if v_has_existing
    and v_existing.status = 'calculated'
    and v_existing.applied_input_hash is not null
    and v_existing.applied_input_hash = v_input_hash then
    return v_existing.revision;
  end if;
  if v_has_existing then
    update public.trip_route_calculations
    set status = 'superseded', error_code = 'superseded'
    where trip_id = p_trip_id
      and status in ('pending', 'manual', 'calculated');
  end if;
  v_revision := v_trip.route_revision;
  if v_has_existing or exists (
    select 1 from public.trip_route_calculations
    where trip_id = p_trip_id and revision = v_revision
  ) then
    update public.trips
    set route_revision = route_revision + 1
    where id = p_trip_id
    returning route_revision into v_revision;
    v_input := private.build_trip_route_input(p_trip_id);
    v_input_hash := extensions.digest(v_input::text, 'sha256');
  end if;
  insert into public.trip_route_calculations (
    trip_id, fleet_id, revision, status, input, input_hash
  ) values (
    p_trip_id, v_trip.fleet_id, v_revision, 'pending', v_input, v_input_hash
  );
  return v_revision;
end;
$$;

revoke all on function public.request_trip_route_calculation(uuid)
  from public, anon;
grant execute on function public.request_trip_route_calculation(uuid)
  to authenticated;

create or replace function public.get_route_calculation_input(
  p_trip_id uuid,
  p_revision bigint
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_input jsonb;
begin
  if p_trip_id is null or p_revision is null or p_revision <= 0 then
    perform private.raise_api_error('invalid_input', 'Trip and revision are required', 400);
  end if;
  select input into v_input
  from public.trip_route_calculations
  where trip_id = p_trip_id and revision = p_revision;
  if not found then
    perform private.raise_api_error('not_found', 'Route calculation not found', 404);
  end if;
  return v_input;
end;
$$;

revoke all on function public.get_route_calculation_input(uuid, bigint)
  from public, anon, authenticated;
grant execute on function public.get_route_calculation_input(uuid, bigint)
  to service_role, postgres, supabase_admin;

create or replace function private.validate_route_result(
  p_trip_id uuid,
  p_revision bigint,
  p_result jsonb
) returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_points jsonb;
  v_ordered jsonb;
  v_ids uuid[];
  v_expected uuid[];
  v_school_ids uuid[];
  v_ordered_school_ids uuid[];
  v_direction text;
  v_total_distance numeric;
  v_total_duration numeric;
  v_leg jsonb;
  v_index integer;
begin
  if p_result is null or jsonb_typeof(p_result) is distinct from 'object'
    or not (p_result ? 'revision')
    or jsonb_typeof(p_result->'revision') is distinct from 'number'
    or not pg_catalog.pg_input_is_valid(p_result->>'revision', 'bigint')
    or (p_result->>'revision')::bigint <> p_revision
    or not (p_result ? 'orderedPointIds')
    or jsonb_typeof(p_result->'orderedPointIds') is distinct from 'array'
    or not (p_result ? 'distanceMeters')
    or jsonb_typeof(p_result->'distanceMeters') is distinct from 'number'
    or not pg_catalog.pg_input_is_valid(p_result->>'distanceMeters', 'numeric')
    or not (p_result ? 'durationSeconds')
    or jsonb_typeof(p_result->'durationSeconds') is distinct from 'number'
    or not pg_catalog.pg_input_is_valid(p_result->>'durationSeconds', 'numeric')
    or not (p_result ? 'calculatedAt')
    or jsonb_typeof(p_result->'calculatedAt') is distinct from 'string'
    or not pg_catalog.pg_input_is_valid(p_result->>'calculatedAt', 'timestamptz') then
    return false;
  end if;
  v_total_distance := (p_result->>'distanceMeters')::numeric;
  v_total_duration := (p_result->>'durationSeconds')::numeric;
  if v_total_distance < 0 or v_total_duration < 0
    or v_total_distance = 'NaN'::numeric or v_total_duration = 'NaN'::numeric
    or v_total_distance = 'Infinity'::numeric
    or v_total_duration = 'Infinity'::numeric
    or not isfinite((p_result->>'calculatedAt')::timestamptz) then
    return false;
  end if;
  select input->'points', input->>'direction'
  into v_points, v_direction
  from public.trip_route_calculations
  where trip_id = p_trip_id and revision = p_revision;
  if v_points is null or v_direction is null then
    return false;
  end if;
  v_expected := array(
    select (point->>'id')::uuid
    from jsonb_array_elements(v_points) point
  );
  v_ordered := p_result->'orderedPointIds';
  if jsonb_array_length(v_ordered) <> cardinality(v_expected)
    or exists (
      select 1 from jsonb_array_elements(v_ordered) item
      where jsonb_typeof(item) is distinct from 'string'
        or not pg_catalog.pg_input_is_valid(item #>> '{}', 'uuid')
    ) then
    return false;
  end if;
  v_ids := array(select value::uuid from jsonb_array_elements_text(v_ordered) value);
  if cardinality(v_ids) <> cardinality(array(select distinct id from unnest(v_ids) id))
    or exists (select 1 from unnest(v_ids) id where not (id = any(v_expected))) then
    return false;
  end if;
  if v_ids[1] <> (select (point->>'id')::uuid from jsonb_array_elements(v_points) point where point->>'kind' = 'origin')
    or v_ids[cardinality(v_ids)] <> (select (point->>'id')::uuid from jsonb_array_elements(v_points) point where point->>'kind' = 'destination') then
    return false;
  end if;
  v_school_ids := array(
    select (point->>'id')::uuid
    from jsonb_array_elements(v_points) point
    join jsonb_array_elements(
      (select input->'school_order'
       from public.trip_route_calculations
       where trip_id = p_trip_id and revision = p_revision)
    ) school_order
      on school_order->>'school_id' = point->>'school_id'
    where point->>'kind' = 'school'
    order by (school_order->>'position')::integer
  );
  v_ordered_school_ids := array(
    select id from unnest(v_ids) with ordinality ordered(id, position)
    where id = any(v_school_ids)
    order by position
  );
  if v_school_ids is distinct from v_ordered_school_ids then
    return false;
  end if;
  if exists (
    select 1
    from public.trip_passengers passenger
    join public.trip_stops home
      on home.trip_id = passenger.trip_id
     and home.kind = 'home'
     and home.student_id = passenger.student_id
    join public.trip_stops school
      on school.trip_id = passenger.trip_id
     and school.kind = 'school'
     and school.school_id = passenger.school_id
    where passenger.trip_id = p_trip_id
      and ((v_direction = 'going' and array_position(v_ids, home.id)
              > array_position(v_ids, school.id))
        or (v_direction = 'return' and array_position(v_ids, school.id)
              > array_position(v_ids, home.id)))
  ) then
    return false;
  end if;
  if not (p_result ? 'legs') or jsonb_typeof(p_result->'legs') is distinct from 'array'
    or jsonb_array_length(p_result->'legs') <> cardinality(v_ids) - 1 then
    return false;
  end if;
  v_index := 0;
  for v_leg in select value from jsonb_array_elements(p_result->'legs')
  loop
    v_index := v_index + 1;
    if jsonb_typeof(v_leg) is distinct from 'object'
      or v_leg->>'fromId' is distinct from v_ids[v_index]::text
      or v_leg->>'toId' is distinct from v_ids[v_index + 1]::text
      or jsonb_typeof(v_leg->'distanceMeters') is distinct from 'number'
      or jsonb_typeof(v_leg->'durationSeconds') is distinct from 'number'
      or not pg_catalog.pg_input_is_valid(v_leg->>'distanceMeters', 'numeric')
      or not pg_catalog.pg_input_is_valid(v_leg->>'durationSeconds', 'numeric')
      or (v_leg->>'distanceMeters')::numeric < 0
      or (v_leg->>'durationSeconds')::numeric < 0
      or (v_leg->>'distanceMeters')::numeric = 'NaN'::numeric
      or (v_leg->>'durationSeconds')::numeric = 'NaN'::numeric
      or (v_leg->>'distanceMeters')::numeric = 'Infinity'::numeric
      or (v_leg->>'durationSeconds')::numeric = 'Infinity'::numeric then
      return false;
    end if;
  end loop;
  return true;
exception
  when invalid_text_representation
    or invalid_datetime_format
    or datetime_field_overflow
    or numeric_value_out_of_range then
  return false;
end;
$$;

revoke all on function private.validate_route_result(uuid, bigint, jsonb)
  from public, anon, authenticated;
grant execute on function private.validate_route_result(uuid, bigint, jsonb)
  to postgres, supabase_admin, service_role;

create or replace function public.apply_trip_route_result(
  p_trip_id uuid,
  p_revision bigint,
  p_result jsonb
) returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_trip public.trips%rowtype;
  v_calculation public.trip_route_calculations%rowtype;
  v_current_hash bytea;
  v_current_input jsonb;
  v_ids uuid[];
  v_reached_ids uuid[];
  v_reached_count integer := 0;
  v_active_exception boolean;
begin
  if p_trip_id is null or p_revision is null or p_revision <= 0 then
    perform private.raise_api_error('invalid_input', 'Trip and revision are required', 400);
  end if;
  perform private.lock_planning();
  select * into v_trip from public.trips where id = p_trip_id for update;
  if not found then
    perform private.raise_api_error('not_found', 'Trip not found', 404);
  end if;
  select * into v_calculation
  from public.trip_route_calculations
  where trip_id = p_trip_id and revision = p_revision
  for update;
  if not found then
    perform private.raise_api_error('not_found', 'Route calculation not found', 404);
  end if;

  -- A calculated result is immutable. Replaying the same response is
  -- idempotent even though applying it increments the ordinary trip revision;
  -- a different response for that revision is an explicit conflict.
  if v_calculation.status = 'calculated' then
    if v_trip.route_revision = p_revision and v_calculation.result = p_result then
      v_current_input := private.build_trip_route_input(p_trip_id);
      v_current_hash := extensions.digest(v_current_input::text, 'sha256');
      if v_calculation.applied_input_hash = v_current_hash then
        return 'calculated';
      end if;
      update public.trip_route_calculations
      set status = 'superseded', error_code = 'input_changed'
      where id = v_calculation.id;
      update public.trips
      set route_revision = route_revision + 1
      where id = p_trip_id;
      return 'superseded';
    end if;
    if v_trip.route_revision <> p_revision then
      update public.trip_route_calculations
      set status = 'superseded', error_code = 'stale_revision'
      where id = v_calculation.id;
      return 'superseded';
    end if;
    perform private.raise_api_error(
      'idempotency_conflict', 'Calculated route result differs', 409
    );
  elsif v_calculation.status = 'superseded' then
    return 'superseded';
  elsif v_calculation.status = 'failed' then
    return 'failed';
  end if;

  v_active_exception := v_trip.status = 'active'
    and private.trip_has_authorized_route_change(p_trip_id);
  if v_trip.status not in ('scheduled', 'confirmation_closed')
    and not v_active_exception then
    update public.trip_route_calculations
    set status = 'failed', error_code = 'trip_active'
    where id = v_calculation.id and status in ('pending', 'manual');
    return 'failed';
  end if;

  if v_trip.route_revision <> p_revision then
    update public.trip_route_calculations
    set status = 'superseded', error_code = 'stale_revision'
    where id = v_calculation.id and status in ('pending', 'manual', 'calculated');
    return 'superseded';
  end if;
  v_current_input := private.build_trip_route_input(p_trip_id);
  v_current_hash := extensions.digest(v_current_input::text, 'sha256');
  if v_current_hash <> v_calculation.input_hash then
    update public.trip_route_calculations
    set status = 'superseded', error_code = 'input_changed'
    where id = v_calculation.id and status in ('pending', 'manual', 'calculated');
    update public.trips set route_revision = route_revision + 1 where id = p_trip_id;
    return 'superseded';
  end if;
  if v_calculation.status not in ('pending', 'manual')
    or not private.validate_route_result(p_trip_id, p_revision, p_result) then
    update public.trip_route_calculations
    set status = 'failed', error_code = 'invalid_result'
    where id = v_calculation.id and status = 'pending';
    perform private.raise_api_error('invalid_route_result', 'Route result is invalid', 400);
  end if;
  v_ids := array(
    select value::uuid from jsonb_array_elements_text(p_result->'orderedPointIds') value
  );

  if v_trip.status = 'active' then
    select coalesce(array_agg(s.id order by s.position), '{}'::uuid[])
    into v_reached_ids
    from public.trip_stops s
    where s.trip_id = p_trip_id
      and s.position <= coalesce((
        select max(reached.position)
        from public.trip_stops reached
        where reached.trip_id = p_trip_id and reached.reached_at is not null
      ), 0);
    v_reached_count := cardinality(v_reached_ids);
    if v_reached_count > 0
      and v_ids[1:v_reached_count] is distinct from v_reached_ids then
      update public.trip_route_calculations
      set status = 'failed', error_code = 'reached_prefix_changed'
      where id = v_calculation.id and status in ('pending', 'manual');
      perform private.raise_api_error(
        'invalid_route_result', 'Reached route prefix cannot change', 400
      );
    end if;
  end if;

  update public.trip_stops
  set position = position + 1000000
  where trip_id = p_trip_id and reached_at is null;
  update public.trip_stops s
  set position = ordered.position
  from unnest(v_ids) with ordinality ordered(id, position)
  where s.id = ordered.id and s.trip_id = p_trip_id and s.reached_at is null;
  update public.trip_route_calculations
  set status = 'calculated', result = p_result, applied_at = clock_timestamp(), error_code = null
  where id = v_calculation.id;
  update public.trips set revision = revision + 1 where id = p_trip_id;
  v_current_input := private.build_trip_route_input(p_trip_id);
  v_current_hash := extensions.digest(v_current_input::text, 'sha256');
  update public.trip_route_calculations
  set applied_input_hash = v_current_hash
  where id = v_calculation.id;
  return 'calculated';
end;
$$;

revoke all on function public.apply_trip_route_result(uuid, bigint, jsonb)
  from public, anon, authenticated;
grant execute on function public.apply_trip_route_result(uuid, bigint, jsonb)
  to service_role, postgres, supabase_admin;
