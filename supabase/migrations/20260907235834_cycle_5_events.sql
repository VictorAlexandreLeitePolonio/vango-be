create table private.notification_worker_state (
  id boolean primary key default true,
  activation_event_id bigint not null default 0,
  enabled boolean not null default false,
  activated_at timestamptz,
  constraint notification_worker_state_singleton check (id),
  constraint notification_worker_state_activation_nonnegative check (activation_event_id >= 0),
  constraint notification_worker_state_enabled_date check (enabled = false or activated_at is not null)
);

create table private.notification_processed_events (
  event_id bigint primary key,
  processed_at timestamptz not null default now()
);

create table private.notification_manual_commands (
  fleet_id uuid not null references public.fleets(id) on delete restrict,
  actor_user_id uuid not null references public.profiles(id) on delete restrict,
  command_id uuid not null,
  notification_id uuid not null references public.notifications(id) on delete restrict,
  payload_hash bytea not null,
  created_at timestamptz not null default now(),
  primary key (fleet_id, command_id)
);

create index notification_manual_commands_rate_idx
  on private.notification_manual_commands (fleet_id, actor_user_id, created_at desc);

revoke all on table private.notification_worker_state from public, anon, authenticated;
revoke all on table private.notification_processed_events from public, anon, authenticated;
revoke all on table private.notification_manual_commands from public, anon, authenticated;

create function private.notification_trip_recipients(
  p_trip_id uuid
) returns uuid[]
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(array_agg(distinct audience.user_id), '{}'::uuid[])
  from (
    select case when current_assignment.trip_id is not null
      then current_assignment.driver_user_id else t.driver_user_id end as user_id
    from public.trips t
    left join public.trip_assignments current_assignment
      on current_assignment.trip_id = t.id
     and current_assignment.valid_until is null
    where t.id = p_trip_id
      and private.has_fleet_role(
        t.fleet_id,
        case when current_assignment.trip_id is not null
          then current_assignment.driver_user_id else t.driver_user_id end,
        'driver'
      )
    union all
    select fm.user_id
    from public.trips t
    join public.fleet_memberships fm on fm.fleet_id = t.fleet_id and fm.status = 'active'
    join public.fleet_membership_roles fmr on fmr.membership_id = fm.id and fmr.role = 'owner'
    where t.id = p_trip_id
    union all
    select s.profile_id
    from public.trip_passengers tp
    join public.students s on s.id = tp.student_id
    where tp.trip_id = p_trip_id and tp.removed_at is null and s.profile_id is not null
    union all
    select sg.guardian_user_id
    from public.trip_passengers tp
    join public.student_guardians sg
      on sg.student_id = tp.student_id and sg.status = 'active'
    where tp.trip_id = p_trip_id and tp.removed_at is null
  ) audience
  where audience.user_id is not null
    and exists (
      select 1
      from public.trips t
      join public.fleet_memberships fm
        on fm.fleet_id = t.fleet_id and fm.user_id = audience.user_id and fm.status = 'active'
      where t.id = p_trip_id
    );
$$;

create function private.notification_student_recipients(
  p_trip_id uuid,
  p_student_id uuid
) returns uuid[]
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(array_agg(distinct audience.user_id), '{}'::uuid[])
  from (
    select s.profile_id as user_id
    from public.trip_passengers tp
    join public.students s on s.id = tp.student_id
    where tp.trip_id = p_trip_id and tp.student_id = p_student_id
      and tp.removed_at is null and s.profile_id is not null
    union all
    select sg.guardian_user_id
    from public.trip_passengers tp
    join public.student_guardians sg
      on sg.student_id = tp.student_id and sg.status = 'active'
    where tp.trip_id = p_trip_id and tp.student_id = p_student_id
      and tp.removed_at is null
  ) audience
  where audience.user_id is not null
    and exists (
      select 1
      from public.trip_passengers tp
      join public.trips t on t.id = tp.trip_id
      join public.fleet_memberships fm
        on fm.fleet_id = t.fleet_id and fm.user_id = audience.user_id and fm.status = 'active'
      where tp.trip_id = p_trip_id and tp.student_id = p_student_id
    );
$$;

