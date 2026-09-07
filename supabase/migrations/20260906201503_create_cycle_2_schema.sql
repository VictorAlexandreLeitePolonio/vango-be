create extension if not exists pgcrypto with schema extensions;
create extension if not exists unaccent with schema extensions;

create table public.schools (
  id uuid primary key default extensions.gen_random_uuid(),
  provider text not null,
  external_id text not null,
  institution_type text not null,
  name text not null,
  postal_code text not null,
  street text not null,
  street_number text not null,
  address_complement text,
  neighborhood text not null,
  city_name text not null,
  city_ibge_code text not null,
  state_code text not null,
  latitude numeric,
  longitude numeric,
  status text not null default 'active',
  source_updated_at date,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint schools_provider_valid check (provider in ('inep', 'emec')),
  constraint schools_institution_type_valid check (institution_type in ('school', 'higher_education')),
  constraint schools_provider_type_valid check (
    (provider = 'inep' and institution_type = 'school')
    or (provider = 'emec' and institution_type = 'higher_education')
  ),
  constraint schools_external_id_not_blank check (btrim(external_id) <> ''),
  constraint schools_name_not_blank check (btrim(name) <> ''),
  constraint schools_postal_code_not_blank check (btrim(postal_code) <> ''),
  constraint schools_street_not_blank check (btrim(street) <> ''),
  constraint schools_street_number_not_blank check (btrim(street_number) <> ''),
  constraint schools_address_complement_not_blank check (address_complement is null or btrim(address_complement) <> ''),
  constraint schools_neighborhood_not_blank check (btrim(neighborhood) <> ''),
  constraint schools_city_name_not_blank check (btrim(city_name) <> ''),
  constraint schools_city_ibge_code_valid check (city_ibge_code ~ '^[0-9]{7}$'),
  constraint schools_state_code_valid check (state_code ~ '^[A-Z]{2}$'),
  constraint schools_coordinates_pair check ((latitude is null) = (longitude is null)),
  constraint schools_latitude_valid check (latitude is null or latitude between -90 and 90),
  constraint schools_longitude_valid check (longitude is null or longitude between -180 and 180),
  constraint schools_status_valid check (status in ('active', 'inactive')),
  constraint schools_provider_external_id_key unique (provider, external_id)
);

create table public.fleet_service_cities (
  fleet_id uuid not null references public.fleets(id) on delete restrict,
  city_ibge_code text not null,
  city_name text not null,
  state_code text not null,
  created_by uuid not null references public.profiles(id) on delete restrict,
  created_at timestamptz not null default now(),
  constraint fleet_service_cities_pkey primary key (fleet_id, city_ibge_code),
  constraint fleet_service_cities_city_code_valid check (city_ibge_code ~ '^[0-9]{7}$'),
  constraint fleet_service_cities_name_not_blank check (btrim(city_name) <> ''),
  constraint fleet_service_cities_state_code_valid check (state_code ~ '^[A-Z]{2}$')
);

create table public.fleet_service_schools (
  fleet_id uuid not null references public.fleets(id) on delete restrict,
  school_id uuid not null references public.schools(id) on delete restrict,
  created_by uuid not null references public.profiles(id) on delete restrict,
  created_at timestamptz not null default now(),
  constraint fleet_service_schools_pkey primary key (fleet_id, school_id)
);

