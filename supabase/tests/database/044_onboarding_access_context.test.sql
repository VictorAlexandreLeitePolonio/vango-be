begin;

create extension if not exists pgtap with schema extensions;
\ir ../_helpers.psql

select plan(12);

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
) values (
  '00000000-0000-0000-0000-000000000000',
  '90000000-0000-0000-0000-000000000001',
  'authenticated',
  'authenticated',
  'guardian-onboarding@example.test',
  extensions.crypt('local-test-password', extensions.gen_salt('bf')),
  now(),
  '{"provider":"email","providers":["email"]}'::jsonb,
  '{"full_name":"  Guardian Onboarding  ","onboarding_intent":"guardian"}'::jsonb,
  now(),
  now()
);

select is(
  (select full_name from public.profiles where id = '90000000-0000-0000-0000-000000000001'),
  'Guardian Onboarding',
  'registration metadata initializes the profile name'
);

select is(
  (select onboarding_intent from public.profiles where id = '90000000-0000-0000-0000-000000000001'),
  'guardian',
  'registration metadata stores the onboarding intent'
);

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
) values (
  '00000000-0000-0000-0000-000000000000',
  '90000000-0000-0000-0000-000000000002',
  'authenticated',
  'authenticated',
  'invalid-onboarding@example.test',
  extensions.crypt('local-test-password', extensions.gen_salt('bf')),
  now(),
  '{"provider":"email","providers":["email"]}'::jsonb,
  '{"onboarding_intent":"owner"}'::jsonb,
  now(),
  now()
);

select is(
  (select onboarding_intent from public.profiles where id = '90000000-0000-0000-0000-000000000002'),
  null,
  'unrecognized metadata never becomes an onboarding intent'
);

select throws_ok(
  $$update public.profiles
    set onboarding_intent = 'owner'
    where id = '90000000-0000-0000-0000-000000000001'$$,
  '23514',
  null,
  'profiles reject unsupported onboarding intents'
);

select set_config(
  'request.jwt.claims',
  '{"sub":"90000000-0000-0000-0000-000000000001","role":"authenticated"}',
  true
);
set local role authenticated;

select is(
  (select onboarding_intent from public.get_my_access_context()),
  'guardian',
  'access context returns the onboarding intent'
);

select is(
  (select account_roles from public.get_my_access_context()),
  array[]::text[],
  'intent alone grants no account role'
);

select public.create_minor_student(
  'Minor Onboarding',
  '2015-02-03',
  '18000000',
  'Test Street',
  '10',
  null,
  'Downtown',
  'Test City',
  '3550000',
  'SP',
  null,
  null
);

select is(
  (select account_roles from public.get_my_access_context()),
  array['guardian']::text[],
  'a primary guardian relationship grants the guardian account role'
);

select is(
  (select dependent_student_ids from public.get_my_access_context()),
  array[(select id from public.students where full_name = 'Minor Onboarding')]::uuid[],
  'access context returns only the guardian dependent'
);

reset role;
select pg_temp.seed_foundation();

select set_config(
  'request.jwt.claims',
  '{"sub":"40000000-0000-0000-0000-000000000003","role":"authenticated"}',
  true
);
set local role authenticated;

select is(
  (select account_roles from public.get_my_access_context()),
  array['driver']::text[],
  'fleet membership contributes its active role'
);

select is(
  (
    select roles
    from public.get_my_access_context(),
      lateral unnest(fleet_access) as access
      cross join lateral jsonb_to_record(access) as fleet(fleet_id uuid, roles text[])
    where fleet.fleet_id = '41000000-0000-0000-0000-000000000001'
  ),
  array['driver']::text[],
  'access context keeps roles scoped to their fleet'
);

reset role;
update public.fleet_memberships
set status = 'suspended', suspended_at = now()
where id = '42000000-0000-0000-0000-000000000003';

set local role authenticated;
select is(
  (select account_roles from public.get_my_access_context()),
  array[]::text[],
  'suspended fleet memberships grant no account role'
);

reset role;
select set_config('request.jwt.claims', '{}', true);
set local role anon;

select isnt(
  has_function_privilege('anon', 'public.get_my_access_context()', 'execute'),
  true,
  'anonymous users cannot execute the access context function'
);

select * from finish();

rollback;