create function private.notification_route_recipients(
  p_fleet_id uuid,
  p_route_id uuid
) returns uuid[]
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(array_agg(distinct audience.user_id), '{}'::uuid[])
  from (
    select r.driver_user_id as user_id
    from public.routes r
    where r.id = p_route_id and r.fleet_id = p_fleet_id and r.status = 'active'
      and private.has_fleet_role(p_fleet_id, r.driver_user_id, 'driver')
    union all
    select fm.user_id
    from public.fleet_memberships fm
    join public.fleet_membership_roles fmr on fmr.membership_id = fm.id and fmr.role = 'owner'
    where fm.fleet_id = p_fleet_id and fm.status = 'active'
    union all
    select s.profile_id
    from public.transport_reservations reservation
    join public.fleet_enrollments e
      on e.id = reservation.enrollment_id
     and e.fleet_id = p_fleet_id
     and e.status = 'active'
    join public.routes r
      on r.id = reservation.route_id
     and r.fleet_id = p_fleet_id
     and r.status = 'active'
    join public.students s on s.id = e.student_id
    where reservation.fleet_id = p_fleet_id
      and reservation.route_id = p_route_id
      and reservation.status = 'active'
      and reservation.valid_until >= current_date
      and s.profile_id is not null
    union all
    select sg.guardian_user_id
    from public.transport_reservations reservation
    join public.fleet_enrollments e
      on e.id = reservation.enrollment_id
     and e.fleet_id = p_fleet_id
     and e.status = 'active'
    join public.routes r
      on r.id = reservation.route_id
     and r.fleet_id = p_fleet_id
     and r.status = 'active'
    join public.student_guardians sg
      on sg.student_id = e.student_id and sg.status = 'active'
    where reservation.fleet_id = p_fleet_id
      and reservation.route_id = p_route_id
      and reservation.status = 'active'
      and reservation.valid_until >= current_date
  ) audience
  where audience.user_id is not null
    and private.is_active_fleet_member(p_fleet_id, audience.user_id);
$$;

create function private.notification_fleet_recipients(
  p_fleet_id uuid
) returns uuid[]
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(array_agg(distinct fm.user_id), '{}'::uuid[])
  from public.fleet_memberships fm
  where fm.fleet_id = p_fleet_id and fm.status = 'active';
$$;

create function private.notification_trip_staff_recipients(
  p_trip_id uuid
) returns uuid[]
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(array_agg(distinct audience.user_id order by audience.user_id), '{}'::uuid[])
  from (
    select case when current_assignment.trip_id is not null
      then current_assignment.driver_user_id else t.driver_user_id end as user_id,
      t.fleet_id
    from public.trips t
    left join public.trip_assignments current_assignment
      on current_assignment.trip_id = t.id
     and current_assignment.valid_until is null
    where t.id = p_trip_id
      and private.has_fleet_role(
        t.fleet_id,
        case when current_assignment.trip_id is not null
          then current_assignment.driver_user_id else t.driver_user_id end,
        'driver'
      )
    union all
    select fm.user_id, t.fleet_id
    from public.trips t
    join public.fleet_memberships fm
      on fm.fleet_id = t.fleet_id and fm.status = 'active'
    join public.fleet_membership_roles fmr
      on fmr.membership_id = fm.id and fmr.role = 'owner'
    where t.id = p_trip_id
  ) audience
  where audience.user_id is not null
    and private.is_active_fleet_member(audience.fleet_id, audience.user_id);
$$;

create function private.notification_school_recipients(
  p_trip_id uuid,
  p_school_id uuid
) returns uuid[]
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(array_agg(distinct audience.user_id order by audience.user_id), '{}'::uuid[])
  from (
    select unnest(private.notification_trip_staff_recipients(p_trip_id)) as user_id
    union all
    select s.profile_id
    from public.trip_passengers tp
    join public.students s on s.id = tp.student_id
    where tp.trip_id = p_trip_id and tp.removed_at is null
      and tp.school_id = p_school_id and s.profile_id is not null
    union all
    select sg.guardian_user_id
    from public.trip_passengers tp
    join public.student_guardians sg
      on sg.student_id = tp.student_id and sg.status = 'active'
    where tp.trip_id = p_trip_id and tp.removed_at is null
      and tp.school_id = p_school_id
  ) audience
  join public.trips t on t.id = p_trip_id
  where audience.user_id is not null
    and private.is_active_fleet_member(t.fleet_id, audience.user_id);
$$;

create function private.notification_stop_recipients(
  p_trip_id uuid,
  p_stop_id uuid
) returns uuid[]
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_stop public.trip_stops%rowtype;
begin
  select * into v_stop
  from public.trip_stops
  where id = p_stop_id and trip_id = p_trip_id;
  if not found then
    return '{}'::uuid[];
  end if;
  if v_stop.kind = 'school' then
    return private.notification_school_recipients(p_trip_id, v_stop.school_id);
  elsif v_stop.kind = 'home' then
    return private.notification_student_recipients(p_trip_id, v_stop.student_id);
  end if;
  return private.notification_trip_recipients(p_trip_id);
end;
$$;

