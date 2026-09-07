create function private.raise_api_error(
  p_code text,
  p_message text,
  p_status integer
) returns void
language plpgsql
set search_path = ''
as $$
begin
  raise sqlstate 'PGRST' using
    message = jsonb_build_object('code', p_code, 'message', p_message)::text,
    detail = jsonb_build_object('status', p_status)::text;
end;
$$;

create function private.current_user_email()
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select lower(btrim(u.email))
  from auth.users u
  where u.id = auth.uid();
$$;

create function private.current_user_email_confirmed()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(u.email_confirmed_at is not null, false)
  from auth.users u
  where u.id = auth.uid();
$$;

create function private.validate_student_fields(
  p_full_name text,
  p_birth_date date,
  p_postal_code text,
  p_street text,
  p_street_number text,
  p_address_complement text,
  p_neighborhood text,
  p_city_name text,
  p_city_ibge_code text,
  p_state_code text,
  p_latitude numeric,
  p_longitude numeric
) returns void
language plpgsql
set search_path = ''
as $$
begin
  if p_full_name is null or btrim(p_full_name) = ''
    or p_birth_date is null or p_birth_date > current_date
    or p_postal_code is null or btrim(p_postal_code) = ''
    or p_street is null or btrim(p_street) = ''
    or p_street_number is null or btrim(p_street_number) = ''
    or (p_address_complement is not null and btrim(p_address_complement) = '')
    or p_neighborhood is null or btrim(p_neighborhood) = ''
    or p_city_name is null or btrim(p_city_name) = ''
    or p_city_ibge_code is null or p_city_ibge_code !~ '^[0-9]{7}$'
    or p_state_code is null or p_state_code !~ '^[A-Z]{2}$'
    or ((p_latitude is null) <> (p_longitude is null))
    or (p_latitude is not null and (p_latitude < -90 or p_latitude > 90))
    or (p_longitude is not null and (p_longitude < -180 or p_longitude > 180)) then
    perform private.raise_api_error('invalid_input', 'Invalid student or address fields', 400);
  end if;
end;
$$;

create function private.validate_request_preferences(
  p_shift text,
  p_directions text[],
  p_weekdays smallint[]
) returns void
language plpgsql
set search_path = ''
as $$
declare
begin
  if p_shift is null or p_shift not in ('morning', 'afternoon', 'evening', 'full_time')
    or p_directions is null or cardinality(p_directions) not between 1 and 2
    or exists (select 1 from unnest(p_directions) direction where direction not in ('going', 'return'))
    or cardinality(array(select distinct direction from unnest(p_directions) direction)) <> cardinality(p_directions)
    or p_weekdays is null or cardinality(p_weekdays) not between 1 and 7
    or exists (select 1 from unnest(p_weekdays) day_value where day_value < 1 or day_value > 7)
    or cardinality(array(select distinct day_value from unnest(p_weekdays) day_value)) <> cardinality(p_weekdays) then
    perform private.raise_api_error('invalid_input', 'Invalid shift, directions or weekdays', 400);
  end if;
end;
$$;

create function private.can_view_student(
  p_student_id uuid,
  p_user_id uuid
) returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.students s
    where s.id = p_student_id
      and (
        s.profile_id = p_user_id
        or exists (
          select 1
          from public.student_guardians sg
          where sg.student_id = s.id
            and sg.guardian_user_id = p_user_id
            and sg.status = 'active'
        )
      )
  );
$$;

create function private.can_manage_student(
  p_student_id uuid,
  p_user_id uuid
) returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.students s
    where s.id = p_student_id
      and (
        s.profile_id = p_user_id
        or exists (
          select 1
          from public.student_guardians sg
          where sg.student_id = s.id
            and sg.guardian_user_id = p_user_id
            and sg.status = 'active'
            and sg.is_primary
        )
      )
  );
$$;

create function private.is_active_school(p_school_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.schools s where s.id = p_school_id and s.status = 'active'
  );
$$;

