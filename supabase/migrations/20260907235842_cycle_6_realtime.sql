-- Cycle 6 Task 2: private trip topics and revocation epochs.
-- Authorization is evaluated on channel join.  Every operation that can
-- revoke access advances the trip epoch in the same transaction, so an old
-- topic never receives a new position after that commit.

create or replace function private.rotate_trip_broadcast_epoch(
  p_trip_id uuid
) returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_epoch bigint;
begin
  if p_trip_id is null then
    return null;
  end if;
  perform private.lock_planning();
  update public.trips
  set broadcast_epoch = broadcast_epoch + 1
  where id = p_trip_id
  returning broadcast_epoch into v_epoch;
  return v_epoch;
end;
$$;

revoke all on function private.rotate_trip_broadcast_epoch(uuid)
  from public, anon, authenticated;
grant execute on function private.rotate_trip_broadcast_epoch(uuid)
  to postgres, supabase_admin;

create or replace function private.rotate_trip_topic(
  p_trip_id uuid
) returns bigint
language sql
security definer
set search_path = ''
as $$
  select private.rotate_trip_broadcast_epoch(p_trip_id);
$$;

revoke all on function private.rotate_trip_topic(uuid)
  from public, anon, authenticated;
grant execute on function private.rotate_trip_topic(uuid)
  to postgres, supabase_admin;

create or replace function private.rotate_trip_epochs_for_student(
  p_student_id uuid
) returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_trip record;
  v_count integer := 0;
begin
  if p_student_id is null then
    return 0;
  end if;
  for v_trip in
    select distinct t.id
    from public.trips t
    join public.trip_passengers p
      on p.trip_id = t.id and p.fleet_id = t.fleet_id
    where p.student_id = p_student_id
      and t.status = 'active'
  loop
    perform private.rotate_trip_broadcast_epoch(v_trip.id);
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;

revoke all on function private.rotate_trip_epochs_for_student(uuid)
  from public, anon, authenticated;
grant execute on function private.rotate_trip_epochs_for_student(uuid)
  to postgres, supabase_admin;

create or replace function private.rotate_trip_epochs_for_fleet_user(
  p_fleet_id uuid,
  p_user_id uuid
) returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_trip record;
  v_count integer := 0;
begin
  if p_fleet_id is null or p_user_id is null then
    return 0;
  end if;
  for v_trip in
    select t.id
    from public.trips t
    where t.fleet_id = p_fleet_id
      and t.status = 'active'
  loop
    perform private.rotate_trip_broadcast_epoch(v_trip.id);
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;

revoke all on function private.rotate_trip_epochs_for_fleet_user(uuid, uuid)
  from public, anon, authenticated;
grant execute on function private.rotate_trip_epochs_for_fleet_user(uuid, uuid)
  to postgres, supabase_admin;

create or replace function private.rotate_trip_epoch_from_trip_row()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.rotate_trip_broadcast_epoch(coalesce(new.id, old.id));
  return coalesce(new, old);
end;
$$;

revoke all on function private.rotate_trip_epoch_from_trip_row()
  from public, anon, authenticated;
grant execute on function private.rotate_trip_epoch_from_trip_row()
  to postgres, supabase_admin;

create or replace function private.rotate_trip_epoch_from_passenger_row()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.rotate_trip_broadcast_epoch(coalesce(new.trip_id, old.trip_id));
  return coalesce(new, old);
end;
$$;

revoke all on function private.rotate_trip_epoch_from_passenger_row()
  from public, anon, authenticated;
grant execute on function private.rotate_trip_epoch_from_passenger_row()
  to postgres, supabase_admin;

create or replace function private.rotate_trip_epoch_from_assignment_row()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.rotate_trip_broadcast_epoch(coalesce(new.trip_id, old.trip_id));
  return coalesce(new, old);
end;
$$;

revoke all on function private.rotate_trip_epoch_from_assignment_row()
  from public, anon, authenticated;
grant execute on function private.rotate_trip_epoch_from_assignment_row()
  to postgres, supabase_admin;

create or replace function private.rotate_trip_epoch_from_student_row()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.rotate_trip_epochs_for_student(coalesce(new.student_id, old.student_id));
  return coalesce(new, old);
end;
$$;

revoke all on function private.rotate_trip_epoch_from_student_row()
  from public, anon, authenticated;
grant execute on function private.rotate_trip_epoch_from_student_row()
  to postgres, supabase_admin;

create or replace function private.rotate_trip_epoch_from_enrollment_row()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_student_id uuid := coalesce(new.student_id, old.student_id);
begin
  if v_student_id is not null then
    perform private.rotate_trip_epochs_for_student(v_student_id);
  end if;
  return coalesce(new, old);