create function private.notification_next_trip_staff_recipients(
  p_fleet_id uuid,
  p_student_id uuid,
  p_now timestamptz
) returns table (trip_id uuid, recipient_ids uuid[])
language sql
stable
security definer
set search_path = ''
as $$
  with next_trip as (
    select t.id, t.fleet_id
    from public.trips t
    join public.trip_passengers tp on tp.trip_id = t.id and tp.fleet_id = t.fleet_id
    join public.fleet_enrollments e
      on e.id = tp.enrollment_id and e.fleet_id = t.fleet_id
    where t.fleet_id = p_fleet_id and tp.student_id = p_student_id
      and tp.removed_at is null and e.status = 'active'
      and t.status in ('scheduled', 'confirmation_closed')
      and t.started_at is null and t.planned_start_at >= p_now
    order by t.planned_start_at, t.id
    limit 1
  )
  select n.id,
    private.notification_trip_staff_recipients(n.id)
  from next_trip n;
$$;

create function private.materialize_confirmation_reminders(
  p_limit integer,
  p_now timestamptz
) returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_passenger record;
  v_recipient_ids uuid[];
  v_count integer := 0;
begin
  for v_passenger in
    select tp.trip_id, tp.student_id, t.fleet_id, t.confirmation_deadline
    from public.trip_passengers tp
    join public.trips t on t.id = tp.trip_id and t.fleet_id = tp.fleet_id
    where t.status = 'scheduled'
      and tp.removed_at is null and tp.confirmation_status = 'pending'
      and t.confirmation_deadline > p_now
      and t.confirmation_deadline <= p_now + interval '10 minutes'
    order by t.confirmation_deadline, tp.trip_id, tp.student_id
    limit p_limit
  loop
    v_recipient_ids := private.notification_student_recipients(
      v_passenger.trip_id, v_passenger.student_id
    );
    if not exists (
      select 1
      from public.notifications n
      where n.fleet_id = v_passenger.fleet_id
        and n.event_key = 'confirmation_reminder:' || v_passenger.trip_id::text
          || ':' || v_passenger.student_id::text
    ) then
      perform private.create_notification(
        v_passenger.fleet_id,
        'confirmation_reminder:' || v_passenger.trip_id::text || ':' || v_passenger.student_id::text,
        'confirmation_reminder', 'trip', v_passenger.trip_id,
        jsonb_build_object(
          'message', 'O prazo de confirmação da viagem está próximo.',
          'trip_id', v_passenger.trip_id,
          'student_id', v_passenger.student_id,
          'deadline', v_passenger.confirmation_deadline
        ),
        p_now, v_passenger.confirmation_deadline, v_recipient_ids
      );
      v_count := v_count + 1;
    end if;
  end loop;
  return v_count;
end;
$$;

