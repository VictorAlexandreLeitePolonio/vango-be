begin;

create extension if not exists pgtap with schema extensions;
\ir ../_helpers.psql

select plan(9);

select has_table('public', 'profiles', 'profiles table exists');
select has_table('public', 'fleets', 'fleets table exists');
select has_table('public', 'fleet_memberships', 'fleet memberships table exists');
select has_table('public', 'fleet_membership_roles', 'membership roles table exists');
select has_table('public', 'audit_events', 'audit events table exists');

select pg_temp.create_test_user(
  '10000000-0000-0000-0000-000000000001',
  'profile-owner@example.test',
  false
);

select ok(
  exists (
    select 1
    from public.profiles
    where id = '10000000-0000-0000-0000-000000000001'
      and full_name is null
  ),
  'auth user receives a minimal profile'
);

select is(
  (
    select count(*)::integer
    from public.profiles
    where id = '10000000-0000-0000-0000-000000000001'
  ),
  1,
  'profile trigger creates exactly one row'
);

select throws_ok(
  $$update public.profiles set full_name = '   '
    where id = '10000000-0000-0000-0000-000000000001'$$,
  '23514',
  null,
  'blank full name is rejected'
);

select ok(
  (
    select created_at = updated_at
    from public.profiles
    where id = '10000000-0000-0000-0000-000000000001'
  ),
  'new profile starts with matching timestamps'
);

select * from finish();

rollback;