end;
$$;

revoke all on function private.rotate_trip_epoch_from_enrollment_row()
  from public, anon, authenticated;
grant execute on function private.rotate_trip_epoch_from_enrollment_row()
  to postgres, supabase_admin;

create or replace function private.rotate_trip_epoch_from_membership_row()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_membership public.fleet_memberships%rowtype;
begin
  if tg_op = 'DELETE' then
    v_membership := old;
  else
    v_membership := new;
  end if;
  perform private.rotate_trip_epochs_for_fleet_user(
    v_membership.fleet_id, v_membership.user_id
  );
  return coalesce(new, old);
end;
$$;

revoke all on function private.rotate_trip_epoch_from_membership_row()
  from public, anon, authenticated;
grant execute on function private.rotate_trip_epoch_from_membership_row()
  to postgres, supabase_admin;

create or replace function private.rotate_trip_epoch_from_membership_role_row()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_membership public.fleet_memberships%rowtype;
begin
  select * into v_membership
  from public.fleet_memberships
  where id = coalesce(new.membership_id, old.membership_id);
  if found then
    perform private.rotate_trip_epochs_for_fleet_user(
      v_membership.fleet_id, v_membership.user_id
    );
  end if;
  return coalesce(new, old);
end;
$$;

revoke all on function private.rotate_trip_epoch_from_membership_role_row()
  from public, anon, authenticated;
grant execute on function private.rotate_trip_epoch_from_membership_role_row()
  to postgres, supabase_admin;

drop trigger if exists trips_broadcast_epoch_revocation on public.trips;
create trigger trips_broadcast_epoch_revocation
after update of status, driver_user_id, van_id, started_at, ended_at
on public.trips
for each row
when (
  old.status is distinct from new.status
  or old.driver_user_id is distinct from new.driver_user_id
  or old.van_id is distinct from new.van_id
  or old.started_at is distinct from new.started_at
  or old.ended_at is distinct from new.ended_at
)
execute function private.rotate_trip_epoch_from_trip_row();

drop trigger if exists trip_passengers_broadcast_epoch_revocation on public.trip_passengers;
create trigger trip_passengers_broadcast_epoch_revocation
after update of confirmation_status, operation_status, removed_at, student_id, enrollment_id
on public.trip_passengers
for each row
when (
  old.confirmation_status is distinct from new.confirmation_status
  or old.operation_status is distinct from new.operation_status
  or old.removed_at is distinct from new.removed_at
  or old.student_id is distinct from new.student_id
  or old.enrollment_id is distinct from new.enrollment_id
)
execute function private.rotate_trip_epoch_from_passenger_row();

drop trigger if exists trip_assignments_broadcast_epoch_revocation on public.trip_assignments;
create trigger trip_assignments_broadcast_epoch_revocation
after insert or update or delete on public.trip_assignments
for each row
execute function private.rotate_trip_epoch_from_assignment_row();

drop trigger if exists student_guardians_broadcast_epoch_revocation on public.student_guardians;
create trigger student_guardians_broadcast_epoch_revocation
after update of status, removed_at, is_primary or delete on public.student_guardians
for each row
execute function private.rotate_trip_epoch_from_student_row();

drop trigger if exists fleet_enrollments_broadcast_epoch_revocation on public.fleet_enrollments;
create trigger fleet_enrollments_broadcast_epoch_revocation
after update of status, ended_at, student_id or delete on public.fleet_enrollments
for each row
execute function private.rotate_trip_epoch_from_enrollment_row();

drop trigger if exists fleet_memberships_broadcast_epoch_revocation on public.fleet_memberships;
create trigger fleet_memberships_broadcast_epoch_revocation
after update of status, user_id, fleet_id or delete on public.fleet_memberships
for each row
execute function private.rotate_trip_epoch_from_membership_row();

drop trigger if exists fleet_membership_roles_broadcast_epoch_revocation on public.fleet_membership_roles;
create trigger fleet_membership_roles_broadcast_epoch_revocation
after insert or update or delete on public.fleet_membership_roles
for each row
execute function private.rotate_trip_epoch_from_membership_role_row();

create or replace function private.can_join_trip_topic(
  p_topic text,
  p_user_id uuid
) returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_match text[];
  v_trip_id uuid;
  v_epoch bigint;
