create function private.array_has_unique_smallints(p_values smallint[])
returns boolean
language sql
immutable
strict
set search_path = ''
as $$
  select cardinality(p_values) = cardinality(
    array(select distinct value from unnest(p_values) as values(value))
  );
$$;

create table public.routes (
  id uuid primary key default extensions.gen_random_uuid(),
  fleet_id uuid not null references public.fleets(id) on delete restrict,
  name text not null,
  direction text not null,
  shift text not null,
  paired_route_id uuid,
  van_id uuid not null,
  driver_user_id uuid not null references public.profiles(id) on delete restrict,
  proximity_minutes integer not null default 10,
  origin_latitude numeric not null,
  origin_longitude numeric not null,
  origin_label text not null,
  destination_latitude numeric not null,
  destination_longitude numeric not null,
  destination_label text not null,
  status text not null default 'active',
  routing_revision bigint not null default 1,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint routes_fleet_id_id_key unique (fleet_id, id),
  constraint routes_fleet_van_fk foreign key (fleet_id, van_id)
    references public.vans(fleet_id, id) on delete restrict,
  constraint routes_name_not_blank check (btrim(name) <> ''),
  constraint routes_direction_valid check (direction in ('going', 'return')),
  constraint routes_shift_valid check (shift in ('morning', 'afternoon', 'evening', 'full_time')),
  constraint routes_proximity_valid check (proximity_minutes between 1 and 60),
  constraint routes_origin_coordinates_valid check (
    origin_latitude between -90 and 90 and origin_longitude between -180 and 180
  ),
  constraint routes_destination_coordinates_valid check (
    destination_latitude between -90 and 90 and destination_longitude between -180 and 180
  ),
  constraint routes_origin_label_not_blank check (btrim(origin_label) <> ''),
  constraint routes_destination_label_not_blank check (btrim(destination_label) <> ''),
  constraint routes_status_valid check (status in ('active', 'inactive')),
  constraint routes_routing_revision_positive check (routing_revision > 0)
);

alter table public.routes
  add constraint routes_fleet_pair_fk foreign key (fleet_id, paired_route_id)
  references public.routes(fleet_id, id) on delete restrict;

create index routes_fleet_status_idx on public.routes (fleet_id, status);
create index routes_van_idx on public.routes (van_id, status);
create index routes_driver_idx on public.routes (driver_user_id, status);

create table public.route_schools (
  route_id uuid not null,
  fleet_id uuid not null,
  school_id uuid not null,
  position integer not null,
  created_at timestamptz not null default now(),
  constraint route_schools_pkey primary key (route_id, school_id),
  constraint route_schools_route_fk foreign key (fleet_id, route_id)
    references public.routes(fleet_id, id) on delete cascade,
  constraint route_schools_school_fk foreign key (fleet_id, school_id)
    references public.fleet_service_schools(fleet_id, school_id) on delete restrict,
  constraint route_schools_position_valid check (position > 0),
  constraint route_schools_position_unique unique (route_id, position)
);

create index route_schools_fleet_school_idx on public.route_schools (fleet_id, school_id);

create table public.route_schedules (
  id uuid primary key default extensions.gen_random_uuid(),
  route_id uuid not null,
  fleet_id uuid not null,
  weekdays smallint[] not null,
  starts_at time not null,
  ends_at time not null,
  ends_next_day boolean not null default false,
  timezone text not null,
  valid_from date not null,
  valid_until date not null,
  confirmation_minutes integer not null default 30,
  status text not null default 'active',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint route_schedules_fleet_id_id_key unique (fleet_id, id),
  constraint route_schedules_route_fk foreign key (fleet_id, route_id)
    references public.routes(fleet_id, id) on delete restrict,
  constraint route_schedules_weekdays_valid check (
    cardinality(weekdays) between 1 and 7
    and weekdays <@ array[1, 2, 3, 4, 5, 6, 7]::smallint[]
    and private.array_has_unique_smallints(weekdays)
  ),
  constraint route_schedules_time_order check (ends_next_day or ends_at > starts_at),
  constraint route_schedules_timezone_not_blank check (btrim(timezone) <> ''),
  constraint route_schedules_dates_finite check (isfinite(valid_from) and isfinite(valid_until)),
  constraint route_schedules_dates_valid check (valid_until >= valid_from),
  constraint route_schedules_confirmation_valid check (confirmation_minutes between 0 and 1440),
  constraint route_schedules_status_valid check (status in ('active', 'inactive'))
);

