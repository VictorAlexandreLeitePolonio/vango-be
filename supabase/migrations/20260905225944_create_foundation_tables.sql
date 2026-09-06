create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text,
  phone text,
  avatar_path text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint profiles_full_name_not_blank
    check (full_name is null or btrim(full_name) <> '')
);

create table public.fleets (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  slug text not null,
  description text,
  logo_path text,
  status text not null default 'draft',
  created_by uuid not null references public.profiles(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint fleets_name_not_blank check (btrim(name) <> ''),
  constraint fleets_slug_format check (slug ~ '^[a-z0-9]+(?:-[a-z0-9]+)*$'),
  constraint fleets_slug_unique unique (slug),
  constraint fleets_status_valid check (status in ('draft', 'published', 'suspended', 'archived'))
);

create table public.fleet_memberships (
  id uuid primary key default gen_random_uuid(),
  fleet_id uuid not null references public.fleets(id) on delete restrict,
  user_id uuid not null references public.profiles(id) on delete restrict,
  status text not null default 'active',
  joined_at timestamptz not null default now(),
  suspended_at timestamptz,
  left_at timestamptz,
  constraint fleet_memberships_user_unique unique (fleet_id, user_id),
  constraint fleet_memberships_status_valid check (status in ('active', 'suspended', 'left')),
  constraint fleet_memberships_status_dates_valid check (
    (status = 'active' and suspended_at is null and left_at is null)
    or (status = 'suspended' and suspended_at is not null and left_at is null)
    or (status = 'left' and suspended_at is null and left_at is not null)
  )
);

create table public.fleet_membership_roles (
  membership_id uuid not null references public.fleet_memberships(id) on delete cascade,
  role text not null,
  constraint fleet_membership_roles_pkey primary key (membership_id, role),
  constraint fleet_membership_roles_role_valid check (role in ('owner', 'driver', 'guardian', 'student'))
);

create table public.audit_events (
  id uuid primary key default gen_random_uuid(),
  fleet_id uuid not null references public.fleets(id) on delete restrict,
  actor_user_id uuid references public.profiles(id) on delete set null,
  action text not null,
  entity_type text not null,
  entity_id uuid not null,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  constraint audit_events_action_valid check (
    action in (
      'fleet_created',
      'fleet_updated',
      'member_roles_changed',
      'membership_status_changed'
    )
  ),
  constraint audit_events_entity_type_valid check (
    entity_type in ('fleet', 'fleet_membership')
  ),
  constraint audit_events_metadata_object check (jsonb_typeof(metadata) = 'object')
);

create index fleet_memberships_user_id_idx on public.fleet_memberships(user_id);
create index fleet_memberships_fleet_id_status_idx on public.fleet_memberships(fleet_id, status);
create index fleet_membership_roles_role_idx on public.fleet_membership_roles(role, membership_id);
create index audit_events_fleet_id_created_at_idx on public.audit_events(fleet_id, created_at desc);
create index audit_events_actor_user_id_idx on public.audit_events(actor_user_id);
