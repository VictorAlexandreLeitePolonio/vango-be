create function private.close_confirmations(p_now timestamptz)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_trip record;
  v_count integer := 0;
begin
  if p_now is null then
    perform private.raise_api_error('invalid_input', 'Clock is required', 400);
  end if;
  perform private.lock_planning();

  for v_trip in
    select t.id, t.confirmation_deadline
    from public.trips t
    where t.status = 'scheduled' and t.confirmation_deadline <= p_now
    order by t.id
    for update
  loop
    update public.trip_passengers
    set confirmation_status = 'expired'
    where trip_id = v_trip.id
      and confirmation_status = 'pending'
      and removed_at is null;

    update public.trips
    set status = 'confirmation_closed', revision = revision + 1
    where id = v_trip.id and status = 'scheduled';
    if found then
      perform private.append_trip_event(
        v_trip.id, extensions.gen_random_uuid(), 'confirmation_closed',
        jsonb_build_object('deadline', v_trip.confirmation_deadline), p_now
      );
      v_count := v_count + 1;
    end if;
  end loop;
  return v_count;
end;
$$;

create function public.respond_trip(
  p_trip_id uuid,
  p_student_id uuid,
  p_confirm boolean,
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
  v_kind text;
  v_result text;
  v_event_id bigint;
  v_existing public.trip_events%rowtype;
begin
  if v_user_id is null then
    perform private.raise_api_error('unauthenticated', 'Authentication required', 401);
  end if;
  if not private.current_user_email_confirmed() then
    perform private.raise_api_error('email_unverified', 'Email confirmation required', 403);
  end if;
  if p_trip_id is null or p_student_id is null or p_confirm is null or p_command_id is null then
    perform private.raise_api_error('invalid_input', 'Trip, student, response and command are required', 400);
  end if;

  perform private.lock_planning();
  select * into v_trip from public.trips where id = p_trip_id for update;
  if not found then
    perform private.raise_api_error('not_found', 'Trip not found', 404);
  end if;
  v_kind := case when p_confirm then 'student_confirmed' else 'student_declined' end;
  v_result := case when p_confirm then 'confirmed' else 'declined' end;
  select * into v_existing
  from public.trip_events
  where trip_id = p_trip_id and command_id = p_command_id;
  if found then
    if v_existing.kind <> v_kind or v_existing.actor_user_id is distinct from v_user_id
      or v_existing.payload_hash <> extensions.digest(
        jsonb_build_object('student_id', p_student_id, 'confirm', p_confirm)::text,
        'sha256'
      ) then
      perform private.raise_api_error('idempotency_conflict', 'Command payload differs', 409);
    end if;
    return v_existing.result;
  end if;
  if v_trip.status <> 'scheduled' then
    perform private.raise_api_error('confirmation_closed', 'Confirmation is closed', 409);
  end if;
  if clock_timestamp() >= v_trip.confirmation_deadline then
    perform private.raise_api_error('confirmation_closed', 'Confirmation is closed', 409);
  end if;

  select * into v_passenger
  from public.trip_passengers p
  where p.trip_id = p_trip_id and p.student_id = p_student_id
  for update;
  if not found or v_passenger.removed_at is not null then
    perform private.raise_api_error('not_found', 'Passenger not found', 404);
  end if;
  if not private.can_view_student(p_student_id, v_user_id)
    or not private.is_active_fleet_member(v_trip.fleet_id, v_user_id) then
    perform private.raise_api_error('not_found', 'Passenger not found', 404);
  end if;
  if v_passenger.confirmation_status = 'expired' then
    perform private.raise_api_error('confirmation_closed', 'Confirmation is closed', 409);
  end if;

  update public.trip_passengers
  set confirmation_status = v_result,
      confirmation_by = v_user_id,
      confirmation_at = clock_timestamp()
  where id = v_passenger.id;
  v_event_id := private.append_trip_event(
    p_trip_id, p_command_id, v_kind,
    jsonb_build_object('student_id', p_student_id, 'confirm', p_confirm), clock_timestamp()
  );
  update public.trip_events set result = v_result where id = v_event_id;
  return v_result;
end;
$$;

create function public.override_trip_participation(
  p_trip_id uuid,
  p_student_id uuid,
  p_confirm boolean,
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
  v_passenger public.trip_passengers%rowtype;
  v_result text := case when p_confirm then 'confirmed' else 'declined' end;
  v_event_id bigint;
  v_existing public.trip_events%rowtype;
  v_payload jsonb;
begin
  if v_user_id is null then
    perform private.raise_api_error('unauthenticated', 'Authentication required', 401);
  end if;
  if not private.current_user_email_confirmed() then
    perform private.raise_api_error('email_unverified', 'Email confirmation required', 403);
  end if;
  if p_reason is null or btrim(p_reason) = '' or char_length(btrim(p_reason)) > 500
    or p_command_id is null then
    perform private.raise_api_error('invalid_input', 'Reason and command are required', 400);
  end if;
  perform private.lock_planning();
  select * into v_trip from public.trips where id = p_trip_id for update;
  if not found then
    perform private.raise_api_error('not_found', 'Trip not found', 404);
  end if;
  if not private.has_fleet_role(v_trip.fleet_id, v_user_id, 'owner') then
    perform private.raise_api_error('not_found', 'Trip not found', 404);
  end if;
  v_payload := jsonb_build_object(
    'student_id', p_student_id, 'confirm', p_confirm, 'reason_recorded', true
  );
  select * into v_existing from public.trip_events
  where trip_id = p_trip_id and command_id = p_command_id;
  if found then
    if v_existing.kind <> 'participation_overridden'
      or v_existing.actor_user_id is distinct from v_user_id
      or v_existing.payload_hash <> extensions.digest(v_payload::text, 'sha256') then
      perform private.raise_api_error('idempotency_conflict', 'Command payload differs', 409);
    end if;
    return v_existing.result;
  end if;
  if v_trip.status not in ('scheduled', 'confirmation_closed') then
    perform private.raise_api_error('trip_active', 'Trip has already started', 409);
  end if;
  select * into v_passenger from public.trip_passengers p
  where p.trip_id = p_trip_id and p.student_id = p_student_id for update;
  if not found or v_passenger.removed_at is not null then
    perform private.raise_api_error('not_found', 'Passenger not found', 404);
  end if;
  update public.trip_passengers
  set confirmation_status = v_result,
      confirmation_by = v_user_id,
      confirmation_at = clock_timestamp()
  where id = v_passenger.id;
  update public.trips set revision = revision + 1 where id = p_trip_id;
  v_event_id := private.append_trip_event(
    p_trip_id, p_command_id, 'participation_overridden', v_payload, clock_timestamp()
  );
  update public.trip_events set result = v_result where id = v_event_id;
  return v_result;
end;
$$;

create or replace function public.set_service_enabled(
  p_fleet_id uuid,
  p_route_ids uuid[],
  p_service_date date,
  p_enabled boolean,
  p_reason text
) returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_route_id uuid;
  v_trip record;
  v_count integer := 0;
  v_reason text := nullif(btrim(p_reason), '');
  v_event_id bigint;
begin
  if v_user_id is null then
    perform private.raise_api_error('unauthenticated', 'Authentication required', 401);
  end if;
  if not private.current_user_email_confirmed() then
    perform private.raise_api_error('email_unverified', 'Email confirmation required', 403);
  end if;
  if p_fleet_id is null or p_service_date is null or p_enabled is null then
    perform private.raise_api_error('invalid_input', 'Fleet, date and enabled are required', 400);
  end if;
  if p_route_ids is not null and cardinality(p_route_ids) = 0 then
    perform private.raise_api_error('invalid_input', 'Route list cannot be empty', 400);
  end if;
  if not p_enabled and v_reason is null then
    perform private.raise_api_error('invalid_input', 'A reason is required when disabling service', 400);
  end if;
  if v_reason is not null and length(v_reason) > 500 then
    perform private.raise_api_error('invalid_input', 'Reason is too long', 400);
  end if;
  perform private.lock_planning();
  perform 1 from public.fleets f where f.id = p_fleet_id for update;
  if not found or not private.has_fleet_role(p_fleet_id, v_user_id, 'owner') then
    perform private.raise_api_error('not_found', 'Fleet not found', 404);
  end if;
  if p_route_ids is not null and exists (
    select 1 from unnest(p_route_ids) requested(route_id)
    left join public.routes r on r.id = requested.route_id and r.fleet_id = p_fleet_id
    where r.id is null
  ) then
    perform private.raise_api_error('not_found', 'Route not found', 404);
  end if;
  for v_route_id in
    select r.id from public.routes r
    where r.fleet_id = p_fleet_id and (p_route_ids is null or r.id = any(p_route_ids))
    order by r.id for update
  loop
    insert into public.route_service_exceptions (
      fleet_id, route_id, service_date, enabled, reason, updated_by, updated_at
    ) values (
      p_fleet_id, v_route_id, p_service_date, p_enabled, v_reason, v_user_id, clock_timestamp()
    )
    on conflict (route_id, service_date) do update
      set enabled = excluded.enabled, reason = excluded.reason,
          updated_by = excluded.updated_by, updated_at = excluded.updated_at;

    for v_trip in
      select t.id, t.status, t.started_at, t.confirmation_deadline
      from public.trips t
      where t.fleet_id = p_fleet_id and t.route_id = v_route_id
        and t.service_date = p_service_date
      order by t.id for update
    loop
      if not p_enabled and v_trip.status in ('scheduled', 'confirmation_closed') then
        update public.trips set status = 'cancelled', revision = revision + 1 where id = v_trip.id;
        v_event_id := private.append_trip_event(
          v_trip.id, extensions.gen_random_uuid(), 'service_disabled',
          jsonb_build_object('service_date', p_service_date), clock_timestamp()
        );
      elsif p_enabled and v_trip.status = 'cancelled' and v_trip.started_at is null then
        update public.trips set status = case when v_trip.confirmation_deadline <= clock_timestamp()
          then 'confirmation_closed' else 'scheduled' end,
          revision = revision + 1 where id = v_trip.id;
        update public.trip_passengers
        set confirmation_status = case when v_trip.confirmation_deadline <= clock_timestamp()
          then 'expired' else 'pending' end,
            confirmation_by = null, confirmation_at = null
        where trip_id = v_trip.id and removed_at is null;
        v_event_id := private.append_trip_event(
          v_trip.id, extensions.gen_random_uuid(), 'service_enabled',
          jsonb_build_object('service_date', p_service_date), clock_timestamp()
        );
      end if;
    end loop;

    insert into public.audit_events (
      fleet_id, actor_user_id, action, entity_type, entity_id, metadata
    ) values (
      p_fleet_id, v_user_id,
      case when p_enabled then 'service_enabled' else 'service_disabled' end,
      'route', v_route_id,
      jsonb_build_object('service_date', p_service_date, 'enabled', p_enabled)
    );
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;

revoke all on function private.close_confirmations(timestamptz) from public, anon, authenticated;
revoke all on function public.respond_trip(uuid, uuid, boolean, uuid) from public, anon;
revoke all on function public.override_trip_participation(uuid, uuid, boolean, text, uuid) from public, anon;
revoke all on function public.set_service_enabled(uuid, uuid[], date, boolean, text) from public, anon;
grant execute on function private.close_confirmations(timestamptz) to postgres, supabase_admin;
grant execute on function public.respond_trip(uuid, uuid, boolean, uuid) to authenticated;
grant execute on function public.override_trip_participation(uuid, uuid, boolean, text, uuid) to authenticated;
grant execute on function public.set_service_enabled(uuid, uuid[], date, boolean, text) to authenticated;
