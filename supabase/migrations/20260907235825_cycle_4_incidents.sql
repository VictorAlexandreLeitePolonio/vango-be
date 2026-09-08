create table public.trip_incidents (
  id uuid primary key default extensions.gen_random_uuid(),
  fleet_id uuid not null references public.fleets(id) on delete restrict,
  trip_id uuid not null,
  category text not null,
  description text not null,
  actor_user_id uuid not null references public.profiles(id) on delete restrict,
  created_at timestamptz not null default now(),
  resolved_at timestamptz,
  constraint trip_incidents_trip_fleet_fk
    foreign key (trip_id, fleet_id)
    references public.trips(id, fleet_id)
    on delete restrict,
  constraint trip_incidents_id_fleet_key unique (id, fleet_id),
  constraint trip_incidents_category_valid check (
    category in ('traffic', 'delay', 'accident', 'mechanical', 'detour', 'other')
  ),
  constraint trip_incidents_description_valid check (
    btrim(description) <> '' and char_length(description) <= 2000
  ),
  constraint trip_incidents_resolution_valid check (
    resolved_at is null or resolved_at >= created_at
  )
);

create index trip_incidents_trip_created_idx
  on public.trip_incidents (fleet_id, trip_id, created_at, id);

create table public.trip_incident_updates (
  id uuid primary key default extensions.gen_random_uuid(),
  fleet_id uuid not null references public.fleets(id) on delete restrict,
  incident_id uuid not null,
  note text not null,
  resolved boolean not null,
  actor_user_id uuid not null references public.profiles(id) on delete restrict,
  created_at timestamptz not null default now(),
  command_id uuid not null,
  constraint trip_incident_updates_incident_fleet_fk
    foreign key (incident_id, fleet_id)
    references public.trip_incidents(id, fleet_id)
    on delete restrict,
  constraint trip_incident_updates_incident_command_key
    unique (incident_id, command_id),
  constraint trip_incident_updates_note_valid check (
    btrim(note) <> '' and char_length(note) <= 2000
  )
);

create index trip_incident_updates_incident_created_idx
  on public.trip_incident_updates (fleet_id, incident_id, created_at, id);

alter table public.trip_incidents enable row level security;
alter table public.trip_incident_updates enable row level security;

revoke all on public.trip_incidents from anon, authenticated;
revoke all on public.trip_incident_updates from anon, authenticated;

create or replace function public.report_trip_incident(
  p_trip_id uuid,
  p_category text,
  p_description text,
  p_command_id uuid
) returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_trip public.trips%rowtype;
  v_incident_id uuid;
  v_existing public.trip_events%rowtype;
  v_event_id bigint;
  v_payload jsonb;
  v_description text := nullif(btrim(p_description), '');
begin
  if v_user_id is null then
    perform private.raise_api_error('unauthenticated', 'Authentication required', 401);
  end if;
  if not private.current_user_email_confirmed() then
    perform private.raise_api_error('email_unverified', 'Email confirmation required', 403);
  end if;
  if p_trip_id is null or p_category is null or p_description is null
    or p_command_id is null or btrim(p_category) = '' or v_description is null
    or char_length(v_description) > 2000
    or p_category not in ('traffic', 'delay', 'accident', 'mechanical', 'detour', 'other') then
    perform private.raise_api_error('invalid_input', 'Invalid incident', 400);
  end if;
  v_payload := jsonb_build_object(
    'category', btrim(p_category),
    'description_hash', encode(extensions.digest(v_description, 'sha256'), 'hex')
  );

  perform private.lock_planning();
  select * into v_trip
  from public.trips t
  where t.id = p_trip_id
  for update;
  if not found then
    perform private.raise_api_error('not_found', 'Trip not found', 404);
  end if;
  if not (
    private.has_fleet_role(v_trip.fleet_id, v_user_id, 'owner')
    or (
      v_trip.driver_user_id = v_user_id
      and private.has_fleet_role(v_trip.fleet_id, v_user_id, 'driver')
    )
  ) then
    perform private.raise_api_error('not_found', 'Trip not found', 404);
  end if;
  select * into v_existing
  from public.trip_events e
  where e.trip_id = p_trip_id and e.command_id = p_command_id;
  if found then
    if v_existing.kind <> 'incident_reported'
      or v_existing.actor_user_id is distinct from v_user_id
      or v_existing.payload_hash <> extensions.digest(v_payload::text, 'sha256') then
      perform private.raise_api_error('idempotency_conflict', 'Command payload differs', 409);
    end if;
    return v_existing.result::uuid;
  end if;
  if v_trip.status not in ('scheduled', 'confirmation_closed', 'active') then
    perform private.raise_api_error('invalid_transition', 'Trip cannot receive an incident', 409);
  end if;

  insert into public.trip_incidents (
    fleet_id, trip_id, category, description, actor_user_id
  ) values (
    v_trip.fleet_id, p_trip_id, btrim(p_category), v_description, v_user_id
  ) returning id into v_incident_id;
  v_event_id := private.append_trip_event(
    p_trip_id, p_command_id, 'incident_reported', v_payload, clock_timestamp()
  );
  update public.trip_events
  set result = v_incident_id::text
  where id = v_event_id;
  return v_incident_id;
