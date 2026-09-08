create or replace function private.assert_trip_ready(p_trip_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_trip public.trips%rowtype;
  v_direction text;
begin
  select * into v_trip from public.trips where id = p_trip_id for update;
  if not found then
    perform private.raise_api_error('not_found', 'Trip not found', 404);
  end if;
  select r.direction into v_direction
  from public.routes r
  where r.id = v_trip.route_id and r.fleet_id = v_trip.fleet_id;
  if v_trip.status <> 'confirmation_closed' then
    perform private.raise_api_error('confirmation_closed', 'Confirmation must be closed', 409);
  end if;
  if v_trip.van_id is null or not exists (
    select 1 from public.vans v where v.id = v_trip.van_id
      and v.fleet_id = v_trip.fleet_id and v.status = 'active'
  ) then
    perform private.raise_api_error('resource_in_use', 'Vehicle is not available', 409);
  end if;
  if v_trip.driver_user_id is null or not exists (
    select 1 from public.fleet_memberships fm
    join public.fleet_membership_roles fmr on fmr.membership_id = fm.id
    where fm.fleet_id = v_trip.fleet_id and fm.user_id = v_trip.driver_user_id
      and fm.status = 'active' and fmr.role = 'driver'
  ) then
    perform private.raise_api_error('resource_in_use', 'Driver is not available', 409);
  end if;
  if exists (
    select 1 from public.trips other
    where other.id <> v_trip.id and other.status = 'active'
      and (other.van_id = v_trip.van_id or other.driver_user_id = v_trip.driver_user_id)
  ) then
    perform private.raise_api_error('resource_in_use', 'Resource is already in an active trip', 409);
  end if;
  if not exists (
    select 1 from public.trip_passengers p
    where p.trip_id = p_trip_id and p.removed_at is null
      and p.confirmation_status = 'confirmed'
  ) then
    perform private.raise_api_error('invalid_transition', 'Trip has no confirmed passengers', 409);
  end if;
  if exists (
    select 1 from public.trip_passengers p
    where p.trip_id = p_trip_id and p.removed_at is null
      and p.confirmation_status not in ('confirmed', 'declined', 'expired')
  ) then
    perform private.raise_api_error('confirmation_closed', 'Every passenger must be confirmed', 409);
  end if;
  if not exists (select 1 from public.trip_stops s where s.trip_id = p_trip_id) then
    perform private.raise_api_error('route_unresolved', 'Trip has no stops', 409);
  end if;
  if exists (
    select 1 from public.trip_stops s
    where s.trip_id = p_trip_id
      and (s.kind in ('origin', 'destination', 'school')
        or exists (
          select 1 from public.trip_passengers p
          where p.trip_id = p_trip_id and p.student_id = s.student_id
            and p.removed_at is null and p.confirmation_status = 'confirmed'
        ))
      and (s.latitude is null or s.longitude is null)
  ) then
    perform private.raise_api_error('route_unresolved', 'Trip has unresolved stops', 409);
  end if;
  if v_direction = 'going' and exists (
    select 1
    from public.trip_passengers p
    join public.trip_stops home_stop
      on home_stop.trip_id = p.trip_id and home_stop.kind = 'home'
     and home_stop.student_id = p.student_id
    join public.trip_stops school_stop
      on school_stop.trip_id = p.trip_id and school_stop.kind = 'school'
     and school_stop.school_id = p.school_id
    where p.trip_id = p_trip_id and p.removed_at is null
      and p.confirmation_status = 'confirmed'
      and school_stop.position < home_stop.position
  ) then
    perform private.raise_api_error('route_unresolved', 'Going trip must collect homes before school', 409);
  elsif v_direction = 'return' and exists (
    select 1
    from public.trip_passengers p
    join public.trip_stops home_stop
      on home_stop.trip_id = p.trip_id and home_stop.kind = 'home'
     and home_stop.student_id = p.student_id
    join public.trip_stops school_stop
      on school_stop.trip_id = p.trip_id and school_stop.kind = 'school'
     and school_stop.school_id = p.school_id
    where p.trip_id = p_trip_id and p.removed_at is null
      and p.confirmation_status = 'confirmed'
      and home_stop.position < school_stop.position
  ) then
    perform private.raise_api_error('route_unresolved', 'Return trip must visit school before homes', 409);
  end if;
end;
$$;

create or replace function public.set_trip_stop(
  p_stop_id uuid,
  p_latitude numeric,
  p_longitude numeric,
  p_label text,
  p_expected_revision bigint
) returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_stop public.trip_stops%rowtype;
  v_trip public.trips%rowtype;
  v_revision bigint;
begin
  if v_user_id is null then
    perform private.raise_api_error('unauthenticated', 'Authentication required', 401);
  end if;
  if not private.current_user_email_confirmed() then
    perform private.raise_api_error('email_unverified', 'Email confirmation required', 403);
  end if;
  if p_stop_id is null or p_expected_revision is null or p_label is null or btrim(p_label) = ''
    or char_length(btrim(p_label)) > 500
    or p_latitude is null or p_longitude is null
    or p_latitude not between -90 and 90 or p_longitude not between -180 and 180 then
    perform private.raise_api_error('invalid_input', 'Invalid stop coordinates or label', 400);
  end if;
  perform private.lock_planning();
  select * into v_stop from public.trip_stops where id = p_stop_id for update;
  if not found then
    perform private.raise_api_error('not_found', 'Stop not found', 404);
  end if;
  select * into v_trip from public.trips where id = v_stop.trip_id for update;
  if not private.has_fleet_role(v_trip.fleet_id, v_user_id, 'owner') then
    perform private.raise_api_error('not_found', 'Stop not found', 404);
  end if;
  if v_trip.status not in ('scheduled', 'confirmation_closed') then
    perform private.raise_api_error('trip_active', 'Trip has already started', 409);
  end if;
  if v_trip.revision <> p_expected_revision then
    perform private.raise_api_error('stale_version', 'Trip revision is stale', 409);
  end if;
  update public.trip_stops
  set latitude = p_latitude, longitude = p_longitude,
      address_snapshot = jsonb_build_object('label', btrim(p_label))
  where id = p_stop_id;
  update public.trips set revision = revision + 1 where id = v_trip.id
  returning revision into v_revision;
  return v_revision;
end;
$$;

create or replace function public.order_trip_stops(
  p_trip_id uuid,
  p_stop_ids uuid[],
  p_expected_revision bigint,
  p_reason text
) returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_trip public.trips%rowtype;
  v_stop_count integer;
  v_revision bigint;
  v_event public.trip_events%rowtype;
  v_event_id bigint;
  v_command_id uuid;
  v_payload jsonb;
  v_current_school_ids uuid[];
  v_requested_school_ids uuid[];
  v_reached_boundary integer;
begin
  if v_user_id is null then
    perform private.raise_api_error('unauthenticated', 'Authentication required', 401);
  end if;
  if not private.current_user_email_confirmed() then
    perform private.raise_api_error('email_unverified', 'Email confirmation required', 403);
  end if;
  if p_trip_id is null or p_expected_revision is null or p_stop_ids is null
    or cardinality(p_stop_ids) = 0 or p_reason is null or btrim(p_reason) = ''
    or char_length(btrim(p_reason)) > 500 then
    perform private.raise_api_error('invalid_input', 'Stop order and reason are required', 400);
  end if;
  if cardinality(p_stop_ids) <> cardinality(array(select distinct id from unnest(p_stop_ids) id)) then
    perform private.raise_api_error('invalid_input', 'Stop order contains duplicates', 400);
  end if;
  if exists (select 1 from unnest(p_stop_ids) ids(id) where ids.id is null) then
    perform private.raise_api_error('invalid_input', 'Stop order contains null', 400);
  end if;
  v_payload := jsonb_build_object(
    'reason', btrim(p_reason),
    'stop_ids', to_jsonb(p_stop_ids)
  );
  v_command_id := pg_catalog.md5(
    p_trip_id::text || ':' || p_expected_revision::text || ':' ||
    btrim(p_reason) || ':' || pg_catalog.array_to_string(p_stop_ids, ',')
  )::uuid;
  perform private.lock_planning();
  select * into v_trip from public.trips where id = p_trip_id for update;
  if not found then
    perform private.raise_api_error('not_found', 'Trip not found', 404);
  end if;
  if not (private.has_fleet_role(v_trip.fleet_id, v_user_id, 'owner')
    or (v_trip.status = 'active' and v_trip.driver_user_id = v_user_id
      and private.has_fleet_role(v_trip.fleet_id, v_user_id, 'driver'))) then
    perform private.raise_api_error('not_found', 'Trip not found', 404);
  end if;
  select * into v_event
  from public.trip_events
  where trip_id = p_trip_id and command_id = v_command_id;
  if found then
    if v_event.kind <> 'stops_reordered'
      or v_event.actor_user_id is distinct from v_user_id
      or v_event.payload_hash <> extensions.digest(v_payload::text, 'sha256') then
      perform private.raise_api_error('idempotency_conflict', 'Command payload differs', 409);
    end if;
    return v_event.result::bigint;
  end if;
  if v_trip.status not in ('scheduled', 'confirmation_closed', 'active') then
    perform private.raise_api_error('invalid_transition', 'Trip cannot be reordered', 409);
  end if;
  if v_trip.revision <> p_expected_revision then
    perform private.raise_api_error('stale_version', 'Trip revision is stale', 409);
  end if;
  select count(*) into v_stop_count from public.trip_stops where trip_id = p_trip_id;
  if v_stop_count <> cardinality(p_stop_ids)
    or exists (select 1 from unnest(p_stop_ids) ids(id)
      where not exists (select 1 from public.trip_stops s where s.id = ids.id and s.trip_id = p_trip_id)) then
    perform private.raise_api_error('invalid_input', 'Order must include every trip stop', 400);
  end if;
  select coalesce(array_agg(s.id order by s.position), '{}'::uuid[])
    into v_current_school_ids
  from public.trip_stops s
  where s.trip_id = p_trip_id and s.kind = 'school';
  select coalesce(array_agg(s.id order by ordered.position), '{}'::uuid[])
    into v_requested_school_ids
  from unnest(p_stop_ids) with ordinality ordered(id, position)
  join public.trip_stops s on s.id = ordered.id
  where s.trip_id = p_trip_id and s.kind = 'school';
  if v_current_school_ids is distinct from v_requested_school_ids then
    perform private.raise_api_error('route_unresolved', 'School order cannot change', 409);
  end if;
  if exists (
    select 1
    from public.trip_stops s
    where s.trip_id = p_trip_id and s.reached_at is not null
      and array_position(p_stop_ids, s.id) is distinct from s.position
  ) then
    perform private.raise_api_error('invalid_transition', 'Reached stops must retain their position', 409);
  end if;
  select coalesce(max(s.position) filter (where s.reached_at is not null), 0)
    into v_reached_boundary
  from public.trip_stops s
  where s.trip_id = p_trip_id;
  if exists (
    select 1
    from unnest(p_stop_ids) with ordinality ordered(id, position)
    join public.trip_stops pending_stop
      on pending_stop.id = ordered.id and pending_stop.trip_id = p_trip_id
    where ordered.position <= v_reached_boundary
      and pending_stop.reached_at is null
      and (
        pending_stop.kind in ('origin', 'destination', 'school')
        or exists (
          select 1 from public.trip_passengers p
          where p.trip_id = p_trip_id and p.student_id = pending_stop.student_id
            and p.removed_at is null and p.confirmation_status = 'confirmed'
        )
      )
  ) then
    perform private.raise_api_error('invalid_transition', 'Pending stops must follow reached stops', 409);
  end if;
  update public.trip_stops
  set position = position + 1000000
  where trip_id = p_trip_id and reached_at is null;
  update public.trip_stops s
  set position = ordered.position
  from unnest(p_stop_ids) with ordinality ordered(id, position)
  where s.id = ordered.id and s.reached_at is null;
  update public.trips set revision = revision + 1 where id = p_trip_id
  returning revision into v_revision;
  v_event_id := private.append_trip_event(
    p_trip_id, v_command_id, 'stops_reordered', v_payload, clock_timestamp()
  );
  update public.trip_events set result = v_revision::text where id = v_event_id;
  return v_revision;
end;
$$;

create or replace function public.start_trip(
  p_trip_id uuid,
  p_command_id uuid
) returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_trip public.trips%rowtype;
  v_event public.trip_events%rowtype;
  v_event_id bigint;
  v_result text := 'active';
begin
  if v_user_id is null then
    perform private.raise_api_error('unauthenticated', 'Authentication required', 401);
  end if;
  if not private.current_user_email_confirmed() then
    perform private.raise_api_error('email_unverified', 'Email confirmation required', 403);
  end if;
  if p_trip_id is null or p_command_id is null then
    perform private.raise_api_error('invalid_input', 'Trip and command are required', 400);
  end if;
  perform private.lock_planning();
  select * into v_trip from public.trips where id = p_trip_id for update;
  if not found then
    perform private.raise_api_error('not_found', 'Trip not found', 404);
  end if;
  if not (private.has_fleet_role(v_trip.fleet_id, v_user_id, 'owner')
    or (v_trip.driver_user_id = v_user_id and private.has_fleet_role(v_trip.fleet_id, v_user_id, 'driver'))) then
    perform private.raise_api_error('not_found', 'Trip not found', 404);
  end if;
  select * into v_event from public.trip_events where trip_id = p_trip_id and command_id = p_command_id;
  if found then
    if v_event.kind <> 'trip_started' or v_event.actor_user_id is distinct from v_user_id then
      perform private.raise_api_error('idempotency_conflict', 'Command payload differs', 409);
    end if;
    return v_event.result;
  end if;
  if v_trip.status = 'scheduled' and clock_timestamp() < v_trip.confirmation_deadline then
    perform private.raise_api_error('confirmation_closed', 'Confirmation window is still open', 409);
  end if;
  if v_trip.status = 'scheduled' then
    perform private.close_confirmations(clock_timestamp());
    select * into v_trip from public.trips where id = p_trip_id for update;
  end if;
  if v_trip.status <> 'confirmation_closed' then
    perform private.raise_api_error('invalid_transition', 'Trip cannot start', 409);
  end if;
  perform private.assert_trip_ready(p_trip_id);
  update public.trips set status = 'active', started_at = clock_timestamp(), revision = revision + 1
  where id = p_trip_id;
  v_event_id := private.append_trip_event(
    p_trip_id, p_command_id, 'trip_started', '{}'::jsonb, clock_timestamp()
  );
  update public.trip_events set result = v_result where id = v_event_id;
  return v_result;
end;
$$;

create or replace function public.record_passenger_event(
  p_trip_id uuid,
  p_student_id uuid,
  p_kind text,
  p_command_id uuid
) returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_trip public.trips%rowtype;
  v_passenger public.trip_passengers%rowtype;
  v_event public.trip_events%rowtype;
  v_event_id bigint;
  v_result text;
  v_event_kind text;
begin
  if v_user_id is null then
    perform private.raise_api_error('unauthenticated', 'Authentication required', 401);
  end if;
  if not private.current_user_email_confirmed() then
    perform private.raise_api_error('email_unverified', 'Email confirmation required', 403);
  end if;
  if p_trip_id is null or p_student_id is null or p_kind is null
    or p_kind not in ('boarded', 'dropped_off', 'absent')
    or p_command_id is null then
    perform private.raise_api_error('invalid_input', 'Invalid passenger event', 400);
  end if;
  v_result := p_kind;
  v_event_kind := case p_kind
    when 'boarded' then 'student_boarded'
    when 'dropped_off' then 'student_dropped_off'
    else 'student_absent' end;
  perform private.lock_planning();
  select * into v_trip from public.trips where id = p_trip_id for update;
  if not found then
    perform private.raise_api_error('not_found', 'Trip not found', 404);
  end if;
  if not (private.has_fleet_role(v_trip.fleet_id, v_user_id, 'owner')
    or (v_trip.driver_user_id = v_user_id and private.has_fleet_role(v_trip.fleet_id, v_user_id, 'driver'))) then
    perform private.raise_api_error('not_found', 'Trip not found', 404);
  end if;
  select * into v_event from public.trip_events where trip_id = p_trip_id and command_id = p_command_id;
  if found then
    if v_event.kind <> v_event_kind
      or v_event.actor_user_id is distinct from v_user_id
      or v_event.payload_hash <> extensions.digest(
        jsonb_build_object('student_id', p_student_id, 'kind', p_kind)::text, 'sha256'
      ) then
      perform private.raise_api_error('idempotency_conflict', 'Command payload differs', 409);
    end if;
    return v_event.result;
  end if;
  if v_trip.status <> 'active' then
    perform private.raise_api_error('invalid_transition', 'Trip is not active', 409);
  end if;
  select * into v_passenger from public.trip_passengers
  where trip_id = p_trip_id and student_id = p_student_id for update;
  if not found or v_passenger.removed_at is not null then
    perform private.raise_api_error('not_found', 'Passenger not found', 404);
  end if;
  if p_kind = 'boarded' and (v_passenger.confirmation_status <> 'confirmed'
    or v_passenger.operation_status <> 'waiting') then
    perform private.raise_api_error('invalid_transition', 'Passenger cannot board', 409);
  elsif p_kind = 'absent' and (v_passenger.confirmation_status <> 'confirmed'
    or v_passenger.operation_status <> 'waiting') then
    perform private.raise_api_error('invalid_transition', 'Passenger cannot be absent', 409);
  elsif p_kind = 'dropped_off' and v_passenger.operation_status <> 'boarded' then
    perform private.raise_api_error('invalid_transition', 'Passenger was not boarded', 409);
  end if;
  update public.trip_passengers set operation_status = p_kind where id = v_passenger.id;
  v_event_id := private.append_trip_event(
    p_trip_id, p_command_id, v_event_kind,
    jsonb_build_object('student_id', p_student_id, 'kind', p_kind), clock_timestamp()
  );
  update public.trip_events set result = v_result where id = v_event_id;
  return v_result;
end;
$$;

create or replace function public.finish_trip(
  p_trip_id uuid,
  p_cancel boolean,
  p_reason text,
  p_command_id uuid
) returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_trip public.trips%rowtype;
  v_event public.trip_events%rowtype;
  v_event_id bigint;
  v_result text;
  v_event_kind text;
  v_payload jsonb;
begin
  if v_user_id is null then
    perform private.raise_api_error('unauthenticated', 'Authentication required', 401);
  end if;
  if not private.current_user_email_confirmed() then
    perform private.raise_api_error('email_unverified', 'Email confirmation required', 403);
  end if;
  if p_trip_id is null or p_cancel is null or p_command_id is null
    or (p_cancel and (p_reason is null or btrim(p_reason) = ''))
    or (p_reason is not null and char_length(btrim(p_reason)) > 500) then
    perform private.raise_api_error('invalid_input', 'Trip, command and reason are required', 400);
  end if;
  perform private.lock_planning();
  select * into v_trip from public.trips where id = p_trip_id for update;
  if not found then
    perform private.raise_api_error('not_found', 'Trip not found', 404);
  end if;
  v_result := case when p_cancel then 'cancelled' else 'completed' end;
  v_event_kind := case when p_cancel then 'trip_cancelled' else 'trip_completed' end;
  v_payload := jsonb_build_object(
    'reason', coalesce(btrim(p_reason), ''),
    'reason_hash', encode(extensions.digest(coalesce(btrim(p_reason), ''), 'sha256'), 'hex'),
    'cancel', p_cancel
  );
  if not (private.has_fleet_role(v_trip.fleet_id, v_user_id, 'owner')
    or (v_trip.driver_user_id = v_user_id and private.has_fleet_role(v_trip.fleet_id, v_user_id, 'driver'))) then
    perform private.raise_api_error('not_found', 'Trip not found', 404);
  end if;
  select * into v_event from public.trip_events where trip_id = p_trip_id and command_id = p_command_id;
  if found then
    if v_event.kind <> v_event_kind or v_event.actor_user_id is distinct from v_user_id
      or v_event.payload_hash <> extensions.digest(v_payload::text, 'sha256') then
      perform private.raise_api_error('idempotency_conflict', 'Command payload differs', 409);
    end if;
    return v_event.result;
  end if;
  if p_cancel then
    if v_trip.status = 'active' then
      perform private.raise_api_error('incident_required', 'Active cancellation requires an incident', 409);
    end if;
    if v_trip.status not in ('scheduled', 'confirmation_closed') then
      perform private.raise_api_error('invalid_transition', 'Trip cannot be cancelled', 409);
    end if;
    v_result := 'cancelled';
  else
    if v_trip.status <> 'active' then
      perform private.raise_api_error('invalid_transition', 'Trip cannot be completed', 409);
    end if;
    if exists (select 1 from public.trip_passengers where trip_id = p_trip_id
      and removed_at is null and confirmation_status = 'confirmed'
      and operation_status in ('waiting', 'boarded')) then
      perform private.raise_api_error('passengers_on_board', 'Passenger list is unresolved', 409);
    end if;
    v_result := 'completed';
  end if;
  update public.trips
  set status = v_result,
      ended_at = case when started_at is null then null else clock_timestamp() end,
      revision = revision + 1
  where id = p_trip_id;
  v_event_id := private.append_trip_event(
    p_trip_id, p_command_id,
    case when p_cancel then 'trip_cancelled' else 'trip_completed' end,
    v_payload,
    clock_timestamp()
  );
  update public.trip_events set result = v_result where id = v_event_id;
  return v_result;
end;
$$;

create or replace function public.mark_trip_stop_reached(
  p_stop_id uuid,
  p_command_id uuid
) returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_stop public.trip_stops%rowtype;
  v_trip public.trips%rowtype;
  v_event public.trip_events%rowtype;
  v_event_kind text;
  v_payload jsonb;
begin
  if v_user_id is null then
    perform private.raise_api_error('unauthenticated', 'Authentication required', 401);
  end if;
  if not private.current_user_email_confirmed() then
    perform private.raise_api_error('email_unverified', 'Email confirmation required', 403);
  end if;
  if p_stop_id is null or p_command_id is null then
    perform private.raise_api_error('invalid_input', 'Stop and command are required', 400);
  end if;
  perform private.lock_planning();
  select * into v_stop from public.trip_stops where id = p_stop_id for update;
  if not found then
    perform private.raise_api_error('not_found', 'Stop not found', 404);
  end if;
  select * into v_trip from public.trips where id = v_stop.trip_id for update;
  if not (private.has_fleet_role(v_trip.fleet_id, v_user_id, 'owner')
    or (v_trip.driver_user_id = v_user_id and private.has_fleet_role(v_trip.fleet_id, v_user_id, 'driver'))) then
    perform private.raise_api_error('not_found', 'Stop not found', 404);
  end if;
  v_event_kind := case when v_stop.kind = 'school' then 'school_reached' else 'trip_stop_reached' end;
  v_payload := jsonb_build_object('stop_id', p_stop_id);
  select * into v_event
  from public.trip_events
  where trip_id = v_trip.id and command_id = p_command_id;
  if found then
    if v_event.kind <> v_event_kind
      or v_event.actor_user_id is distinct from v_user_id
      or v_event.payload_hash <> extensions.digest(v_payload::text, 'sha256') then
      perform private.raise_api_error('idempotency_conflict', 'Command payload differs', 409);
    end if;
    return;
  end if;
  if v_trip.status <> 'active' then
    perform private.raise_api_error('invalid_transition', 'Trip is not active', 409);
  end if;
  if v_stop.kind = 'home' and not exists (
    select 1 from public.trip_passengers p
    where p.trip_id = v_trip.id and p.student_id = v_stop.student_id
      and p.removed_at is null and p.confirmation_status = 'confirmed'
  ) then
    perform private.raise_api_error('invalid_transition', 'Passenger is not executable', 409);
  end if;
  if v_stop.reached_at is not null then
    perform private.raise_api_error('invalid_transition', 'Stop was already reached', 409);
  end if;
  update public.trip_stops set reached_at = clock_timestamp() where id = p_stop_id;
  perform private.append_trip_event(
    v_trip.id, p_command_id, v_event_kind, v_payload, clock_timestamp()
  );
end;
$$;

revoke all on function private.assert_trip_ready(uuid) from public, anon, authenticated;
revoke all on function public.set_trip_stop(uuid, numeric, numeric, text, bigint) from public, anon;
revoke all on function public.order_trip_stops(uuid, uuid[], bigint, text) from public, anon;
revoke all on function public.start_trip(uuid, uuid) from public, anon;
revoke all on function public.record_passenger_event(uuid, uuid, text, uuid) from public, anon;
revoke all on function public.finish_trip(uuid, boolean, text, uuid) from public, anon;
revoke all on function public.mark_trip_stop_reached(uuid, uuid) from public, anon;
grant execute on function private.assert_trip_ready(uuid) to postgres, supabase_admin;
grant execute on function public.set_trip_stop(uuid, numeric, numeric, text, bigint) to authenticated;
grant execute on function public.order_trip_stops(uuid, uuid[], bigint, text) to authenticated;
grant execute on function public.start_trip(uuid, uuid) to authenticated;
grant execute on function public.record_passenger_event(uuid, uuid, text, uuid) to authenticated;
grant execute on function public.finish_trip(uuid, boolean, text, uuid) to authenticated;
grant execute on function public.mark_trip_stop_reached(uuid, uuid) to authenticated;