create function private.notification_actionable(
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
  if p_notification_id is null or p_user_id is null or p_now is null then
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
    elsif v_notification.category in ('boarded', 'dropped_off', 'absent', 'school_arrival', 'arrival') then
      return p_now < v_notification.expires_at;
    end if;
  end if;

  return true;
end;
$$;

create function private.materialize_notifications(
  p_limit integer,
  p_now timestamptz
) returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_state private.notification_worker_state%rowtype;
  v_event public.trip_events%rowtype;
  v_trip public.trips%rowtype;
  v_student_id uuid;
  v_stop_id uuid;
  v_category text;
  v_message text;
  v_recipients uuid[];
  v_expires_at timestamptz;
  v_entity_id uuid;
  v_should_notify boolean;
  v_processed integer := 0;
begin
  if p_limit is null or p_limit < 1 or p_limit > 100 or p_now is null then
    perform private.raise_api_error('invalid_input', 'Invalid materialization window', 400);
  end if;

  select * into v_state
  from private.notification_worker_state
  where id = true
  for update;
  if not found or not v_state.enabled then
    return 0;
  end if;

  for v_event in
    select e.*
    from public.trip_events e
    left join private.notification_processed_events processed
      on processed.event_id = e.id
    where e.id > v_state.activation_event_id and processed.event_id is null
    order by e.id
    limit p_limit
    for update of e skip locked
  loop
    select t.* into v_trip from public.trips t where t.id = v_event.trip_id;
    v_entity_id := v_event.trip_id;
    v_student_id := null;
    v_stop_id := null;
    v_category := null;
    v_message := null;
    v_recipients := '{}'::uuid[];
    v_expires_at := null;
    v_should_notify := true;
    if (v_event.payload->>'student_id') ~
      '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' then
      v_student_id := (v_event.payload->>'student_id')::uuid;
    end if;
    if (v_event.payload->>'stop_id') ~
      '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' then
      v_stop_id := (v_event.payload->>'stop_id')::uuid;
    end if;

    case v_event.kind
      when 'trip_generated' then
        v_category := 'confirmation_available';
        v_message := 'Uma confirmação de viagem está disponível.';
        v_recipients := private.notification_trip_recipients(v_event.trip_id);
        v_expires_at := v_trip.confirmation_deadline;
      when 'confirmation_closed' then
        v_category := 'confirmation_closed';
        v_message := 'O prazo de confirmação da viagem foi encerrado.';
        v_recipients := private.notification_trip_recipients(v_event.trip_id);
        v_expires_at := v_trip.reserved_until;
      when 'trip_started' then
        v_category := 'trip_started';
        v_message := 'A viagem foi iniciada.';
        v_recipients := private.notification_trip_recipients(v_event.trip_id);
        v_expires_at := v_trip.reserved_until;
      when 'student_confirmed' then
        v_category := 'confirmation_updated';
        v_message := 'A participação na viagem foi confirmada.';
        v_recipients := private.notification_student_recipients(v_event.trip_id, v_student_id);
        v_expires_at := v_trip.confirmation_deadline;
      when 'student_declined' then
        v_category := 'confirmation_updated';
        v_message := 'A participação na viagem foi recusada.';
        v_recipients := private.notification_student_recipients(v_event.trip_id, v_student_id);
        v_expires_at := v_trip.confirmation_deadline;
      when 'participation_overridden' then
        v_category := 'confirmation_updated';
        v_message := 'A participação na viagem foi atualizada.';
        v_recipients := private.notification_student_recipients(v_event.trip_id, v_student_id);
        v_expires_at := v_event.occurred_at + interval '24 hours';
      when 'student_boarded' then
        v_category := 'boarded';
        v_message := 'O embarque foi registrado.';
        v_recipients := private.notification_student_recipients(v_event.trip_id, v_student_id);
        v_expires_at := v_event.occurred_at + interval '24 hours';
      when 'student_dropped_off' then
        v_category := 'dropped_off';
        v_message := 'O desembarque foi registrado.';
        v_recipients := private.notification_student_recipients(v_event.trip_id, v_student_id);
        v_expires_at := v_event.occurred_at + interval '24 hours';
      when 'student_absent' then
        v_category := 'absent';
        v_message := 'A ausência foi registrada.';
        v_recipients := private.notification_student_recipients(v_event.trip_id, v_student_id);
        v_expires_at := v_event.occurred_at + interval '24 hours';
      when 'school_reached' then
        v_category := 'school_arrival';
        v_message := 'A chegada à escola foi registrada.';
        v_recipients := private.notification_stop_recipients(v_event.trip_id, v_stop_id);
        v_expires_at := v_event.occurred_at + interval '24 hours';
      when 'trip_stop_reached' then
        v_category := 'arrival';
        v_message := 'A chegada à parada foi registrada.';
        v_recipients := private.notification_stop_recipients(v_event.trip_id, v_stop_id);
        v_expires_at := v_event.occurred_at + interval '24 hours';
      when 'trip_cancelled', 'service_disabled' then
        v_category := 'cancelled';
        v_message := 'Uma viagem foi cancelada.';
        v_recipients := private.notification_trip_recipients(v_event.trip_id);
        v_expires_at := v_event.occurred_at + interval '24 hours';
      when 'service_enabled' then
        v_category := 'service_enabled';
        v_message := 'O serviço da viagem foi reativado.';
        v_recipients := private.notification_trip_recipients(v_event.trip_id);
        v_expires_at := v_event.occurred_at + interval '24 hours';
      when 'trip_completed' then
        v_category := 'trip_completed';
        v_message := 'A viagem foi encerrada.';
        v_recipients := private.notification_trip_recipients(v_event.trip_id);
        v_expires_at := v_event.occurred_at + interval '24 hours';
      when 'incident_reported', 'incident_updated' then
        v_category := 'incident';
        v_message := 'Uma ocorrência foi registrada na viagem.';
        v_recipients := private.notification_trip_recipients(v_event.trip_id);
        v_expires_at := v_event.occurred_at + interval '24 hours';
      else
        v_should_notify := false;
    end case;

    if v_should_notify then
      if v_expires_at is null or v_expires_at <= v_event.occurred_at then
        v_expires_at := v_event.occurred_at + interval '24 hours';
      end if;
      perform private.create_notification(
        v_event.fleet_id,
        'trip_event:' || v_event.id::text,
        v_category,
        'trip',
        v_entity_id,
        jsonb_strip_nulls(jsonb_build_object(
          'message', v_message,
          'trip_id', v_event.trip_id,
          'student_id', v_student_id,
          'stop_id', v_stop_id,
          'occurred_at', v_event.occurred_at
        )),
        v_event.occurred_at,
        v_expires_at,
        coalesce(v_recipients, '{}'::uuid[])
      );
    end if;
    insert into private.notification_processed_events(event_id, processed_at)
    values (v_event.id, p_now)
    on conflict (event_id) do nothing;
    v_processed := v_processed + 1;
  end loop;
  v_processed := v_processed + private.materialize_confirmation_reminders(p_limit, p_now);
  return v_processed;
end;
$$;

create function private.notify_join_request_transition()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_category text;
  v_message text;
begin
  if old.status is not distinct from new.status
    or new.status not in ('approved', 'rejected') then
    return new;
  end if;
  v_category := case when new.status = 'approved' then 'approval' else 'rejection' end;
  v_message := case when new.status = 'approved'
    then 'Seu pedido de transporte foi aprovado.'
    else 'Seu pedido de transporte foi recusado.' end;
  perform private.create_notification(
    new.fleet_id,
    'join_request:' || new.id::text || ':' || new.status,
    v_category,
    'join_request',
    new.id,
    jsonb_strip_nulls(jsonb_build_object(
      'message', v_message,
      'request_id', new.id,
      'student_id', new.student_id,
      'status', new.status
    )),
    coalesce(new.decided_at, clock_timestamp()),
    coalesce(new.decided_at, clock_timestamp()) + interval '24 hours',
    array[new.requester_user_id]
  );
  return new;
end;
$$;

create function private.notification_trip_driver_is_current(
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
      and private.has_fleet_role(t.fleet_id, p_user_id, 'driver')
      and (
        exists (
          select 1
          from public.trip_assignments assignment
          where assignment.trip_id = t.id
            and assignment.valid_until is null
            and assignment.driver_user_id = p_user_id
        )
        or (
          not exists (
            select 1
            from public.trip_assignments assignment
            where assignment.trip_id = t.id and assignment.valid_until is null
          )
          and t.driver_user_id = p_user_id
        )
      )
  );
$$;

create function private.notification_context_authorized(
  p_notification_id uuid,
  p_user_id uuid
) returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_notification public.notifications%rowtype;
  v_target_id uuid;
  v_student_id uuid;
  v_scope text;
begin
  select * into v_notification
  from public.notifications
  where id = p_notification_id;
  if not found then
    return false;
  end if;
  if v_notification.entity_type = 'join_request' then
    return exists (
      select 1 from public.fleet_join_requests request
      where request.id = v_notification.entity_id
        and request.fleet_id = v_notification.fleet_id
        and request.requester_user_id = p_user_id
    );
  end if;
  if not private.is_active_fleet_member(v_notification.fleet_id, p_user_id) then
    return false;
  end if;
  if private.has_fleet_role(v_notification.fleet_id, p_user_id, 'owner') then
    return true;
  end if;

  if v_notification.entity_type = 'trip' then
    if private.notification_trip_driver_is_current(v_notification.entity_id, p_user_id) then
      return true;
    end if;
    if (v_notification.body->>'student_id') ~
      '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' then
      v_student_id := (v_notification.body->>'student_id')::uuid;
      return exists (
        select 1
        from public.trip_passengers tp
        where tp.trip_id = v_notification.entity_id
          and tp.student_id = v_student_id
          and tp.removed_at is null
          and private.can_view_student(v_student_id, p_user_id)
      );
    end if;
    if (v_notification.body->>'stop_id') ~
      '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' then
      v_target_id := (v_notification.body->>'stop_id')::uuid;
      return exists (
        select 1
        from public.trip_stops stop
        join public.trip_passengers tp on tp.trip_id = stop.trip_id
        where stop.id = v_target_id
          and stop.trip_id = v_notification.entity_id
          and tp.removed_at is null
          and (
            (stop.kind = 'home' and stop.student_id = tp.student_id)
            or (stop.kind = 'school' and tp.school_id = stop.school_id)
          )
          and private.can_view_student(tp.student_id, p_user_id)
      );
    end if;
    return exists (
      select 1
      from public.trip_passengers tp
      where tp.trip_id = v_notification.entity_id
        and tp.removed_at is null
        and private.can_view_student(tp.student_id, p_user_id)
    );
  end if;

  if v_notification.entity_type = 'manual' then
    v_scope := v_notification.body->>'scope';
    if v_scope = 'trip' and (v_notification.body->>'target_id') ~
      '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' then
      v_target_id := (v_notification.body->>'target_id')::uuid;
      if private.notification_trip_driver_is_current(v_target_id, p_user_id) then
        return true;
      end if;
      return exists (
        select 1
        from public.trip_passengers tp
        where tp.trip_id = v_target_id and tp.removed_at is null
          and private.can_view_student(tp.student_id, p_user_id)
      );
    elsif v_scope = 'route' and (v_notification.body->>'target_id') ~
      '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' then
      v_target_id := (v_notification.body->>'target_id')::uuid;
      return exists (
        select 1 from public.routes route
        where route.id = v_target_id and route.fleet_id = v_notification.fleet_id
          and route.status = 'active' and route.driver_user_id = p_user_id
          and private.has_fleet_role(v_notification.fleet_id, p_user_id, 'driver')
      ) or exists (
        select 1
        from public.transport_reservations reservation
        join public.fleet_enrollments enrollment
          on enrollment.id = reservation.enrollment_id
         and enrollment.fleet_id = reservation.fleet_id
         and enrollment.status = 'active'
        where reservation.route_id = v_target_id
          and reservation.fleet_id = v_notification.fleet_id
          and reservation.status = 'active'
          and reservation.valid_until >= current_date
          and private.can_view_student(reservation.student_id, p_user_id)
      );
    elsif v_scope = 'van' and (v_notification.body->>'target_id') ~
      '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' then
      v_target_id := (v_notification.body->>'target_id')::uuid;
      return exists (
        select 1 from public.routes route
        where route.van_id = v_target_id and route.fleet_id = v_notification.fleet_id
          and route.status = 'active' and route.driver_user_id = p_user_id
          and private.has_fleet_role(v_notification.fleet_id, p_user_id, 'driver')
      ) or exists (
        select 1
        from public.routes route
        join public.transport_reservations reservation
          on reservation.route_id = route.id
         and reservation.fleet_id = route.fleet_id
         and reservation.status = 'active'
         and reservation.valid_until >= current_date
        join public.fleet_enrollments enrollment
          on enrollment.id = reservation.enrollment_id
         and enrollment.fleet_id = reservation.fleet_id
         and enrollment.status = 'active'
        where route.van_id = v_target_id
          and route.fleet_id = v_notification.fleet_id
          and route.status = 'active'
          and private.can_view_student(reservation.student_id, p_user_id)
      );
    end if;
    return true;
  end if;

  if v_notification.entity_type in ('student', 'enrollment') then
    if (v_notification.body->>'trip_id') ~
      '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
      and private.notification_trip_driver_is_current(
        (v_notification.body->>'trip_id')::uuid, p_user_id
      ) then
      return true;
    end if;
    if (v_notification.body->>'student_id') ~
      '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' then
      v_student_id := (v_notification.body->>'student_id')::uuid;
      return private.can_view_student(v_student_id, p_user_id);
    end if;
    return false;
  end if;
  return true;
end;
$$;

create or replace function private.can_read_notification(
  p_notification_id uuid,
  p_user_id uuid
) returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.notification_recipients nr
    where nr.notification_id = p_notification_id
      and nr.user_id = p_user_id
      and private.notification_context_authorized(p_notification_id, p_user_id)
  );
