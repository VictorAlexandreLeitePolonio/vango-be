alter table public.audit_events
  drop constraint if exists audit_events_action_valid;

alter table public.audit_events
  add constraint audit_events_action_valid check (action in (
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
    'enrollment_school_updated', 'service_enabled', 'service_disabled'
  ));

alter table public.audit_events
  drop constraint if exists audit_events_entity_type_valid;

alter table public.audit_events
  add constraint audit_events_entity_type_valid check (entity_type in (
    'fleet', 'fleet_membership', 'service_city', 'service_school', 'student',
    'student_guardian', 'join_request', 'fleet_invitation', 'enrollment',
    'van', 'route', 'route_schedule', 'route_student_schedule',
    'transport_reservation', 'service_day', 'trip'
  ));

create table public.route_service_exceptions (
  fleet_id uuid not null references public.fleets(id) on delete restrict,
  route_id uuid not null,
  service_date date not null,
  enabled boolean not null,
  reason text,
  updated_by uuid not null references public.profiles(id) on delete restrict,
  updated_at timestamptz not null default now(),
  primary key (route_id, service_date),
  constraint route_service_exceptions_route_fleet_fk
    foreign key (fleet_id, route_id)
    references public.routes(fleet_id, id)
    on delete restrict,
  constraint route_service_exceptions_reason_not_blank
    check (reason is null or btrim(reason) <> '')
);

create index route_service_exceptions_fleet_date_idx
  on public.route_service_exceptions (fleet_id, service_date);

create table public.service_days (
  id uuid primary key default extensions.gen_random_uuid(),
  fleet_id uuid not null references public.fleets(id) on delete restrict,
  service_date date not null,
  constraint service_days_fleet_date_key unique (fleet_id, service_date),
  constraint service_days_id_fleet_key unique (id, fleet_id),
  constraint service_days_id_fleet_date_key unique (id, fleet_id, service_date)
);

create index service_days_fleet_date_idx
  on public.service_days (fleet_id, service_date);

create table public.trips (
  id uuid primary key default extensions.gen_random_uuid(),
  fleet_id uuid not null references public.fleets(id) on delete restrict,
  service_day_id uuid not null,
  route_id uuid not null,
  schedule_id uuid not null,
  service_date date not null,
  planned_start_at timestamptz not null,
  reserved_until timestamptz not null,
  confirmation_deadline timestamptz not null,
  status text not null default 'scheduled',
  van_id uuid,
  driver_user_id uuid references public.profiles(id) on delete restrict,
  started_at timestamptz,
  ended_at timestamptz,
  revision bigint not null default 1,
  event_sequence bigint not null default 0,
  constraint trips_service_day_fleet_fk
    foreign key (service_day_id, fleet_id, service_date)
    references public.service_days(id, fleet_id, service_date)
    on delete restrict,
  constraint trips_route_fleet_fk
    foreign key (fleet_id, route_id)
    references public.routes(fleet_id, id)
    on delete restrict,
  constraint trips_schedule_fleet_fk
    foreign key (fleet_id, schedule_id)
    references public.route_schedules(fleet_id, id)
    on delete restrict,
  constraint trips_van_fleet_fk
    foreign key (fleet_id, van_id)
    references public.vans(fleet_id, id)
    on delete restrict,
  constraint trips_window_valid check (planned_start_at < reserved_until),
  constraint trips_confirmation_deadline_valid check (confirmation_deadline <= planned_start_at),
  constraint trips_status_valid check (status in (
    'scheduled', 'confirmation_closed', 'active', 'completed', 'cancelled'
  )),
  constraint trips_revision_positive check (revision > 0),
  constraint trips_event_sequence_nonnegative check (event_sequence >= 0),
  constraint trips_started_dates_valid check (
    (started_at is null and ended_at is null)
    or (started_at is not null and (ended_at is null or ended_at >= started_at))
  ),
  constraint trips_schedule_date_key unique (schedule_id, service_date),
  constraint trips_id_fleet_key unique (id, fleet_id)
);

create index trips_fleet_date_idx on public.trips (fleet_id, service_date);
create index trips_route_date_idx on public.trips (route_id, service_date);
create index trips_driver_status_idx on public.trips (driver_user_id, status);
create index trips_van_status_idx on public.trips (van_id, status);

alter table public.route_service_exceptions enable row level security;
alter table public.service_days enable row level security;
alter table public.trips enable row level security;

revoke all on public.route_service_exceptions from anon, authenticated;
revoke all on public.service_days from anon, authenticated;
revoke all on public.trips from anon, authenticated;

create function public.set_service_enabled(
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
  v_count integer := 0;
  v_reason text := nullif(btrim(p_reason), '');
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
    select 1
    from unnest(p_route_ids) requested(route_id)
    left join public.routes r
      on r.id = requested.route_id and r.fleet_id = p_fleet_id
    where r.id is null
  ) then
    perform private.raise_api_error('not_found', 'Route not found', 404);
  end if;

  for v_route_id in
    select r.id
    from public.routes r
    where r.fleet_id = p_fleet_id
      and (p_route_ids is null or r.id = any(p_route_ids))
    order by r.id
    for update
  loop
    insert into public.route_service_exceptions (
      fleet_id, route_id, service_date, enabled, reason, updated_by, updated_at
    ) values (
      p_fleet_id, v_route_id, p_service_date, p_enabled, v_reason, v_user_id,
      clock_timestamp()
    )
    on conflict (route_id, service_date) do update
      set enabled = excluded.enabled,
          reason = excluded.reason,
          updated_by = excluded.updated_by,
          updated_at = excluded.updated_at;

    if not p_enabled then
      update public.trips
      set status = 'cancelled', revision = revision + 1
      where fleet_id = p_fleet_id
        and route_id = v_route_id
        and service_date = p_service_date
        and status in ('scheduled', 'confirmation_closed');
    else
      update public.trips
      set status = 'scheduled', revision = revision + 1,
          started_at = null, ended_at = null
      where fleet_id = p_fleet_id
        and route_id = v_route_id
        and service_date = p_service_date
        and status = 'cancelled'
        and started_at is null;
    end if;

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

revoke all on function public.set_service_enabled(uuid, uuid[], date, boolean, text)
  from public, anon;
grant execute on function public.set_service_enabled(uuid, uuid[], date, boolean, text)
  to authenticated;