create table public.students (
  id uuid primary key default extensions.gen_random_uuid(),
  student_type text not null,
  profile_id uuid references public.profiles(id) on delete restrict,
  full_name text not null,
  birth_date date not null,
  postal_code text not null,
  street text not null,
  street_number text not null,
  address_complement text,
  neighborhood text not null,
  city_name text not null,
  city_ibge_code text not null,
  state_code text not null,
  latitude numeric,
  longitude numeric,
  created_by uuid not null references public.profiles(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint students_type_valid check (student_type in ('minor', 'adult')),
  constraint students_profile_type_valid check (
    (student_type = 'minor' and profile_id is null)
    or (student_type = 'adult' and profile_id is not null)
  ),
  constraint students_full_name_not_blank check (btrim(full_name) <> ''),
  constraint students_postal_code_not_blank check (btrim(postal_code) <> ''),
  constraint students_street_not_blank check (btrim(street) <> ''),
  constraint students_street_number_not_blank check (btrim(street_number) <> ''),
  constraint students_address_complement_not_blank check (address_complement is null or btrim(address_complement) <> ''),
  constraint students_neighborhood_not_blank check (btrim(neighborhood) <> ''),
  constraint students_city_name_not_blank check (btrim(city_name) <> ''),
  constraint students_city_ibge_code_valid check (city_ibge_code ~ '^[0-9]{7}$'),
  constraint students_state_code_valid check (state_code ~ '^[A-Z]{2}$'),
  constraint students_coordinates_pair check ((latitude is null) = (longitude is null)),
  constraint students_latitude_valid check (latitude is null or latitude between -90 and 90),
  constraint students_longitude_valid check (longitude is null or longitude between -180 and 180)
);

create table public.student_guardians (
  student_id uuid not null references public.students(id) on delete restrict,
  guardian_user_id uuid not null references public.profiles(id) on delete restrict,
  is_primary boolean not null default false,
  status text not null default 'active',
  joined_at timestamptz not null default now(),
  removed_at timestamptz,
  constraint student_guardians_pkey primary key (student_id, guardian_user_id),
  constraint student_guardians_status_valid check (status in ('active', 'removed')),
  constraint student_guardians_dates_valid check (
    (status = 'active' and removed_at is null)
    or (status = 'removed' and removed_at is not null)
  )
);

create table public.fleet_invitations (
  id uuid primary key default extensions.gen_random_uuid(),
  fleet_id uuid not null references public.fleets(id) on delete restrict,
  email text not null,
  token_hash bytea not null,
  role text not null,
  status text not null default 'pending',
  created_by uuid not null references public.profiles(id) on delete restrict,
  expires_at timestamptz not null,
  responded_by uuid references public.profiles(id) on delete set null,
  responded_at timestamptz,
  created_at timestamptz not null default now(),
  constraint fleet_invitations_email_not_blank check (btrim(email) <> ''),
  constraint fleet_invitations_token_hash_unique unique (token_hash),
  constraint fleet_invitations_role_valid check (role in ('guardian', 'student')),
  constraint fleet_invitations_status_valid check (status in ('pending', 'accepted', 'declined', 'cancelled', 'expired')),
  constraint fleet_invitations_response_dates_valid check (
    (status = 'pending' and responded_at is null)
    or (status <> 'pending' and responded_at is not null)
  )
);

create table public.fleet_join_requests (
  id uuid primary key default extensions.gen_random_uuid(),
  fleet_id uuid not null references public.fleets(id) on delete restrict,
  requester_user_id uuid not null references public.profiles(id) on delete restrict,
  student_id uuid not null references public.students(id) on delete restrict,
  school_id uuid not null references public.schools(id) on delete restrict,
  origin text not null,
  fleet_invitation_id uuid references public.fleet_invitations(id) on delete restrict,
  shift text not null,
  directions text[] not null,
  weekdays smallint[] not null,
  postal_code text not null,
  street text not null,
  street_number text not null,
  address_complement text,
  neighborhood text not null,
  city_name text not null,
  city_ibge_code text not null,
  state_code text not null,
  latitude numeric,
  longitude numeric,
  status text not null default 'pending',
  decided_by uuid references public.profiles(id) on delete set null,
  decided_at timestamptz,
  created_at timestamptz not null default now(),
  constraint fleet_join_requests_origin_valid check (origin in ('marketplace', 'invitation')),
  constraint fleet_join_requests_origin_invitation_valid check (
    (origin = 'marketplace' and fleet_invitation_id is null)
    or (origin = 'invitation' and fleet_invitation_id is not null)
  ),
  constraint fleet_join_requests_shift_valid check (shift in ('morning', 'afternoon', 'evening', 'full_time')),
  constraint fleet_join_requests_directions_valid check (
    cardinality(directions) between 1 and 2
    and directions <@ array['going', 'return']::text[]
    and (cardinality(directions) < 2 or directions[1] <> directions[2])
  ),
  constraint fleet_join_requests_weekdays_valid check (
    cardinality(weekdays) between 1 and 7
    and weekdays <@ array[1, 2, 3, 4, 5, 6, 7]::smallint[]
  ),
  constraint fleet_join_requests_status_valid check (status in ('pending', 'approved', 'rejected', 'cancelled')),
  constraint fleet_join_requests_city_code_valid check (city_ibge_code ~ '^[0-9]{7}$'),
  constraint fleet_join_requests_state_code_valid check (state_code ~ '^[A-Z]{2}$'),
  constraint fleet_join_requests_coordinates_pair check ((latitude is null) = (longitude is null)),
  constraint fleet_join_requests_latitude_valid check (latitude is null or latitude between -90 and 90),
  constraint fleet_join_requests_longitude_valid check (longitude is null or longitude between -180 and 180),
  constraint fleet_join_requests_decision_dates_valid check (
    (status = 'pending' and decided_at is null)
    or (status <> 'pending' and decided_at is not null)
  )
);

create table public.fleet_enrollments (
  id uuid primary key default extensions.gen_random_uuid(),
  fleet_id uuid not null references public.fleets(id) on delete restrict,
  student_id uuid not null references public.students(id) on delete restrict,
  source_request_id uuid not null references public.fleet_join_requests(id) on delete restrict,
  status text not null default 'active',
  started_at timestamptz not null default now(),
  ended_at timestamptz,
  ended_by uuid references public.profiles(id) on delete set null,
  end_reason text,
  constraint fleet_enrollments_source_request_unique unique (source_request_id),
  constraint fleet_enrollments_status_valid check (status in ('active', 'ended')),
  constraint fleet_enrollments_end_reason_valid check (end_reason is null or (btrim(end_reason) <> '' and char_length(end_reason) <= 500)),
  constraint fleet_enrollments_end_dates_valid check (
    (status = 'active' and ended_at is null and ended_by is null and end_reason is null)
    or (status = 'ended' and ended_at is not null and ended_by is not null and end_reason is not null)
  )
);

create table public.student_guardian_invitations (
  id uuid primary key default extensions.gen_random_uuid(),
  student_id uuid not null references public.students(id) on delete restrict,
  email text not null,
  token_hash bytea not null,
  invited_by uuid not null references public.profiles(id) on delete restrict,
  status text not null default 'pending',
  expires_at timestamptz not null,
  responded_by uuid references public.profiles(id) on delete set null,
  responded_at timestamptz,
  created_at timestamptz not null default now(),
  constraint student_guardian_invitations_email_not_blank check (btrim(email) <> ''),
  constraint student_guardian_invitations_token_hash_unique unique (token_hash),
  constraint student_guardian_invitations_status_valid check (status in ('pending', 'accepted', 'declined', 'cancelled', 'expired')),
  constraint student_guardian_invitations_response_dates_valid check (
    (status = 'pending' and responded_at is null)
    or (status <> 'pending' and responded_at is not null)
  )
);

create table public.fleet_membership_role_sources (
  id uuid primary key default extensions.gen_random_uuid(),
  membership_id uuid not null references public.fleet_memberships(id) on delete cascade,
  role text not null,
  source_type text not null,
  enrollment_id uuid references public.fleet_enrollments(id) on delete cascade,
  created_at timestamptz not null default now(),
  constraint fleet_membership_role_sources_role_valid check (role in ('owner', 'driver', 'guardian', 'student')),
  constraint fleet_membership_role_sources_source_valid check (
    (source_type = 'manual' and enrollment_id is null)
    or (source_type = 'enrollment' and role in ('guardian', 'student') and enrollment_id is not null)
  )
);

create unique index students_adult_profile_id_key
on public.students (profile_id)
where student_type = 'adult';

create unique index student_guardians_one_primary_key
on public.student_guardians (student_id)
where is_primary and status = 'active';

create unique index student_guardian_invitations_pending_email_key
on public.student_guardian_invitations (student_id, lower(email))
where status = 'pending';

create unique index fleet_invitations_pending_email_key
on public.fleet_invitations (fleet_id, lower(email), role)
where status = 'pending';

create unique index fleet_join_requests_pending_student_fleet_key
on public.fleet_join_requests (fleet_id, student_id)
where status = 'pending';

create unique index fleet_enrollments_active_student_fleet_key
on public.fleet_enrollments (fleet_id, student_id)
where status = 'active';

create unique index fleet_membership_role_sources_manual_key
on public.fleet_membership_role_sources (membership_id, role)
where source_type = 'manual';

create unique index fleet_membership_role_sources_enrollment_key
on public.fleet_membership_role_sources (membership_id, role, enrollment_id)
where source_type = 'enrollment';

create index fleet_service_cities_created_by_idx on public.fleet_service_cities (created_by);
create index fleet_service_schools_school_id_idx on public.fleet_service_schools (school_id);
create index fleet_service_schools_created_by_idx on public.fleet_service_schools (created_by);
create index students_created_by_idx on public.students (created_by);
create index students_city_idx on public.students (city_ibge_code);
create index student_guardians_guardian_idx on public.student_guardians (guardian_user_id, status);
create index student_guardian_invitations_token_hash_idx on public.student_guardian_invitations (token_hash);
create index fleet_invitations_token_hash_idx on public.fleet_invitations (token_hash);
create index fleet_join_requests_fleet_status_idx on public.fleet_join_requests (fleet_id, status, created_at desc);
create index fleet_join_requests_student_idx on public.fleet_join_requests (student_id, status);
create index fleet_enrollments_fleet_status_idx on public.fleet_enrollments (fleet_id, status);
create index fleet_enrollments_student_idx on public.fleet_enrollments (student_id, status);
create index fleet_membership_role_sources_membership_idx on public.fleet_membership_role_sources (membership_id);
create index fleet_membership_role_sources_enrollment_id_idx on public.fleet_membership_role_sources (enrollment_id);
create index schools_active_city_idx on public.schools (status, city_ibge_code, institution_type);

alter table public.audit_events drop constraint audit_events_action_valid;
alter table public.audit_events add constraint audit_events_action_valid check (
  action in (
    'fleet_created',
    'fleet_updated',
    'member_roles_changed',
    'membership_status_changed',
    'service_city_added',
    'service_city_removed',
    'service_school_added',
    'service_school_removed',
    'student_updated',
    'secondary_guardian_added',
    'secondary_guardian_removed',
    'join_request_created',
    'join_request_cancelled',
    'join_request_approved',
    'join_request_rejected',
    'fleet_invitation_created',
    'fleet_invitation_accepted',
    'fleet_invitation_declined',
    'fleet_invitation_cancelled',
    'enrollment_ended'
  )
);

alter table public.audit_events drop constraint audit_events_entity_type_valid;
alter table public.audit_events add constraint audit_events_entity_type_valid check (
  entity_type in (
    'fleet',
    'fleet_membership',
    'service_city',
    'service_school',
    'student',
    'student_guardian',
    'join_request',
    'fleet_invitation',
    'enrollment'
  )
);