$$;

create function private.notify_student_update()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_changed_fields text[];
  v_address_changed boolean;
  v_category text;
  v_next record;
  v_event_at timestamptz;
begin
  v_changed_fields := array_remove(array[
    case when old.full_name is distinct from new.full_name then 'full_name' end,
    case when old.birth_date is distinct from new.birth_date then 'birth_date' end,
    case when old.postal_code is distinct from new.postal_code then 'postal_code' end,
    case when old.street is distinct from new.street then 'street' end,
    case when old.street_number is distinct from new.street_number then 'street_number' end,
    case when old.address_complement is distinct from new.address_complement then 'address_complement' end,
    case when old.neighborhood is distinct from new.neighborhood then 'neighborhood' end,
    case when old.city_name is distinct from new.city_name then 'city_name' end,
    case when old.city_ibge_code is distinct from new.city_ibge_code then 'city_ibge_code' end,
    case when old.state_code is distinct from new.state_code then 'state_code' end,
    case when old.latitude is distinct from new.latitude then 'latitude' end,
    case when old.longitude is distinct from new.longitude then 'longitude' end
  ], null);
  if cardinality(v_changed_fields) = 0 then
    return new;
  end if;
  v_address_changed := v_changed_fields && array[
    'postal_code', 'street', 'street_number', 'address_complement', 'neighborhood',
    'city_name', 'city_ibge_code', 'state_code', 'latitude', 'longitude'
  ];
  v_category := case when v_address_changed then 'address_updated' else 'student_updated' end;
  v_event_at := clock_timestamp();

  for v_next in
    select e.fleet_id, next_trip.trip_id, next_trip.recipient_ids
    from public.fleet_enrollments e
    cross join lateral private.notification_next_trip_staff_recipients(
      e.fleet_id, new.id, clock_timestamp()
    ) next_trip
    where e.student_id = new.id and e.status = 'active'
  loop
    if cardinality(v_next.recipient_ids) > 0 then
      perform private.create_notification(
        v_next.fleet_id,
        'student_update:' || new.id::text || ':' ||
          to_char(v_event_at at time zone 'UTC', 'YYYYMMDDHH24MISSMS'),
        v_category, 'student', new.id,
        jsonb_build_object(
          'message', case when v_address_changed
            then 'Os dados de endereço do aluno foram atualizados.'
            else 'Os dados do aluno foram atualizados.' end,
          'student_id', new.id,
          'trip_id', v_next.trip_id,
          'changed_fields', to_jsonb(v_changed_fields)
        ),
        v_event_at, v_event_at + interval '24 hours', v_next.recipient_ids
      );
    end if;
  end loop;
  return new;
