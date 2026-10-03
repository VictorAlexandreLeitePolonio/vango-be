alter table public.students
  add column registration_origin text;

update public.students
set registration_origin = case
  when student_type = 'minor' then 'guardian_created'
  when student_type = 'adult' then 'self_created'
end;

alter table public.students
  alter column registration_origin set not null,
  drop constraint students_profile_type_valid,
  add constraint students_profile_type_valid check (
    (student_type = 'minor' and registration_origin = 'guardian_created' and profile_id is null)
    or (student_type = 'minor' and registration_origin = 'fleet_owner_created' and profile_id is null)
    or (student_type = 'adult' and registration_origin = 'self_created' and profile_id is not null)
    or (student_type = 'adult' and registration_origin = 'fleet_owner_created')
  );

create or replace function public.create_minor_student(
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
) returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_student_id uuid;
begin
  if v_user_id is null then
    perform private.raise_api_error('unauthenticated', 'Authentication required', 401);
  end if;
  if not private.current_user_email_confirmed() then
    perform private.raise_api_error('email_unverified', 'Email confirmation required', 403);
  end if;

  perform private.validate_student_fields(
    p_full_name, p_birth_date, p_postal_code, p_street, p_street_number,
    p_address_complement, p_neighborhood, p_city_name, p_city_ibge_code,
    p_state_code, p_latitude, p_longitude
  );
  if age(current_date, p_birth_date) >= interval '18 years' then
    perform private.raise_api_error('student_conflict', 'Minor must be under eighteen', 409);
  end if;

  insert into public.students (
    student_type, registration_origin, full_name, birth_date, postal_code,
    street, street_number, address_complement, neighborhood, city_name,
    city_ibge_code, state_code, latitude, longitude, created_by
  ) values (
    'minor', 'guardian_created', btrim(p_full_name), p_birth_date,
    btrim(p_postal_code), btrim(p_street), btrim(p_street_number),
    nullif(btrim(p_address_complement), ''), btrim(p_neighborhood),
    btrim(p_city_name), p_city_ibge_code, p_state_code, p_latitude,
    p_longitude, v_user_id
  ) returning id into v_student_id;

  insert into public.student_guardians (student_id, guardian_user_id, is_primary)
  values (v_student_id, v_user_id, true);

  return v_student_id;
exception
  when unique_violation then
    perform private.raise_api_error('student_conflict', 'Student conflicts with an existing record', 409);
    return null;
end;
$$;

create or replace function public.create_adult_student(
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
) returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_student_id uuid;
begin
  if v_user_id is null then
    perform private.raise_api_error('unauthenticated', 'Authentication required', 401);
  end if;
  if not private.current_user_email_confirmed() then
    perform private.raise_api_error('email_unverified', 'Email confirmation required', 403);
  end if;

  perform private.validate_student_fields(
    p_full_name, p_birth_date, p_postal_code, p_street, p_street_number,
    p_address_complement, p_neighborhood, p_city_name, p_city_ibge_code,
    p_state_code, p_latitude, p_longitude
  );
  if age(current_date, p_birth_date) < interval '18 years' then
    perform private.raise_api_error('student_conflict', 'Adult must be eighteen or older', 409);
  end if;

  insert into public.students (
    student_type, profile_id, registration_origin, full_name, birth_date,
    postal_code, street, street_number, address_complement, neighborhood,
    city_name, city_ibge_code, state_code, latitude, longitude, created_by
  ) values (
    'adult', v_user_id, 'self_created', btrim(p_full_name), p_birth_date,
    btrim(p_postal_code), btrim(p_street), btrim(p_street_number),
    nullif(btrim(p_address_complement), ''), btrim(p_neighborhood),
    btrim(p_city_name), p_city_ibge_code, p_state_code, p_latitude,
    p_longitude, v_user_id
  ) returning id into v_student_id;

  return v_student_id;
exception
  when unique_violation then
    perform private.raise_api_error('student_conflict', 'A student already exists for this profile', 409);
    return null;
end;
$$;

create function private.reject_student_registration_origin_change()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.registration_origin is distinct from old.registration_origin then
    raise exception using
      errcode = '23514',
      message = 'Student registration origin is immutable';
  end if;

  return new;
end;
$$;

revoke execute on function private.reject_student_registration_origin_change()
from public, anon, authenticated;

create trigger students_registration_origin_immutable
before update of registration_origin on public.students
for each row
execute function private.reject_student_registration_origin_change();

alter table public.fleet_enrollments
  add column source_type text not null default 'join_request',
  alter column source_request_id drop not null;

alter table public.fleet_enrollments
  add constraint fleet_enrollments_source_type_valid
    check (source_type in ('join_request', 'owner_registration')),
  add constraint fleet_enrollments_source_pair_valid
    check (
      (source_type = 'join_request' and source_request_id is not null)
      or (source_type = 'owner_registration' and source_request_id is null)
    ),
  add constraint fleet_enrollments_owner_fields_valid
    check (
      source_type <> 'owner_registration'
      or (school_id is not null and shift is not null)
    );

create function private.reject_fleet_enrollment_source_change()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.source_type is distinct from old.source_type
     or new.source_request_id is distinct from old.source_request_id then
    raise exception using
      errcode = '23514',
      message = 'Fleet enrollment source is immutable';
  end if;

  return new;
end;
$$;

revoke execute on function private.reject_fleet_enrollment_source_change()
from public, anon, authenticated;

create trigger fleet_enrollments_source_immutable
before update of source_type, source_request_id on public.fleet_enrollments
for each row
execute function private.reject_fleet_enrollment_source_change();

create table public.fleet_student_contacts (
  id uuid primary key default extensions.gen_random_uuid(),
  fleet_id uuid not null,
  enrollment_id uuid not null,
  contact_type text not null,
  full_name text not null,
  email text,
  phone text,
  is_primary boolean not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint fleet_student_contacts_enrollment_fleet_fk
    foreign key (fleet_id, enrollment_id)
    references public.fleet_enrollments(fleet_id, id)
    on delete restrict,
  constraint fleet_student_contacts_type_valid
    check (contact_type in ('guardian', 'student')),
  constraint fleet_student_contacts_name_not_blank
    check (btrim(full_name) <> ''),
  constraint fleet_student_contacts_email_not_blank
    check (email is null or btrim(email) <> ''),
  constraint fleet_student_contacts_phone_not_blank
    check (phone is null or btrim(phone) <> ''),
  constraint fleet_student_contacts_method_required
    check (
      (email is not null and btrim(email) <> '')
      or (phone is not null and btrim(phone) <> '')
    )
);

create index fleet_student_contacts_fleet_enrollment_idx
  on public.fleet_student_contacts (fleet_id, enrollment_id);

create unique index fleet_student_contacts_one_primary_idx
  on public.fleet_student_contacts (fleet_id, enrollment_id)
  where is_primary;

create trigger fleet_student_contacts_set_updated_at
before update on public.fleet_student_contacts
for each row execute function private.set_updated_at();

alter table public.fleet_student_contacts enable row level security;

revoke all on table public.fleet_student_contacts from public, anon, authenticated;
grant select on table public.fleet_student_contacts to authenticated;

create policy fleet_student_contacts_select_owners
on public.fleet_student_contacts for select
to authenticated
using (
  private.has_fleet_role(fleet_id, (select auth.uid()), 'owner')
);

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
    'enrollment_school_updated', 'service_enabled', 'service_disabled',
    'fleet_student_registered'
  ));