create index route_schedules_route_idx on public.route_schedules (route_id, status, valid_from, valid_until);
create index route_schedules_fleet_idx on public.route_schedules (fleet_id, status, valid_from, valid_until);

create trigger routes_set_updated_at
before update on public.routes
for each row execute function private.set_updated_at();

create trigger route_schedules_set_updated_at
before update on public.route_schedules
for each row execute function private.set_updated_at();

alter table public.audit_events drop constraint audit_events_action_valid;
alter table public.audit_events add constraint audit_events_action_valid check (
  action in (
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
    'enrollment_school_updated'
  )
);

alter table public.audit_events drop constraint audit_events_entity_type_valid;
alter table public.audit_events add constraint audit_events_entity_type_valid check (
  entity_type in (
    'fleet', 'fleet_membership', 'service_city', 'service_school', 'student',
    'student_guardian', 'join_request', 'fleet_invitation', 'enrollment',
    'van', 'route', 'route_schedule', 'route_student_schedule',
    'transport_reservation'
  )
);

create function private.validate_schedule(p_schedule jsonb)
returns void
language plpgsql
set search_path = ''
as $$
declare
  v_day jsonb;
  v_days smallint[] := array[]::smallint[];
  v_timezone text;
  v_start text;
  v_end text;
  v_ends_next_day boolean;
  v_from date;
  v_until date;
  v_confirmation text;
  v_confirmation_value integer;