end;
$$;

create function private.notify_enrollment_school_update()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_next record;
  v_event_at timestamptz;
begin
  if old.school_id is not distinct from new.school_id then
    return new;
  end if;
  v_event_at := clock_timestamp();
  for v_next in
    select e.fleet_id, next_trip.trip_id, next_trip.recipient_ids
    from public.fleet_enrollments e
    cross join lateral private.notification_next_trip_staff_recipients(
      e.fleet_id, new.student_id, clock_timestamp()
    ) next_trip
    where e.id = new.id and e.status = 'active'
  loop
    if cardinality(v_next.recipient_ids) > 0 then
      perform private.create_notification(
        v_next.fleet_id,
        'school_update:' || new.id::text || ':' || new.routing_revision::text,
        'school_updated', 'enrollment', new.id,
        jsonb_build_object(
          'message', 'A escola do aluno foi atualizada.',
          'student_id', new.student_id,
          'enrollment_id', new.id,
          'trip_id', v_next.trip_id
        ),
        v_event_at, v_event_at + interval '24 hours',
        v_next.recipient_ids
      );
    end if;
  end loop;
  return new;
end;
$$;

drop trigger if exists student_notification_update on public.students;
create trigger student_notification_update
after update on public.students
for each row execute function private.notify_student_update();

