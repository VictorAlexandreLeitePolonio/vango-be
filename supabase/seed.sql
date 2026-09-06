begin;

insert into auth.users (
  instance_id,
  id,
  aud,
  role,
  email,
  encrypted_password,
  email_confirmed_at,
  raw_app_meta_data,
  raw_user_meta_data,
  created_at,
  updated_at
) values
  (
    '00000000-0000-0000-0000-000000000000',
    '50000000-0000-0000-0000-000000000001',
    'authenticated',
    'authenticated',
    'seed-owner@example.test',
    extensions.crypt('local-test-password', extensions.gen_salt('bf')),
    now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    '{}'::jsonb,
    now(),
    now()
  ),
  (
    '00000000-0000-0000-0000-000000000000',
    '50000000-0000-0000-0000-000000000002',
    'authenticated',
    'authenticated',
    'seed-driver@example.test',
    extensions.crypt('local-test-password', extensions.gen_salt('bf')),
    now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    '{}'::jsonb,
    now(),
    now()
  ),
  (
    '00000000-0000-0000-0000-000000000000',
    '50000000-0000-0000-0000-000000000003',
    'authenticated',
    'authenticated',
    'seed-guardian@example.test',
    extensions.crypt('local-test-password', extensions.gen_salt('bf')),
    now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    '{}'::jsonb,
    now(),
    now()
  ),
  (
    '00000000-0000-0000-0000-000000000000',
    '50000000-0000-0000-0000-000000000004',
    'authenticated',
    'authenticated',
    'seed-owner-b@example.test',
    extensions.crypt('local-test-password', extensions.gen_salt('bf')),
    now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    '{}'::jsonb,
    now(),
    now()
  ),
  (
    '00000000-0000-0000-0000-000000000000',
    '50000000-0000-0000-0000-000000000005',
    'authenticated',
    'authenticated',
    'seed-student@example.test',
    extensions.crypt('local-test-password', extensions.gen_salt('bf')),
    now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    '{}'::jsonb,
    now(),
    now()
  )
on conflict (id) do nothing;

update public.profiles
set full_name = seed_profile.full_name
from (
  values
    ('50000000-0000-0000-0000-000000000001'::uuid, 'Seed Owner'),
    ('50000000-0000-0000-0000-000000000002'::uuid, 'Seed Driver'),
    ('50000000-0000-0000-0000-000000000003'::uuid, 'Seed Guardian'),
    ('50000000-0000-0000-0000-000000000004'::uuid, 'Seed Owner B'),
    ('50000000-0000-0000-0000-000000000005'::uuid, 'Seed Student')
) as seed_profile(id, full_name)
where profiles.id = seed_profile.id;

insert into public.fleets (id, name, slug, description, status, created_by)
values
  (
    '51000000-0000-0000-0000-000000000001',
    'Demo Fleet',
    'demo-fleet',
    'Frota fictícia para desenvolvimento local',
    'published',
    '50000000-0000-0000-0000-000000000001'
  ),
  (
    '51000000-0000-0000-0000-000000000002',
    'Backup Fleet',
    'backup-fleet',
    'Segunda frota fictícia para validar isolamento',
    'draft',
    '50000000-0000-0000-0000-000000000004'
  )
on conflict (id) do nothing;

insert into public.fleet_memberships (id, fleet_id, user_id)
values
  (
    '52000000-0000-0000-0000-000000000001',
    '51000000-0000-0000-0000-000000000001',
    '50000000-0000-0000-0000-000000000001'
  ),
  (
    '52000000-0000-0000-0000-000000000002',
    '51000000-0000-0000-0000-000000000001',
    '50000000-0000-0000-0000-000000000002'
  ),
  (
    '52000000-0000-0000-0000-000000000003',
    '51000000-0000-0000-0000-000000000001',
    '50000000-0000-0000-0000-000000000003'
  ),
  (
    '52000000-0000-0000-0000-000000000004',
    '51000000-0000-0000-0000-000000000001',
    '50000000-0000-0000-0000-000000000005'
  ),
  (
    '52000000-0000-0000-0000-000000000005',
    '51000000-0000-0000-0000-000000000002',
    '50000000-0000-0000-0000-000000000004'
  )
on conflict (id) do nothing;

insert into public.fleet_membership_roles (membership_id, role)
values
  ('52000000-0000-0000-0000-000000000001', 'owner'),
  ('52000000-0000-0000-0000-000000000002', 'driver'),
  ('52000000-0000-0000-0000-000000000002', 'guardian'),
  ('52000000-0000-0000-0000-000000000003', 'guardian'),
  ('52000000-0000-0000-0000-000000000004', 'student'),
  ('52000000-0000-0000-0000-000000000005', 'owner')
on conflict (membership_id, role) do nothing;

insert into public.audit_events (
  id,
  fleet_id,
  actor_user_id,
  action,
  entity_type,
  entity_id,
  metadata
)
values
  (
    '53000000-0000-0000-0000-000000000001',
    '51000000-0000-0000-0000-000000000001',
    '50000000-0000-0000-0000-000000000001',
    'fleet_created',
    'fleet',
    '51000000-0000-0000-0000-000000000001',
    '{}'::jsonb
  ),
  (
    '53000000-0000-0000-0000-000000000002',
    '51000000-0000-0000-0000-000000000002',
    '50000000-0000-0000-0000-000000000004',
    'fleet_created',
    'fleet',
    '51000000-0000-0000-0000-000000000002',
    '{}'::jsonb
  )
on conflict (id) do nothing;

commit;
