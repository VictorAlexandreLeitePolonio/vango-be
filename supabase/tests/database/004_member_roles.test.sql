begin;

create extension if not exists pgtap with schema extensions;
\ir ../_helpers.psql

select plan(7);
select pg_temp.seed_foundation();

select set_config(
  'request.jwt.claims',
  '{"sub":"40000000-0000-0000-0000-000000000001","role":"authenticated"}',
  true
);
set local role authenticated;

select lives_ok(
  $$select public.set_fleet_member_roles(
    '42000000-0000-0000-0000-000000000003',
    array['guardian', 'driver']::text[]
  )$$,
  'owner replaces roles of an existing membership'
);

select results_eq(
  $$select role from public.fleet_membership_roles
    where membership_id = '42000000-0000-0000-0000-000000000003'
    order by role$$,
  $$values ('driver'::text), ('guardian'::text)$$,
  'roles are persisted without losing order-independent membership'
);

select throws_ok(
  $$select public.set_fleet_member_roles(
    '42000000-0000-0000-0000-000000000003',
    array['driver', 'driver']::text[]
  )$$,
  'PGRST', null, 'duplicate roles are rejected'
);

select throws_ok(
  $$select public.set_fleet_member_roles(
    '42000000-0000-0000-0000-000000000003',
    array[]::text[]
  )$$,
  'PGRST', null, 'empty roles are rejected'
);

reset role;
select set_config(
  'request.jwt.claims',
  '{"sub":"40000000-0000-0000-0000-000000000003","role":"authenticated"}',
  true
);
set local role authenticated;

select throws_ok(
  $$select public.set_fleet_member_roles(
    '42000000-0000-0000-0000-000000000004',
    array['student']::text[]
  )$$,
  'PGRST', null, 'non-owner cannot change roles'
);

reset role;
select set_config(
  'request.jwt.claims',
  '{"sub":"40000000-0000-0000-0000-000000000001","role":"authenticated"}',
  true
);
set local role authenticated;

select lives_ok(
  $$select public.set_fleet_member_roles(
    '42000000-0000-0000-0000-000000000002',
    array['driver']::text[]
  )$$,
  'one of two owners can lose owner role'
);

select throws_ok(
  $$select public.set_fleet_member_roles(
    '42000000-0000-0000-0000-000000000001',
    array['driver']::text[]
  )$$,
  'PGRST', null, 'last active owner cannot lose owner role'
);

select * from finish();
rollback;