create function private.sync_effective_membership_roles(p_membership_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  delete from public.fleet_membership_roles
  where membership_id = p_membership_id;

  insert into public.fleet_membership_roles (membership_id, role)
  select distinct sources.membership_id, sources.role
  from public.fleet_membership_role_sources sources
  where sources.membership_id = p_membership_id;
end;
$$;

create function private.ensure_manual_role_source()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not exists (
    select 1
    from public.fleet_membership_role_sources sources
    where sources.membership_id = new.membership_id
      and sources.role = new.role
      and sources.source_type = 'enrollment'
  ) then
    insert into public.fleet_membership_role_sources (membership_id, role, source_type)
    values (new.membership_id, new.role, 'manual')
    on conflict do nothing;
  end if;
  return new;
end;
$$;

create trigger fleet_membership_roles_manual_source
after insert on public.fleet_membership_roles
for each row execute function private.ensure_manual_role_source();

revoke execute on function private.raise_api_error(text, text, integer) from public, anon, authenticated;
revoke execute on function private.current_user_email() from public, anon, authenticated;
revoke execute on function private.current_user_email_confirmed() from public, anon, authenticated;
revoke execute on function private.validate_student_fields(text, date, text, text, text, text, text, text, text, text, numeric, numeric) from public, anon, authenticated;
revoke execute on function private.validate_request_preferences(text, text[], smallint[]) from public, anon, authenticated;
revoke execute on function private.can_view_student(uuid, uuid) from public, anon;
revoke execute on function private.can_manage_student(uuid, uuid) from public, anon;
revoke execute on function private.is_active_school(uuid) from public, anon, authenticated;
revoke execute on function private.sync_effective_membership_roles(uuid) from public, anon, authenticated;
revoke execute on function private.ensure_manual_role_source() from public, anon, authenticated;

grant usage on schema private to authenticated;
grant execute on function private.current_user_email() to authenticated;
grant execute on function private.current_user_email_confirmed() to authenticated;
grant execute on function private.can_view_student(uuid, uuid) to authenticated;
grant execute on function private.can_manage_student(uuid, uuid) to authenticated;
grant execute on function private.is_active_school(uuid) to authenticated;
grant execute on function private.is_active_fleet_member(uuid, uuid) to authenticated;
grant execute on function private.has_fleet_role(uuid, uuid, text) to authenticated;

alter table public.schools enable row level security;
alter table public.fleet_service_cities enable row level security;
alter table public.fleet_service_schools enable row level security;
alter table public.students enable row level security;
alter table public.student_guardians enable row level security;
alter table public.student_guardian_invitations enable row level security;
alter table public.fleet_invitations enable row level security;
alter table public.fleet_join_requests enable row level security;
alter table public.fleet_enrollments enable row level security;
alter table public.fleet_membership_role_sources enable row level security;

revoke all on table public.schools from anon, authenticated;
revoke all on table public.fleet_service_cities from anon, authenticated;
revoke all on table public.fleet_service_schools from anon, authenticated;
revoke all on table public.students from anon, authenticated;
revoke all on table public.student_guardians from anon, authenticated;
revoke all on table public.student_guardian_invitations from anon, authenticated;
revoke all on table public.fleet_invitations from anon, authenticated;
revoke all on table public.fleet_join_requests from anon, authenticated;
revoke all on table public.fleet_enrollments from anon, authenticated;
revoke all on table public.fleet_membership_role_sources from anon, authenticated;

grant select on table public.fleet_service_cities to authenticated;
grant insert (fleet_id, city_ibge_code, city_name, state_code, created_by) on table public.fleet_service_cities to authenticated;
grant delete on table public.fleet_service_cities to authenticated;
grant select on table public.fleet_service_schools to authenticated;
grant insert (fleet_id, school_id, created_by) on table public.fleet_service_schools to authenticated;
grant delete on table public.fleet_service_schools to authenticated;
grant select on table public.students to authenticated;
grant select on table public.student_guardians to authenticated;
grant select on table public.fleet_join_requests to authenticated;
grant select on table public.fleet_enrollments to authenticated;

create policy fleet_service_cities_select_active_members
on public.fleet_service_cities for select
to authenticated
using (private.is_active_fleet_member(fleet_id, (select auth.uid())));

create policy fleet_service_cities_insert_owners
on public.fleet_service_cities for insert
to authenticated
with check (
  created_by = (select auth.uid())
  and private.has_fleet_role(fleet_id, (select auth.uid()), 'owner')
  and city_ibge_code ~ '^[0-9]{7}$'
  and state_code ~ '^[A-Z]{2}$'
  and btrim(city_name) <> ''
);

create policy fleet_service_cities_delete_owners
on public.fleet_service_cities for delete
to authenticated
using (private.has_fleet_role(fleet_id, (select auth.uid()), 'owner'));

create policy fleet_service_schools_select_active_members
on public.fleet_service_schools for select
to authenticated
using (private.is_active_fleet_member(fleet_id, (select auth.uid())));

create policy fleet_service_schools_insert_owners
on public.fleet_service_schools for insert
to authenticated
with check (
  created_by = (select auth.uid())
  and private.has_fleet_role(fleet_id, (select auth.uid()), 'owner')
  and private.is_active_school(school_id)
);

create policy fleet_service_schools_delete_owners
on public.fleet_service_schools for delete
to authenticated
using (private.has_fleet_role(fleet_id, (select auth.uid()), 'owner'));

create policy students_select_related_user
on public.students for select
to authenticated
using (private.can_view_student(id, (select auth.uid())));

create policy student_guardians_select_related_user
on public.student_guardians for select
to authenticated
using (
  guardian_user_id = (select auth.uid())
  or private.can_manage_student(student_id, (select auth.uid()))
);

create policy fleet_join_requests_select_requester
on public.fleet_join_requests for select
to authenticated
using (requester_user_id = (select auth.uid()));

create policy fleet_enrollments_select_related_user
on public.fleet_enrollments for select
to authenticated
using (private.can_view_student(student_id, (select auth.uid())));

create or replace function public.set_fleet_member_roles(
  p_membership_id uuid,
  p_roles text[]
) returns text[]
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_fleet_id uuid;
  v_membership_status text;
  v_old_roles text[];
  v_new_roles text[];
begin
  if v_user_id is null then
    perform private.raise_api_error('unauthenticated', 'Authentication required', 401);
  end if;

  select fm.fleet_id, fm.status
  into v_fleet_id, v_membership_status
  from public.fleet_memberships fm
  where fm.id = p_membership_id
  for update;

  if not found then
    perform private.raise_api_error('membership_conflict', 'Membership not found', 404);
  end if;

  if v_membership_status <> 'active' then
    perform private.raise_api_error('membership_conflict', 'Roles require an active membership', 409);
  end if;

  perform 1 from public.fleets f where f.id = v_fleet_id for update;

  if not private.has_fleet_role(v_fleet_id, v_user_id, 'owner') then
    perform private.raise_api_error('forbidden', 'Owner role required', 403);
  end if;

  if p_roles is null or cardinality(p_roles) = 0 or array_position(p_roles, null) is not null then
    perform private.raise_api_error('invalid_input', 'At least one role is required', 400);
  end if;

  select array_agg(distinct requested.role order by requested.role)
  into v_new_roles
  from unnest(p_roles) as requested(role);

  if cardinality(v_new_roles) <> cardinality(p_roles)
    or exists (
      select 1 from unnest(v_new_roles) requested(role)
      where requested.role not in ('owner', 'driver', 'guardian', 'student')
    ) then
    perform private.raise_api_error('invalid_input', 'Roles must be unique and valid', 400);
  end if;

  select coalesce(array_agg(fmr.role order by fmr.role), array[]::text[])
  into v_old_roles
  from public.fleet_membership_roles fmr
  where fmr.membership_id = p_membership_id;

  if 'owner' = any(v_old_roles)
    and not ('owner' = any(v_new_roles))
    and private.is_last_active_owner(p_membership_id) then
    perform private.raise_api_error('last_owner', 'The last active owner cannot be removed', 409);
  end if;

  delete from public.fleet_membership_role_sources
  where membership_id = p_membership_id
    and source_type = 'manual';

  insert into public.fleet_membership_role_sources (membership_id, role, source_type)
  select p_membership_id, requested.role, 'manual'
  from unnest(v_new_roles) requested(role);

  perform private.sync_effective_membership_roles(p_membership_id);

  select coalesce(array_agg(fmr.role order by fmr.role), array[]::text[])
  into v_new_roles
  from public.fleet_membership_roles fmr
  where fmr.membership_id = p_membership_id;

  if v_old_roles is distinct from v_new_roles then
    insert into public.audit_events (
      fleet_id, actor_user_id, action, entity_type, entity_id, metadata
    ) values (
      v_fleet_id,
      v_user_id,
      'member_roles_changed',
      'fleet_membership',
      p_membership_id,
      jsonb_build_object('previous_roles', v_old_roles, 'new_roles', v_new_roles)
    );
  end if;

  return v_new_roles;
end;
$$;

revoke execute on function public.set_fleet_member_roles(uuid, text[]) from public, anon;
grant execute on function public.set_fleet_member_roles(uuid, text[]) to authenticated;
