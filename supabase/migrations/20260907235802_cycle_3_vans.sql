create table public.vans (
  id uuid primary key default extensions.gen_random_uuid(),
  fleet_id uuid not null references public.fleets(id) on delete restrict,
  plate text not null,
  model text not null,
  public_name text not null,
  capacity integer not null,
  status text not null default 'active',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deactivated_at timestamptz,
  constraint vans_fleet_id_id_key unique (fleet_id, id),
  constraint vans_plate_format check (
    plate ~ '^[A-Z]{3}[0-9]{4}$'
    or plate ~ '^[A-Z]{3}[0-9][A-Z][0-9]{2}$'
  ),
  constraint vans_model_not_blank check (btrim(model) <> ''),
  constraint vans_public_name_not_blank check (btrim(public_name) <> ''),
  constraint vans_capacity_valid check (capacity between 1 and 100),
  constraint vans_status_valid check (status in ('active', 'inactive')),
  constraint vans_status_dates_valid check (
    (status = 'active' and deactivated_at is null)
    or (status = 'inactive' and deactivated_at is not null)
  )
);

create unique index vans_active_plate_key
on public.vans (plate)
where status = 'active';

create index vans_fleet_status_idx on public.vans (fleet_id, status);

create trigger vans_set_updated_at
before update on public.vans
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

create function private.lock_planning()
returns void
language sql
volatile
set search_path = ''
as $$
  -- ponytail: global lock serializes planning; replace with ordered resource locks if contention matters.
  select pg_advisory_xact_lock(71303, 1);
$$;

revoke execute on function private.lock_planning() from public, anon, authenticated;
grant execute on function private.lock_planning() to postgres;

alter table public.vans enable row level security;
revoke all on table public.vans from anon, authenticated;
grant select on table public.vans to authenticated;

create policy vans_select_operations
on public.vans for select
to authenticated
using (
  private.has_fleet_role(fleet_id, (select auth.uid()), 'owner')
  or private.has_fleet_role(fleet_id, (select auth.uid()), 'driver')
);

create function public.save_van(
  p_fleet_id uuid,
  p_van_id uuid,
  p_plate text,
  p_model text,
  p_public_name text,
  p_capacity integer
) returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_van public.vans%rowtype;
  v_plate text := upper(regexp_replace(coalesce(p_plate, ''), '[[:space:]-]+', '', 'g'));
  v_id uuid;
  v_action text;
begin
  if v_user_id is null then
    perform private.raise_api_error('unauthenticated', 'Authentication required', 401);
  end if;
  if not private.current_user_email_confirmed() then
    perform private.raise_api_error('email_unverified', 'Email confirmation required', 403);
  end if;
  if v_plate !~ '^[A-Z]{3}[0-9]{4}$'
    and v_plate !~ '^[A-Z]{3}[0-9][A-Z][0-9]{2}$' then
    perform private.raise_api_error('invalid_input', 'Invalid vehicle plate', 400);
  end if;
  if p_model is null or btrim(p_model) = ''
    or p_public_name is null or btrim(p_public_name) = ''
    or p_capacity is null or p_capacity < 1 or p_capacity > 100 then
    perform private.raise_api_error('invalid_input', 'Invalid vehicle fields', 400);
  end if;

  perform private.lock_planning();
  if p_fleet_id is null or not private.has_fleet_role(p_fleet_id, v_user_id, 'owner') then
    perform private.raise_api_error('not_found', 'Fleet not found', 404);
  end if;
  perform 1 from public.fleets where id = p_fleet_id for update;

  if p_van_id is null then
    insert into public.vans (fleet_id, plate, model, public_name, capacity)
    values (p_fleet_id, v_plate, btrim(p_model), btrim(p_public_name), p_capacity)
    returning id into v_id;
    v_action := 'van_created';
  else
    select * into v_van
    from public.vans
    where id = p_van_id and fleet_id = p_fleet_id
    for update;
    if not found then
      perform private.raise_api_error('not_found', 'Vehicle not found', 404);
    end if;
    update public.vans
    set plate = v_plate,
        model = btrim(p_model),
        public_name = btrim(p_public_name),
        capacity = p_capacity
    where id = p_van_id;
    v_id := p_van_id;
    v_action := 'van_updated';
  end if;

  insert into public.audit_events (
    fleet_id, actor_user_id, action, entity_type, entity_id, metadata
  ) values (
    p_fleet_id, v_user_id, v_action, 'van', v_id,
    jsonb_build_object('changed_fields', jsonb_build_array('plate', 'model', 'public_name', 'capacity'))
  );
  return v_id;
exception
  when unique_violation then
    declare
      v_constraint text;
    begin
      get stacked diagnostics v_constraint = constraint_name;
      if v_constraint = 'vans_active_plate_key' then
        perform private.raise_api_error('plate_conflict', 'Vehicle plate is already in use', 409);
      end if;
      raise;
    end;
end;
$$;

create function public.deactivate_van(
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
  update public.vans
  set status = 'inactive', deactivated_at = clock_timestamp()
  where id = p_van_id;
  insert into public.audit_events (
    fleet_id, actor_user_id, action, entity_type, entity_id, metadata
  ) values (
    v_van.fleet_id, v_user_id, 'van_deactivated', 'van', p_van_id,
    jsonb_build_object('reason_recorded', true)
  );
  return 'inactive';
end;
$$;

revoke execute on function public.save_van(uuid, uuid, text, text, text, integer) from public, anon;
revoke execute on function public.deactivate_van(uuid, text) from public, anon;
grant execute on function public.save_van(uuid, uuid, text, text, text, integer) to authenticated;
grant execute on function public.deactivate_van(uuid, text) to authenticated;