begin
  if p_schedule is null or jsonb_typeof(p_schedule) <> 'object'
    or jsonb_typeof(p_schedule->'weekdays') is distinct from 'array'
    or jsonb_typeof(p_schedule->'starts_at') is distinct from 'string'
    or jsonb_typeof(p_schedule->'ends_at') is distinct from 'string'
    or jsonb_typeof(p_schedule->'ends_next_day') is distinct from 'boolean'
    or jsonb_typeof(p_schedule->'timezone') is distinct from 'string'
    or jsonb_typeof(p_schedule->'valid_from') is distinct from 'string'
    or jsonb_typeof(p_schedule->'valid_until') is distinct from 'string'
    or jsonb_typeof(p_schedule->'confirmation_minutes') is distinct from 'number' then
    perform private.raise_api_error('invalid_input', 'Invalid schedule object', 400);
  end if;

  if jsonb_array_length(p_schedule->'weekdays') not between 1 and 7 then
    perform private.raise_api_error('invalid_input', 'Schedule requires one to seven weekdays', 400);
  end if;
  for v_day in select value from jsonb_array_elements(p_schedule->'weekdays') loop
    if jsonb_typeof(v_day) is distinct from 'number'
      or (v_day #>> '{}') !~ '^[1-7]$' then
      perform private.raise_api_error('invalid_input', 'Schedule weekday is invalid', 400);
    end if;
    v_days := array_append(v_days, (v_day #>> '{}')::smallint);
  end loop;
  if not private.array_has_unique_smallints(v_days) then
    perform private.raise_api_error('invalid_input', 'Schedule weekdays must be unique', 400);
  end if;

  v_start := p_schedule->>'starts_at';
  v_end := p_schedule->>'ends_at';
  if v_start !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
    or v_end !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' then
    perform private.raise_api_error('invalid_input', 'Schedule time is invalid', 400);
  end if;
  v_ends_next_day := (p_schedule->>'ends_next_day')::boolean;
  if not v_ends_next_day and v_end::time <= v_start::time then
    perform private.raise_api_error('invalid_input', 'Schedule must end after it starts', 400);
  end if;

  v_timezone := btrim(p_schedule->>'timezone');
  if v_timezone = '' or not exists (
    select 1 from pg_catalog.pg_timezone_names where name = v_timezone
  ) then
    perform private.raise_api_error('invalid_input', 'Schedule timezone is invalid', 400);
  end if;

  begin
    v_from := (p_schedule->>'valid_from')::date;
    v_until := (p_schedule->>'valid_until')::date;
  exception when others then
    perform private.raise_api_error('invalid_input', 'Schedule validity dates are invalid', 400);
  end;
  if not isfinite(v_from) or not isfinite(v_until) or v_until < v_from then
    perform private.raise_api_error('invalid_input', 'Schedule validity is invalid', 400);
  end if;

  v_confirmation := p_schedule->>'confirmation_minutes';
  if v_confirmation !~ '^[0-9]+$' then
    perform private.raise_api_error('invalid_input', 'Schedule confirmation window is invalid', 400);
  end if;
  begin
    v_confirmation_value := v_confirmation::integer;
  exception when others then
    perform private.raise_api_error('invalid_input', 'Schedule confirmation window is invalid', 400);
  end;
  if v_confirmation_value not between 0 and 1440 then
    perform private.raise_api_error('invalid_input', 'Schedule confirmation window is invalid', 400);
  end if;
end;
$$;

create function private.schedule_windows(
  p_schedule_id uuid,
  p_from date,
  p_until date
) returns table(service_date date, "window" tstzrange)
language sql
stable
set search_path = ''
as $$
  select dates.service_date::date,
         tstzrange(
           (dates.service_date::date + s.starts_at) at time zone s.timezone,
           ((dates.service_date::date
             + case when s.ends_next_day then 1 else 0 end)
             + s.ends_at) at time zone s.timezone,
           '[)'
         )
  from public.route_schedules s
  cross join lateral generate_series(
    greatest(s.valid_from, coalesce(p_from, s.valid_from))::timestamp,
    least(s.valid_until, coalesce(p_until, s.valid_until))::timestamp,
    interval '1 day'
  ) as dates(service_date)
  where s.id = p_schedule_id
    and s.status = 'active'
    and extract(isodow from dates.service_date)::smallint = any(s.weekdays)
$$;

revoke execute on function private.array_has_unique_smallints(smallint[]) from public, anon, authenticated;
revoke execute on function private.validate_schedule(jsonb) from public, anon, authenticated;
revoke execute on function private.schedule_windows(uuid, date, date) from public, anon, authenticated;
grant execute on function private.array_has_unique_smallints(smallint[]) to postgres;
grant execute on function private.validate_schedule(jsonb) to postgres;
grant execute on function private.schedule_windows(uuid, date, date) to postgres;

create function private.validate_route_resources(
  p_route_id uuid,
  p_van_id uuid,
  p_driver_user_id uuid
) returns void
language plpgsql
set search_path = ''
as $$
declare
  v_left record;
  v_right record;
begin
  -- Every caller (including schedule creation after suspension) checks the
  -- current resources under the planning lock, not only overlapping times.
  if not exists (
    select 1 from public.routes r
    join public.vans v on v.id = p_van_id and v.fleet_id = r.fleet_id
    where r.id = p_route_id and v.status = 'active'
      and private.has_fleet_role(r.fleet_id, p_driver_user_id, 'driver')
  ) then
    perform private.raise_api_error('resource_in_use', 'Route resources are unavailable', 409);
  end if;
  for v_left in
    select rs.id
    from public.route_schedules rs
    join public.routes r on r.id = rs.route_id and r.fleet_id = rs.fleet_id
    where rs.route_id = p_route_id and rs.status = 'active'
      and r.status = 'active'
  loop
    for v_right in
      select rs.id
      from public.route_schedules rs
      join public.routes r on r.id = rs.route_id and r.fleet_id = rs.fleet_id
      where rs.status = 'active'
        and r.status = 'active'
        and rs.id <> v_left.id
        and (r.van_id = p_van_id or r.driver_user_id = p_driver_user_id)
    loop
      if exists (
        select 1
        from private.schedule_windows(v_left.id, null, null) left_window
        join private.schedule_windows(v_right.id, null, null) right_window
          on left_window."window" && right_window."window"
      ) then
        perform private.raise_api_error('schedule_conflict', 'Route resource is already scheduled', 409);
      end if;
    end loop;
  end loop;
end;
$$;

create function private.assert_van_releasable(p_van_id uuid)
returns void
language plpgsql
set search_path = ''
as $$
declare
  v_now timestamptz := clock_timestamp();
begin
  if exists (
    select 1
    from public.routes r
    join public.route_schedules rs
      on rs.fleet_id = r.fleet_id and rs.route_id = r.id
    where r.van_id = p_van_id
      and r.status = 'active'
      and rs.status = 'active'
      and exists (
        select 1
        from private.schedule_windows(
          rs.id,
          (v_now at time zone rs.timezone)::date - 1,
          rs.valid_until
        ) w
        where upper(w."window") > v_now
      )
  ) then
    perform private.raise_api_error('resource_in_use', 'Vehicle has current or future route assignments', 409);
  end if;
end;
$$;

create or replace function private.assert_driver_releasable(
  p_fleet_id uuid,
  p_user_id uuid
) returns void
language plpgsql
set search_path = ''
as $$
declare
  v_now timestamptz := clock_timestamp();
begin
  if exists (
    select 1
    from public.routes r
    join public.route_schedules rs
      on rs.fleet_id = r.fleet_id and rs.route_id = r.id
    where r.fleet_id = p_fleet_id
      and r.driver_user_id = p_user_id
      and r.status = 'active'
      and rs.status = 'active'
      and exists (
        select 1
        from private.schedule_windows(
          rs.id,
          (v_now at time zone rs.timezone)::date - 1,
          rs.valid_until
        ) w
        where upper(w."window") > v_now
      )
  ) then
    perform private.raise_api_error('resource_in_use', 'Driver has current or future route assignments', 409);
  end if;
end;
$$;

revoke execute on function private.validate_route_resources(uuid, uuid, uuid) from public, anon, authenticated;
revoke execute on function private.assert_van_releasable(uuid) from public, anon, authenticated;
revoke execute on function private.assert_driver_releasable(uuid, uuid) from public, anon, authenticated;
grant execute on function private.validate_route_resources(uuid, uuid, uuid) to postgres;
grant execute on function private.assert_van_releasable(uuid) to postgres;
grant execute on function private.assert_driver_releasable(uuid, uuid) to postgres;

create or replace function public.deactivate_van(
  p_van_id uuid,
  p_reason text
) returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_van public.vans%rowtype;
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
  select * into v_van from public.vans where id = p_van_id for update;
  if not found or not private.has_fleet_role(v_van.fleet_id, v_user_id, 'owner') then
    perform private.raise_api_error('not_found', 'Vehicle not found', 404);
  end if;
  if v_van.status <> 'active' then
    perform private.raise_api_error('invalid_transition', 'Vehicle is already inactive', 409);
  end if;
  perform private.assert_van_releasable(p_van_id);
  update public.vans
  set status = 'inactive', deactivated_at = clock_timestamp()
  where id = p_van_id;
  insert into public.audit_events (
    fleet_id, actor_user_id, action, entity_type, entity_id, metadata
  ) values (
    v_van.fleet_id, v_user_id, 'van_deactivated', 'van', p_van_id,
    jsonb_build_object('reason', btrim(p_reason))
  );
  return 'inactive';
end;
$$;

create function public.save_route(
  p_fleet_id uuid,
  p_route_id uuid,
  p_config jsonb
) returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_id uuid;
  v_name text;
  v_direction text;
  v_shift text;
  v_paired_route_id uuid;
  v_paired_direction text;
  v_van_id uuid;
  v_driver_user_id uuid;
  v_origin jsonb;
  v_destination jsonb;
  v_origin_lat numeric;
  v_origin_lon numeric;
  v_destination_lat numeric;
  v_destination_lon numeric;
  v_origin_label text;
  v_destination_label text;
  v_proximity integer;
  v_proximity_text text;
  v_school jsonb;
  v_position integer;
  v_school_id uuid;
  v_constraint text;
begin
  if v_user_id is null then
    perform private.raise_api_error('unauthenticated', 'Authentication required', 401);
  end if;
  if not private.current_user_email_confirmed() then
    perform private.raise_api_error('email_unverified', 'Email confirmation required', 403);
  end if;
  if p_config is null or jsonb_typeof(p_config) is distinct from 'object'
    or jsonb_typeof(p_config->'name') is distinct from 'string'
    or jsonb_typeof(p_config->'direction') is distinct from 'string'
    or jsonb_typeof(p_config->'shift') is distinct from 'string'
    or jsonb_typeof(p_config->'van_id') is distinct from 'string'
    or jsonb_typeof(p_config->'driver_user_id') is distinct from 'string'
    or jsonb_typeof(p_config->'origin') is distinct from 'object'
    or jsonb_typeof(p_config->'destination') is distinct from 'object'
    or jsonb_typeof(p_config->'schools') is distinct from 'array' then
    perform private.raise_api_error('invalid_input', 'Invalid route configuration', 400);
  end if;
  if p_config ? 'proximity_minutes'
    and (jsonb_typeof(p_config->'proximity_minutes') is distinct from 'number'
      or p_config->>'proximity_minutes' !~ '^[0-9]+$') then
    perform private.raise_api_error('invalid_input', 'Invalid route configuration', 400);
  end if;
  v_name := btrim(p_config->>'name');
  v_direction := p_config->>'direction';
  v_shift := p_config->>'shift';
  v_proximity_text := coalesce(p_config->>'proximity_minutes', '10');
  begin
    v_proximity := v_proximity_text::integer;
    v_van_id := (p_config->>'van_id')::uuid;
    v_driver_user_id := (p_config->>'driver_user_id')::uuid;
    v_paired_route_id := nullif(p_config->>'paired_route_id', '')::uuid;
    v_origin_lat := (p_config->'origin'->>'latitude')::numeric;
    v_origin_lon := (p_config->'origin'->>'longitude')::numeric;
    v_destination_lat := (p_config->'destination'->>'latitude')::numeric;
    v_destination_lon := (p_config->'destination'->>'longitude')::numeric;
  exception when others then
    perform private.raise_api_error('invalid_input', 'Invalid route reference or coordinates', 400);
  end;
  v_origin := p_config->'origin';
  v_destination := p_config->'destination';
  if jsonb_typeof(v_origin->'latitude') is distinct from 'number'
    or jsonb_typeof(v_origin->'longitude') is distinct from 'number'
    or jsonb_typeof(v_origin->'label') is distinct from 'string'
    or jsonb_typeof(v_destination->'latitude') is distinct from 'number'
    or jsonb_typeof(v_destination->'longitude') is distinct from 'number'
    or jsonb_typeof(v_destination->'label') is distinct from 'string' then
    perform private.raise_api_error('invalid_input', 'Invalid route coordinates or labels', 400);
  end if;
  v_origin_label := btrim(v_origin->>'label');
  v_destination_label := btrim(v_destination->>'label');
  if v_name = '' or v_direction not in ('going', 'return')
    or v_shift not in ('morning', 'afternoon', 'evening', 'full_time')
    or v_proximity not between 1 and 60
    or v_van_id is null or v_driver_user_id is null
    or v_origin_label = '' or v_destination_label = ''
    or v_origin_lat is null or v_origin_lon is null
    or v_destination_lat is null or v_destination_lon is null
    or v_origin_lat not between -90 and 90 or v_origin_lon not between -180 and 180
    or v_destination_lat not between -90 and 90 or v_destination_lon not between -180 and 180 then
    perform private.raise_api_error('invalid_input', 'Invalid route references or coordinates', 400);
  end if;

  perform private.lock_planning();
  if p_fleet_id is null or not private.has_fleet_role(p_fleet_id, v_user_id, 'owner') then
    perform private.raise_api_error('not_found', 'Fleet not found', 404);
  end if;
  perform 1 from public.vans v
  where v.id = v_van_id and v.fleet_id = p_fleet_id and v.status = 'active'
  for update;
  if not found then
    perform private.raise_api_error('not_found', 'Vehicle not found', 404);
  end if;
  if not private.has_fleet_role(p_fleet_id, v_driver_user_id, 'driver') then
    perform private.raise_api_error('invalid_input', 'Driver is not active in this fleet', 400);
  end if;
  if v_paired_route_id is not null then
    select r.direction into v_paired_direction
    from public.routes r
    where r.id = v_paired_route_id and r.fleet_id = p_fleet_id;
    if not found or v_paired_route_id = p_route_id then
      perform private.raise_api_error('not_found', 'Paired route not found', 404);
    end if;
    if v_paired_direction = v_direction then
      perform private.raise_api_error('invalid_input', 'Paired route must have the opposite direction', 400);
    end if;
  end if;

  if p_route_id is null then
    insert into public.routes (
      fleet_id, name, direction, shift, paired_route_id, van_id, driver_user_id,
      proximity_minutes, origin_latitude, origin_longitude, origin_label,
      destination_latitude, destination_longitude, destination_label
    ) values (
      p_fleet_id, v_name, v_direction, v_shift, v_paired_route_id,
      v_van_id, v_driver_user_id, v_proximity, v_origin_lat, v_origin_lon, v_origin_label,
      v_destination_lat, v_destination_lon, v_destination_label
    ) returning id into v_id;
  else
    perform 1 from public.routes r
    where r.id = p_route_id and r.fleet_id = p_fleet_id for update;
    if not found then
      perform private.raise_api_error('not_found', 'Route not found', 404);
    end if;
    update public.routes
    set name = v_name, direction = v_direction, shift = v_shift,
        paired_route_id = v_paired_route_id, van_id = v_van_id, driver_user_id = v_driver_user_id,
        proximity_minutes = v_proximity, origin_latitude = v_origin_lat, origin_longitude = v_origin_lon,
        origin_label = v_origin_label, destination_latitude = v_destination_lat,
        destination_longitude = v_destination_lon, destination_label = v_destination_label,
        routing_revision = routing_revision + 1
    where id = p_route_id;
    v_id := p_route_id;
  end if;

  -- Route schools are replaced as one set, so check the old reservation
  -- contract before deleting any rows. The helper is defined with the
  -- reservation tables in the following C3 migration and permits additions
  -- and reordering while retaining every school needed by a live booking.
  perform private.assert_route_school_change(v_id, p_config->'schools');
  delete from public.route_schools where route_id = v_id;
  for v_school in select value from jsonb_array_elements(p_config->'schools') loop
    begin
      v_school_id := (v_school->>'school_id')::uuid;
      v_position := (v_school->>'position')::integer;
    exception when others then
      perform private.raise_api_error('invalid_input', 'Invalid route school', 400);
    end;
    if v_school_id is null or v_position is null or v_position < 1
      or not exists (
        select 1 from public.schools s
        join public.fleet_service_schools fss on fss.school_id = s.id
        where s.id = v_school_id and s.status = 'active'
          and fss.fleet_id = p_fleet_id
      ) then
      perform private.raise_api_error('invalid_input', 'Invalid route school', 400);
    end if;
    insert into public.route_schools (route_id, fleet_id, school_id, position)
    values (v_id, p_fleet_id, v_school_id, v_position);
  end loop;
  perform private.validate_route_resources(v_id, v_van_id, v_driver_user_id);
  insert into public.audit_events (
    fleet_id, actor_user_id, action, entity_type, entity_id, metadata
  ) values (
    p_fleet_id, v_user_id, case when p_route_id is null then 'route_created' else 'route_updated' end,
    'route', v_id, jsonb_build_object('direction', v_direction)
  );
  return v_id;
exception
  when unique_violation then
    get stacked diagnostics v_constraint = constraint_name;
    if v_constraint in ('route_schools_pkey', 'route_schools_position_unique') then
      perform private.raise_api_error('invalid_input', 'Route contains a duplicate school or position', 400);
    end if;
    raise;
end;
$$;

create function public.save_route_schedule(
  p_route_id uuid,
  p_schedule_id uuid,
  p_schedule jsonb
) returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_fleet_id uuid;
  v_id uuid;
  v_constraint text;
begin
  if v_user_id is null then
    perform private.raise_api_error('unauthenticated', 'Authentication required', 401);
  end if;
  if not private.current_user_email_confirmed() then
    perform private.raise_api_error('email_unverified', 'Email confirmation required', 403);
  end if;
  perform private.validate_schedule(p_schedule);
  perform private.lock_planning();
  select r.fleet_id into v_fleet_id
  from public.routes r where r.id = p_route_id for update;
  if not found or not private.has_fleet_role(v_fleet_id, v_user_id, 'owner') then
    perform private.raise_api_error('not_found', 'Route not found', 404);
  end if;
  if p_schedule_id is null then
    insert into public.route_schedules (
      route_id, fleet_id, weekdays, starts_at, ends_at, ends_next_day, timezone,
      valid_from, valid_until, confirmation_minutes
    ) values (
      p_route_id, v_fleet_id,
      (select array_agg(value::smallint) from jsonb_array_elements_text(p_schedule->'weekdays')),
      (p_schedule->>'starts_at')::time, (p_schedule->>'ends_at')::time,
      (p_schedule->>'ends_next_day')::boolean, btrim(p_schedule->>'timezone'),
      (p_schedule->>'valid_from')::date, (p_schedule->>'valid_until')::date,
      (p_schedule->>'confirmation_minutes')::integer
    ) returning id into v_id;
  else
    perform 1 from public.route_schedules s
    where s.id = p_schedule_id and s.route_id = p_route_id and s.fleet_id = v_fleet_id
    for update;
    if not found then
      perform private.raise_api_error('not_found', 'Schedule not found', 404);
    end if;
    update public.route_schedules
    set weekdays = (select array_agg(value::smallint) from jsonb_array_elements_text(p_schedule->'weekdays')),
        starts_at = (p_schedule->>'starts_at')::time, ends_at = (p_schedule->>'ends_at')::time,
        ends_next_day = (p_schedule->>'ends_next_day')::boolean, timezone = btrim(p_schedule->>'timezone'),
        valid_from = (p_schedule->>'valid_from')::date, valid_until = (p_schedule->>'valid_until')::date,
        confirmation_minutes = (p_schedule->>'confirmation_minutes')::integer
    where id = p_schedule_id;
    v_id := p_schedule_id;
  end if;

  perform private.validate_route_resources(p_route_id,
    (select r.van_id from public.routes r where r.id = p_route_id),
    (select r.driver_user_id from public.routes r where r.id = p_route_id));
  insert into public.audit_events (
    fleet_id, actor_user_id, action, entity_type, entity_id, metadata
  ) values (
    v_fleet_id, v_user_id,
    case when p_schedule_id is null then 'route_schedule_created' else 'route_schedule_updated' end,
    'route_schedule', v_id, '{}'::jsonb
  );
  return v_id;
exception
  when unique_violation then
    get stacked diagnostics v_constraint = constraint_name;
    if v_constraint = 'route_schedules_fleet_id_id_key' then
      perform private.raise_api_error('schedule_conflict', 'Schedule conflicts with another route', 409);
    end if;
    raise;
end;
$$;

create function public.set_route_status(
  p_route_id uuid,
  p_status text,
  p_reason text
) returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_route public.routes%rowtype;
  v_fleet_id uuid;
begin
  if v_user_id is null then
    perform private.raise_api_error('unauthenticated', 'Authentication required', 401);
  end if;
  if not private.current_user_email_confirmed() then
    perform private.raise_api_error('email_unverified', 'Email confirmation required', 403);
  end if;
  if p_status is null or p_status not in ('active', 'inactive') then
    perform private.raise_api_error('invalid_status', 'Invalid route status', 400);
  end if;
  if p_status = 'inactive' and (p_reason is null or btrim(p_reason) = '') then
    perform private.raise_api_error('invalid_input', 'A reason is required to deactivate a route', 400);
  end if;
  perform private.lock_planning();
  select * into v_route
  from public.routes r where r.id = p_route_id for update;
  if not found or not private.has_fleet_role(v_route.fleet_id, v_user_id, 'owner') then
    perform private.raise_api_error('not_found', 'Route not found', 404);
  end if;
  v_fleet_id := v_route.fleet_id;
  if v_route.status = p_status then
    return p_status;
  end if;
  if p_status = 'active' then
    perform 1
    from public.vans v
    where v.id = v_route.van_id
      and v.fleet_id = v_route.fleet_id
      and v.status = 'active'
    for update;
    if not found then
      perform private.raise_api_error('resource_in_use', 'Route vehicle is inactive', 409);
    end if;
    if not private.has_fleet_role(v_route.fleet_id, v_route.driver_user_id, 'driver') then
      perform private.raise_api_error('resource_in_use', 'Route driver is inactive', 409);
    end if;
    perform private.validate_route_resources(
      p_route_id, v_route.van_id, v_route.driver_user_id
    );
  end if;
  update public.routes
  set status = p_status, routing_revision = routing_revision + 1
  where id = p_route_id;
  insert into public.audit_events (
    fleet_id, actor_user_id, action, entity_type, entity_id, metadata
  ) values (
    v_fleet_id, v_user_id, 'route_status_changed', 'route', p_route_id,
    jsonb_build_object('previous_status', v_route.status, 'new_status', p_status,
      'reason', nullif(btrim(p_reason), ''))
  );
  return p_status;
end;
$$;

alter table public.routes enable row level security;
alter table public.route_schools enable row level security;
alter table public.route_schedules enable row level security;
revoke all on table public.routes from anon, authenticated;
revoke all on table public.route_schools from anon, authenticated;
revoke all on table public.route_schedules from anon, authenticated;
grant select on table public.routes, public.route_schools, public.route_schedules to authenticated;

create policy routes_select_operations on public.routes for select to authenticated using (
  private.has_fleet_role(routes.fleet_id, (select auth.uid()), 'owner')
  or (routes.driver_user_id = (select auth.uid())
      and private.has_fleet_role(routes.fleet_id, (select auth.uid()), 'driver'))
);

create policy route_schools_select_operations on public.route_schools for select to authenticated using (
  exists (
    select 1 from public.routes r
    where r.id = route_schools.route_id and r.fleet_id = route_schools.fleet_id
      and (private.has_fleet_role(r.fleet_id, (select auth.uid()), 'owner')
        or (r.driver_user_id = (select auth.uid())
            and private.has_fleet_role(r.fleet_id, (select auth.uid()), 'driver')))
  )
);

create policy route_schedules_select_operations on public.route_schedules for select to authenticated using (
  exists (
    select 1 from public.routes r
    where r.id = route_schedules.route_id and r.fleet_id = route_schedules.fleet_id
      and (private.has_fleet_role(r.fleet_id, (select auth.uid()), 'owner')
        or (r.driver_user_id = (select auth.uid())
            and private.has_fleet_role(r.fleet_id, (select auth.uid()), 'driver')))
  )
);

revoke execute on function public.save_route(uuid, uuid, jsonb) from public, anon;
revoke execute on function public.save_route_schedule(uuid, uuid, jsonb) from public, anon;
revoke execute on function public.set_route_status(uuid, text, text) from public, anon;
revoke execute on function public.deactivate_van(uuid, text) from public, anon;
grant execute on function public.save_route(uuid, uuid, jsonb) to authenticated;
grant execute on function public.save_route_schedule(uuid, uuid, jsonb) to authenticated;
grant execute on function public.set_route_status(uuid, text, text) to authenticated;
grant execute on function public.deactivate_van(uuid, text) to authenticated;
