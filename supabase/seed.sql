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
  ),
  (
    '00000000-0000-0000-0000-000000000000',
    '50000000-0000-0000-0000-000000000006',
    'authenticated',
    'authenticated',
    'carlos.motorista@vango.com.br',
    extensions.crypt('Senha@123', extensions.gen_salt('bf')),
    now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    '{"full_name":"Carlos Motorista"}'::jsonb,
    now(),
    now()
  )
on conflict (id) do nothing;

update auth.users
set confirmation_token = '',
    recovery_token = '',
    email_change_token_new = '',
    email_change = ''
where email like 'seed-%@example.test' or email = 'carlos.motorista@vango.com.br';

update public.profiles
set full_name = seed_profile.full_name
from (
  values
    ('50000000-0000-0000-0000-000000000001'::uuid, 'Seed Owner'),
    ('50000000-0000-0000-0000-000000000002'::uuid, 'Seed Driver'),
    ('50000000-0000-0000-0000-000000000003'::uuid, 'Seed Guardian'),
    ('50000000-0000-0000-0000-000000000004'::uuid, 'Seed Owner B'),
    ('50000000-0000-0000-0000-000000000005'::uuid, 'Seed Student'),
    ('50000000-0000-0000-0000-000000000006'::uuid, 'Carlos Motorista')
) as seed_profile(id, full_name)
where profiles.id = seed_profile.id;

insert into public.fleets (id, name, slug, description, status, created_by)
values
  (
    '51000000-0000-0000-0000-000000000001',
    'Demo Fleet',
    'demo-fleet',
    'Mock fleet for local development',
    'published',
    '50000000-0000-0000-0000-000000000001'
  ),
  (
    '51000000-0000-0000-0000-000000000002',
    'Backup Fleet',
    'backup-fleet',
    'Second mock fleet to validate isolation',
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
  ),
  (
    '52000000-0000-0000-0000-000000000006',
    '51000000-0000-0000-0000-000000000001',
    '50000000-0000-0000-0000-000000000006'
  )
on conflict (id) do nothing;

insert into public.fleet_membership_roles (membership_id, role)
values
  ('52000000-0000-0000-0000-000000000001', 'owner'),
  ('52000000-0000-0000-0000-000000000002', 'driver'),
  ('52000000-0000-0000-0000-000000000002', 'guardian'),
  ('52000000-0000-0000-0000-000000000003', 'guardian'),
  ('52000000-0000-0000-0000-000000000004', 'student'),
  ('52000000-0000-0000-0000-000000000005', 'owner'),
  ('52000000-0000-0000-0000-000000000006', 'driver')
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
  );

insert into public.schools (
  id, provider, external_id, institution_type, name, postal_code, street,
  street_number, neighborhood, city_name, city_ibge_code, state_code,
  latitude, longitude, status
) values (
  '60000000-0000-0000-0000-000000000001', 'inep', '35000001', 'school',
  'Colégio Objetivo - Campus Paraíso', '04101-000', 'Rua Vergueiro', '1200',
  'Paraíso', 'São Paulo', '3550308', 'SP', -23.5745, -46.6405, 'active'
) on conflict (id) do nothing;

insert into public.fleet_service_cities (fleet_id, city_ibge_code, city_name, state_code, created_by)
values (
  '51000000-0000-0000-0000-000000000001', '3550308', 'São Paulo', 'SP',
  '50000000-0000-0000-0000-000000000001'
) on conflict (fleet_id, city_ibge_code) do nothing;

insert into public.fleet_service_schools (fleet_id, school_id, created_by)
values (
  '51000000-0000-0000-0000-000000000001', '60000000-0000-0000-0000-000000000001',
  '50000000-0000-0000-0000-000000000001'
) on conflict (fleet_id, school_id) do nothing;

insert into public.vans (id, fleet_id, plate, model, public_name, capacity, status)
values (
  '61000000-0000-0000-0000-000000000001', '51000000-0000-0000-0000-000000000001',
  'BRA2E19', 'Mercedes-Benz Sprinter 415', 'Van 01 - Zona Sul', 20, 'active'
) on conflict (id) do nothing;

commit;