begin
  if p_topic is null or p_user_id is null
    or p_topic !~ '^trip:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}:v[1-9][0-9]*$' then
    return false;
  end if;
  select m into v_match
  from pg_catalog.regexp_matches(
    p_topic,
    '^trip:([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}):v([1-9][0-9]*)$'
  ) m;
  if v_match is null or not pg_catalog.pg_input_is_valid(v_match[1], 'uuid')
    or not pg_catalog.pg_input_is_valid(v_match[2], 'bigint') then
    return false;
  end if;
  v_trip_id := v_match[1]::uuid;
  v_epoch := v_match[2]::bigint;
  return exists (
    select 1
    from public.trips t
    where t.id = v_trip_id
      and t.broadcast_epoch = v_epoch
      and private.can_track_trip(t.id, p_user_id)
  );
end;
$$;

revoke all on function private.can_join_trip_topic(text, uuid)
  from public, anon;
grant execute on function private.can_join_trip_topic(text, uuid)
  to authenticated, postgres, supabase_admin;

create or replace function public.get_trip_tracking(
  p_trip_id uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_trip public.trips%rowtype;
  v_current public.trip_current_locations%rowtype;
  v_current_found boolean;
  v_operator boolean;
  v_current_json jsonb;
  v_stops jsonb;
  v_schools jsonb;
  v_stale boolean;
  v_topic text;
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
  select * into v_trip from public.trips where id = p_trip_id;
  if not found or not private.can_track_trip(p_trip_id, v_user_id) then
    perform private.raise_api_error('not_found', 'Trip tracking not found', 404);
  end if;
  v_operator := private.has_fleet_role(v_trip.fleet_id, v_user_id, 'owner')
    or (v_trip.driver_user_id = v_user_id
      and private.has_fleet_role(v_trip.fleet_id, v_user_id, 'driver'));
  select * into v_current from public.trip_current_locations
  where trip_id = p_trip_id;
  v_current_found := found;
  v_stale := not v_current_found
    or v_current.captured_at < clock_timestamp() - interval '30 seconds';
  select coalesce(jsonb_agg(
    jsonb_build_object(
      'id', s.id,
      'kind', s.kind,
      'student_id', s.student_id,
      'school_id', s.school_id,
      'position', s.position,
      'latitude', s.latitude,
      'longitude', s.longitude
    ) order by s.position
  ), '[]'::jsonb)
  into v_stops
  from public.trip_stops s
  where s.trip_id = p_trip_id
    and (
      v_operator
      or s.kind = 'school'
      or (
        s.kind = 'home'
        and exists (
          select 1
          from public.trip_passengers p
          where p.trip_id = p_trip_id
            and p.student_id = s.student_id
            and p.removed_at is null
            and p.confirmation_status = 'confirmed'
            and p.operation_status in ('waiting', 'boarded')
            and private.can_view_student(p.student_id, v_user_id)
        )
      )
    );
  select coalesce(jsonb_agg(
    jsonb_build_object(
      'id', s.id,
      'school_id', s.school_id,
      'position', s.position,
      'latitude', s.latitude,
      'longitude', s.longitude
    ) order by s.position
  ), '[]'::jsonb)
  into v_schools
  from public.trip_stops s
  where s.trip_id = p_trip_id and s.kind = 'school';
  v_topic := 'trip:' || p_trip_id::text || ':v' || v_trip.broadcast_epoch::text;
  v_current_json := case when v_current_found then jsonb_build_object(
    'latitude', v_current.latitude,
    'longitude', v_current.longitude,
    'accuracy', v_current.accuracy,
    'speed', v_current.speed,
    'heading', v_current.heading,
    'captured_at', v_current.captured_at,
    'received_at', v_current.received_at,
    'sequence', v_current.sequence
  ) else 'null'::jsonb end;
  return jsonb_build_object(
    'trip_id', p_trip_id,
    'topic', v_topic,
    'epoch', v_trip.broadcast_epoch,
    'last_position', v_current_json,
    'stale', v_stale,
    'own_stops', case when v_operator then '[]'::jsonb else v_stops end,
    'schools', v_schools,
    'eta', null::jsonb
  ) || case when v_operator then jsonb_build_object('operational_stops', v_stops)
    else '{}'::jsonb end;
end;
$$;

revoke all on function public.get_trip_tracking(uuid) from public, anon;
grant execute on function public.get_trip_tracking(uuid) to authenticated, service_role;

drop policy if exists trip_broadcast_read on realtime.messages;
-- Realtime authorization probes use messages.private default false; the
-- private channel flag belongs to the join/send protocol, not this probe row.
create policy trip_broadcast_read
on realtime.messages
for select
to authenticated
using (
  extension = 'broadcast'
  and private.can_join_trip_topic(realtime.topic(), (select auth.uid()))
);