drop trigger if exists enrollment_school_notification_update on public.fleet_enrollments;
create trigger enrollment_school_notification_update
after update of school_id on public.fleet_enrollments
for each row execute function private.notify_enrollment_school_update();

drop trigger if exists fleet_join_request_notification on public.fleet_join_requests;
create trigger fleet_join_request_notification
after update of status on public.fleet_join_requests
for each row execute function private.notify_join_request_transition();

create function public.send_manual_notification(
  p_fleet_id uuid,
  p_scope text,
  p_target_id uuid,
  p_category text,
  p_message text,
  p_command_id uuid
) returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_message text := nullif(btrim(p_message), '');
  v_existing private.notification_manual_commands%rowtype;
  v_hash bytea;
  v_notification_id uuid;
  v_recipients uuid[];
  v_count integer;
  v_is_owner boolean;
  v_constraint text;
begin
  if v_user_id is null then
    perform private.raise_api_error('unauthenticated', 'Authentication required', 401);
  end if;
  if not private.current_user_email_confirmed() then
    perform private.raise_api_error('email_unverified', 'Email confirmation required', 403);
  end if;
  if p_fleet_id is null or p_scope is null or p_target_id is null
    or p_category is null or p_command_id is null
    or v_message is null or char_length(v_message) > 2000 then
    perform private.raise_api_error('invalid_input', 'Invalid manual notification', 400);
  end if;
  if p_scope not in ('fleet', 'route', 'trip', 'van', 'user') then
    perform private.raise_api_error('invalid_audience', 'Invalid notification audience', 400);
  end if;
  if p_category not in ('delay', 'arrival', 'incident', 'reminder', 'notice') then
    perform private.raise_api_error('invalid_input', 'Invalid notification category', 400);
  end if;
  if not exists (select 1 from public.fleets f where f.id = p_fleet_id) then
    perform private.raise_api_error('not_found', 'Fleet not found', 404);
  end if;

  -- Authorization and recipient resolution share the planning lock with
  -- route/driver revocations, so a manual message cannot cross a change.
  perform private.lock_planning();

  v_is_owner := private.has_fleet_role(p_fleet_id, v_user_id, 'owner');
  if not v_is_owner then
    if not private.has_fleet_role(p_fleet_id, v_user_id, 'driver')
      or p_scope <> 'trip'
      or p_category not in ('delay', 'arrival', 'incident', 'reminder')
      or not exists (
        select 1 from public.trips t
        where t.id = p_target_id and t.fleet_id = p_fleet_id
          and t.status in ('scheduled', 'confirmation_closed', 'active')
          and private.notification_trip_driver_is_current(t.id, v_user_id)
      ) then
      perform private.raise_api_error('forbidden', 'Manual audience is not allowed', 403);
    end if;
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('manual-notification:' || p_fleet_id::text || ':'
      || v_user_id::text, 0)
  );
  v_hash := extensions.digest(
    jsonb_build_object('scope', p_scope, 'target_id', p_target_id,
      'category', p_category, 'message', v_message)::text,
    'sha256'
  );
  select * into v_existing
  from private.notification_manual_commands c
  where c.fleet_id = p_fleet_id and c.command_id = p_command_id
  for update;
  if found then
    if v_existing.actor_user_id <> v_user_id or v_existing.payload_hash <> v_hash then
      perform private.raise_api_error('idempotency_conflict', 'Command payload differs', 409);
    end if;
    return v_existing.notification_id;
  end if;

  select count(*)::integer into v_count
  from private.notification_manual_commands c
  where c.fleet_id = p_fleet_id and c.actor_user_id = v_user_id
    and c.created_at > clock_timestamp() - interval '1 minute';
  if v_count >= 10 then
    perform private.raise_api_error('rate_limited', 'Manual notification limit reached', 429);
  end if;

  if p_scope = 'fleet' then
    if p_target_id <> p_fleet_id then
      perform private.raise_api_error('invalid_audience', 'Fleet target differs', 400);
    end if;
    v_recipients := private.notification_fleet_recipients(p_fleet_id);
  elsif p_scope = 'route' then
    if not exists (
      select 1 from public.routes r where r.id = p_target_id and r.fleet_id = p_fleet_id
    ) then
      perform private.raise_api_error('invalid_audience', 'Route is outside the fleet', 400);
    end if;
    v_recipients := private.notification_route_recipients(p_fleet_id, p_target_id);
  elsif p_scope = 'trip' then
    if not exists (
      select 1 from public.trips t where t.id = p_target_id and t.fleet_id = p_fleet_id
    ) then
      perform private.raise_api_error('invalid_audience', 'Trip is outside the fleet', 400);
    end if;
    v_recipients := private.notification_trip_recipients(p_target_id);
  elsif p_scope = 'van' then
    if not exists (
      select 1 from public.vans v where v.id = p_target_id and v.fleet_id = p_fleet_id
    ) then
      perform private.raise_api_error('invalid_audience', 'Van is outside the fleet', 400);
    end if;
    select coalesce(array_agg(distinct recipient_id), '{}'::uuid[])
    into v_recipients
    from public.routes r
    cross join lateral unnest(private.notification_route_recipients(p_fleet_id, r.id)) audience(recipient_id)
    where r.fleet_id = p_fleet_id and r.van_id = p_target_id;
  else
    if not private.is_active_fleet_member(p_fleet_id, p_target_id) then
      perform private.raise_api_error('invalid_audience', 'User is outside the fleet', 400);
    end if;
    v_recipients := array[p_target_id];
  end if;

  v_notification_id := private.create_notification(
    p_fleet_id,
    'manual:' || p_command_id::text,
    p_category,
    'manual',
    p_target_id,
    jsonb_build_object(
      'message', v_message,
      'scope', p_scope,
      'target_id', p_target_id,
      'command_id', p_command_id
    ),
    clock_timestamp(),
    clock_timestamp() + interval '24 hours',
    coalesce(v_recipients, '{}'::uuid[])
  );
  insert into private.notification_manual_commands (
    fleet_id, actor_user_id, command_id, notification_id, payload_hash
  ) values (
    p_fleet_id, v_user_id, p_command_id, v_notification_id, v_hash
  );
  return v_notification_id;