end;
$$;

create or replace function public.update_trip_incident(
  p_incident_id uuid,
  p_note text,
  p_resolved boolean,
  p_command_id uuid
) returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_trip public.trips%rowtype;
  v_incident public.trip_incidents%rowtype;
  v_incident_ref record;
  v_existing public.trip_events%rowtype;
  v_event_id bigint;
  v_payload jsonb;
  v_note text := nullif(btrim(p_note), '');
begin
  if v_user_id is null then
    perform private.raise_api_error('unauthenticated', 'Authentication required', 401);
  end if;
  if not private.current_user_email_confirmed() then
    perform private.raise_api_error('email_unverified', 'Email confirmation required', 403);
  end if;
  if p_incident_id is null or p_note is null or p_resolved is null
    or p_command_id is null or v_note is null or char_length(v_note) > 2000 then
    perform private.raise_api_error('invalid_input', 'Invalid incident update', 400);
  end if;

  -- Read the reference before locking it so trip locks always precede
  -- incident locks.  This is the same planning lock order as trip commands.
  select i.trip_id, i.fleet_id
  into v_incident_ref
  from public.trip_incidents i
  where i.id = p_incident_id;
  if not found then
    perform private.raise_api_error('not_found', 'Incident not found', 404);
  end if;
  perform private.lock_planning();
  select * into v_trip
  from public.trips t
  where t.id = v_incident_ref.trip_id
    and t.fleet_id = v_incident_ref.fleet_id
  for update;
  if not found then
    perform private.raise_api_error('not_found', 'Incident not found', 404);
  end if;
  select * into v_incident
  from public.trip_incidents i
  where i.id = p_incident_id and i.fleet_id = v_trip.fleet_id
  for update;
  if not found then
    perform private.raise_api_error('not_found', 'Incident not found', 404);
  end if;
  if not (
    private.has_fleet_role(v_trip.fleet_id, v_user_id, 'owner')
    or (
      v_trip.driver_user_id = v_user_id
      and private.has_fleet_role(v_trip.fleet_id, v_user_id, 'driver')
    )
  ) then
    perform private.raise_api_error('not_found', 'Incident not found', 404);
  end if;

  v_payload := jsonb_build_object(
    'incident_id', p_incident_id,
    'note_hash', encode(extensions.digest(v_note, 'sha256'), 'hex'),
    'resolved', p_resolved
  );
  select * into v_existing
  from public.trip_events e
  where e.trip_id = v_trip.id and e.command_id = p_command_id;
  if found then
    if v_existing.kind <> 'incident_updated'
      or v_existing.actor_user_id is distinct from v_user_id
      or v_existing.payload_hash <> extensions.digest(v_payload::text, 'sha256') then
      perform private.raise_api_error('idempotency_conflict', 'Command payload differs', 409);
    end if;
    return v_existing.result::uuid;
  end if;

  insert into public.trip_incident_updates (
    fleet_id, incident_id, note, resolved, actor_user_id, command_id
  ) values (
    v_trip.fleet_id, p_incident_id, v_note, p_resolved, v_user_id, p_command_id
  );
  update public.trip_incidents
  set resolved_at = case when p_resolved then clock_timestamp() else null end
  where id = p_incident_id;
  v_event_id := private.append_trip_event(
    v_trip.id, p_command_id, 'incident_updated', v_payload, clock_timestamp()
  );
  update public.trip_events
  set result = p_incident_id::text
  where id = v_event_id;
  return p_incident_id;
