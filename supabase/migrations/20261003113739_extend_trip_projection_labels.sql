-- Task 20: the owner/driver projection of get_trip carries the operational labels
-- (route name, van plate/public name, passenger full name) that the driver app
-- needs. The guardian/passenger projection is unchanged.
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
  -- Operational labels; stays empty for the guardian/passenger projection.
  v_labels jsonb := '{}'::jsonb;
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
      'removal_reason', p.removal_reason, 'student_full_name', st.full_name
    ) order by p.id), '[]'::jsonb)
    into v_passengers
    from public.trip_passengers p
    join public.students st on st.id = p.student_id
    where p.trip_id = v_trip.id;

    select jsonb_build_object(
      'route_name', r.name, 'van_plate', v.plate, 'van_public_name', v.public_name
    )
    into v_labels
    from public.routes r
    left join public.vans v on v.id = v_trip.van_id and v.fleet_id = v_trip.fleet_id
    where r.id = v_trip.route_id and r.fleet_id = v_trip.fleet_id;

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
    ) || coalesce(v_labels, '{}'::jsonb),
    'passengers', v_passengers,
    'stops', v_stops,
    'assignments', v_assignments,
    'incidents', v_incidents,
    'events', v_events
  );
end;
$$;

revoke all on function public.get_trip(uuid) from public, anon;
grant execute on function public.get_trip(uuid) to authenticated;