exception
  when unique_violation then
    get stacked diagnostics v_constraint = constraint_name;
    if v_constraint = 'notification_manual_commands_pkey' then
      perform private.raise_api_error('idempotency_conflict', 'Command already exists', 409);
    end if;
    raise;
end;
$$;

revoke all on function private.notification_trip_recipients(uuid)
  from public, anon, authenticated;
revoke all on function private.notification_student_recipients(uuid, uuid)
  from public, anon, authenticated;
revoke all on function private.notification_route_recipients(uuid, uuid)
  from public, anon, authenticated;
revoke all on function private.notification_fleet_recipients(uuid)
  from public, anon, authenticated;
revoke all on function private.notification_trip_staff_recipients(uuid)
  from public, anon, authenticated;
revoke all on function private.notification_school_recipients(uuid, uuid)
  from public, anon, authenticated;
revoke all on function private.notification_stop_recipients(uuid, uuid)
  from public, anon, authenticated;
revoke all on function private.notification_next_trip_staff_recipients(uuid, uuid, timestamptz)
  from public, anon, authenticated;
revoke all on function private.materialize_confirmation_reminders(integer, timestamptz)
  from public, anon, authenticated;
revoke all on function private.notification_actionable(uuid, uuid, timestamptz)
  from public, anon, authenticated;
revoke all on function private.materialize_notifications(integer, timestamptz)
  from public, anon, authenticated;
revoke all on function private.notify_join_request_transition()
  from public, anon, authenticated;
revoke all on function private.notification_trip_driver_is_current(uuid, uuid)
  from public, anon, authenticated;
revoke all on function private.notification_context_authorized(uuid, uuid)
  from public, anon, authenticated;
revoke all on function private.can_read_notification(uuid, uuid)
  from public, anon, authenticated;
revoke all on function private.notify_student_update()
  from public, anon, authenticated;
revoke all on function private.notify_enrollment_school_update()
  from public, anon, authenticated;
revoke all on function public.send_manual_notification(uuid, text, uuid, text, text, uuid)
  from public, anon;
grant execute on function public.send_manual_notification(uuid, text, uuid, text, text, uuid)
  to authenticated;
grant execute on function private.notification_actionable(uuid, uuid, timestamptz)
  to postgres, supabase_admin;
grant execute on function private.materialize_notifications(integer, timestamptz)
  to postgres, supabase_admin;
grant execute on function private.materialize_confirmation_reminders(integer, timestamptz)
  to postgres, supabase_admin;