end;
$$;

create or replace function public.get_trip(
  p_trip_id uuid
) returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_trip public.trips%rowtype;
  v_owner boolean;
  v_driver boolean;
  v_passenger boolean;
  v_passengers jsonb;
  v_stops jsonb;
  v_assignments jsonb;
  v_incidents jsonb;
  v_events jsonb;
begin
  if v_user_id is null then
    perform private.raise_api_error('unauthenticated', 'Authentication required', 401);
  end if;
  if not private.current_user_email_confirmed() then
    perform private.raise_api_error('email_unverified', 'Email confirmation required', 403);
  end if;
  if p_trip_id is null then
    perform private.raise_api_error('not_found', 'Trip not found', 404);
  end if;
  select * into v_trip from public.trips t where t.id = p_trip_id;
  if not found then
    perform private.raise_api_error('not_found', 'Trip not found', 404);
  end if;
  v_owner := private.has_fleet_role(v_trip.fleet_id, v_user_id, 'owner');
  v_driver := v_trip.driver_user_id = v_user_id
    and private.has_fleet_role(v_trip.fleet_id, v_user_id, 'driver');
  v_passenger := private.is_active_fleet_member(v_trip.fleet_id, v_user_id)
    and exists (
      select 1
      from public.trip_passengers p
      where p.trip_id = v_trip.id
        and private.can_view_student(p.student_id, v_user_id)
        and p.removed_at is null
    );
  if not v_owner and not v_driver and not v_passenger then
    perform private.raise_api_error('not_found', 'Trip not found', 404);
  end if;

  if v_owner or v_driver then
    select coalesce(jsonb_agg(jsonb_build_object(
      'id', p.id, 'enrollment_id', p.enrollment_id, 'student_id', p.student_id,
      'school_id', p.school_id, 'confirmation_status', p.confirmation_status,
      'operation_status', p.operation_status, 'confirmation_by', p.confirmation_by,
      'confirmation_at', p.confirmation_at, 'removed_at', p.removed_at,
      'removal_reason', p.removal_reason
    ) order by p.id), '[]'::jsonb)
    into v_passengers
    from public.trip_passengers p where p.trip_id = v_trip.id;

    select coalesce(jsonb_agg(jsonb_build_object(
      'id', s.id, 'kind', s.kind, 'student_id', s.student_id, 'school_id', s.school_id,
      'position', s.position, 'address_snapshot', s.address_snapshot,
      'latitude', s.latitude, 'longitude', s.longitude, 'reached_at', s.reached_at
    ) order by s.position), '[]'::jsonb)
    into v_stops from public.trip_stops s where s.trip_id = v_trip.id;

    select coalesce(jsonb_agg(jsonb_build_object(
      'id', a.id, 'van_id', a.van_id, 'driver_user_id', a.driver_user_id,
      'valid_from', a.valid_from, 'valid_until', a.valid_until,
      'reason', a.reason, 'actor_user_id', a.actor_user_id
    ) order by a.valid_from, a.id), '[]'::jsonb)
    into v_assignments from public.trip_assignments a where a.trip_id = v_trip.id;

    select coalesce(jsonb_agg(jsonb_build_object(
      'id', i.id, 'category', i.category, 'description', i.description,
      'actor_user_id', i.actor_user_id, 'created_at', i.created_at,
      'resolved_at', i.resolved_at,
      'updates', coalesce((select jsonb_agg(jsonb_build_object(
        'id', u.id, 'note', u.note, 'resolved', u.resolved,
        'actor_user_id', u.actor_user_id, 'created_at', u.created_at,
        'command_id', u.command_id
      ) order by u.created_at, u.id)
      from public.trip_incident_updates u where u.incident_id = i.id), '[]'::jsonb)
    ) order by i.created_at, i.id), '[]'::jsonb)
    into v_incidents from public.trip_incidents i where i.trip_id = v_trip.id;

    select coalesce(jsonb_agg(jsonb_build_object(
      'id', e.id, 'command_id', e.command_id, 'event_sequence', e.event_sequence,
      'kind', e.kind, 'actor_user_id', e.actor_user_id, 'occurred_at', e.occurred_at,
      'received_at', e.received_at, 'payload', e.payload, 'result', e.result
    ) order by e.event_sequence), '[]'::jsonb)
    into v_events from public.trip_events e where e.trip_id = v_trip.id;
  else
    select coalesce(jsonb_agg(jsonb_build_object(
      'id', p.id, 'student_id', p.student_id, 'school_id', p.school_id,
      'confirmation_status', p.confirmation_status, 'operation_status', p.operation_status,
      'confirmation_at', p.confirmation_at, 'removed_at', p.removed_at
    ) order by p.id), '[]'::jsonb)
    into v_passengers
    from public.trip_passengers p
    where p.trip_id = v_trip.id and private.can_view_student(p.student_id, v_user_id);

    select coalesce(jsonb_agg(case when s.kind = 'home' then
      jsonb_build_object('id', s.id, 'kind', s.kind, 'student_id', s.student_id,
        'position', s.position, 'address_snapshot', s.address_snapshot,
        'latitude', s.latitude, 'longitude', s.longitude, 'reached_at', s.reached_at)
      else
      jsonb_build_object('id', s.id, 'kind', s.kind, 'school_id', s.school_id,
        'position', s.position, 'reached_at', s.reached_at)
      end order by s.position), '[]'::jsonb)
    into v_stops
    from public.trip_stops s
    where s.trip_id = v_trip.id
      and (
        s.kind in ('origin', 'destination')
        or (s.kind = 'school' and exists (
          select 1 from public.trip_passengers p
          where p.trip_id = s.trip_id and p.school_id = s.school_id
            and p.removed_at is null and private.can_view_student(p.student_id, v_user_id)
        ))
        or (s.kind = 'home' and exists (
        select 1 from public.trip_passengers p
        where p.trip_id = s.trip_id and p.student_id = s.student_id
          and p.removed_at is null and private.can_view_student(p.student_id, v_user_id)
        ))
      );
    v_assignments := '[]'::jsonb;
    select coalesce(jsonb_agg(jsonb_build_object(
      'id', i.id, 'category', i.category, 'created_at', i.created_at,
      'resolved_at', i.resolved_at
    ) order by i.created_at, i.id), '[]'::jsonb)
    into v_incidents from public.trip_incidents i where i.trip_id = v_trip.id;
    -- Event payloads include operational details for other passengers; the
    -- guardian projection intentionally omits the event stream.
    v_events := '[]'::jsonb;
  end if;

  return jsonb_build_object(
    'trip', jsonb_build_object(
      'id', v_trip.id, 'fleet_id', v_trip.fleet_id, 'service_day_id', v_trip.service_day_id,
      'route_id', v_trip.route_id, 'schedule_id', v_trip.schedule_id,
      'service_date', v_trip.service_date, 'planned_start_at', v_trip.planned_start_at,
      'reserved_until', v_trip.reserved_until, 'confirmation_deadline', v_trip.confirmation_deadline,
      'status', v_trip.status, 'van_id', v_trip.van_id, 'driver_user_id', v_trip.driver_user_id,
      'started_at', v_trip.started_at, 'ended_at', v_trip.ended_at, 'revision', v_trip.revision
    ),
    'passengers', v_passengers,
    'stops', v_stops,
    'assignments', v_assignments,
    'incidents', v_incidents,
    'events', v_events
  );
end;
$$;

create or replace function public.list_service_day(
  p_fleet_id uuid,
  p_service_date date
) returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_is_owner boolean;
  v_is_driver boolean;
  v_trips jsonb;
begin
  if v_user_id is null then
    perform private.raise_api_error('unauthenticated', 'Authentication required', 401);
  end if;
  if not private.current_user_email_confirmed() then
    perform private.raise_api_error('email_unverified', 'Email confirmation required', 403);
  end if;
  if p_fleet_id is null or p_service_date is null or not isfinite(p_service_date) then
    perform private.raise_api_error('invalid_input', 'Fleet and finite date are required', 400);
  end if;
  v_is_owner := private.has_fleet_role(p_fleet_id, v_user_id, 'owner');
  v_is_driver := private.has_fleet_role(p_fleet_id, v_user_id, 'driver');
  select coalesce(jsonb_agg(public.get_trip(t.id) order by t.planned_start_at, t.id), '[]'::jsonb)
  into v_trips
  from public.trips t
  where t.fleet_id = p_fleet_id
    and t.service_date = p_service_date
    and (v_is_owner or (v_is_driver and t.driver_user_id = v_user_id));
  return jsonb_build_object('fleet_id', p_fleet_id, 'service_date', p_service_date, 'trips', v_trips);
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
  if not (
    private.has_fleet_role(v_trip.fleet_id, v_user_id, 'owner')
    or (v_trip.driver_user_id = v_user_id
      and private.has_fleet_role(v_trip.fleet_id, v_user_id, 'driver'))
  ) then
    perform private.raise_api_error('not_found', 'Trip not found', 404);
  end if;
  v_result := case when p_cancel then 'cancelled' else 'completed' end;
  v_event_kind := case when p_cancel then 'trip_cancelled' else 'trip_completed' end;
  v_payload := jsonb_build_object(
    'reason', coalesce(btrim(p_reason), ''),
    'reason_hash', encode(extensions.digest(coalesce(btrim(p_reason), ''), 'sha256'), 'hex'),
    'cancel', p_cancel
  );
  select * into v_event from public.trip_events
  where trip_id = p_trip_id and command_id = p_command_id;
  if found then
    if v_event.kind <> v_event_kind or v_event.actor_user_id is distinct from v_user_id
      or v_event.payload_hash <> extensions.digest(v_payload::text, 'sha256') then
      perform private.raise_api_error('idempotency_conflict', 'Command payload differs', 409);
    end if;
    return v_event.result;
  end if;
  if p_cancel then
    if v_trip.status = 'active' then
      if not exists (select 1 from public.trip_incidents i where i.trip_id = p_trip_id) then
        perform private.raise_api_error('incident_required', 'Active cancellation requires an incident', 409);
      end if;
      if exists (select 1 from public.trip_passengers p where p.trip_id = p_trip_id
        and p.removed_at is null and p.confirmation_status = 'confirmed'
        and p.operation_status in ('waiting', 'boarded')) then
        perform private.raise_api_error('passengers_on_board', 'Passenger list is unresolved', 409);
      end if;
    elsif v_trip.status not in ('scheduled', 'confirmation_closed') then
      perform private.raise_api_error('invalid_transition', 'Trip cannot be cancelled', 409);
    end if;
  else
    if v_trip.status <> 'active' then
      perform private.raise_api_error('invalid_transition', 'Trip cannot be completed', 409);
    end if;
    if exists (select 1 from public.trip_passengers p where p.trip_id = p_trip_id
      and p.removed_at is null and p.confirmation_status = 'confirmed'
      and p.operation_status in ('waiting', 'boarded')) then
      perform private.raise_api_error('passengers_on_board', 'Passenger list is unresolved', 409);
    end if;
  end if;
  update public.trips
  set status = v_result,
      ended_at = case when started_at is null then null else clock_timestamp() end,
      revision = revision + 1
  where id = p_trip_id;
  v_event_id := private.append_trip_event(
    p_trip_id, p_command_id, v_event_kind, v_payload, clock_timestamp()
  );
  update public.trip_events set result = v_result where id = v_event_id;
  return v_result;
end;
$$;

revoke all on function public.report_trip_incident(uuid, text, text, uuid) from public, anon;
revoke all on function public.update_trip_incident(uuid, text, boolean, uuid) from public, anon;
revoke all on function public.get_trip(uuid) from public, anon;
revoke all on function public.list_service_day(uuid, date) from public, anon;
revoke all on function public.finish_trip(uuid, boolean, text, uuid) from public, anon;
grant execute on function public.report_trip_incident(uuid, text, text, uuid) to authenticated;
grant execute on function public.update_trip_incident(uuid, text, boolean, uuid) to authenticated;
grant execute on function public.get_trip(uuid) to authenticated;
grant execute on function public.list_service_day(uuid, date) to authenticated;
grant execute on function public.finish_trip(uuid, boolean, text, uuid) to authenticated;
