begin;

create extension if not exists pgtap with schema extensions;
\ir ../_helpers.psql

select plan(7);

select pg_temp.create_test_user('30000000-0000-0000-0000-000000000001', 'confirmed@example.test', true);
select pg_temp.create_test_user('30000000-0000-0000-0000-000000000002', 'unconfirmed@example.test', false);

select set_config(
  'request.jwt.claims',
  '{"sub":"30000000-0000-0000-0000-000000000001","role":"authenticated"}',
  true
);
set local role authenticated;

select lives_ok(
  $$select public.create_fleet('Fleet One', 'fleet-one', null, null, 'draft')$$,
  'confirmed user creates a fleet'
);

select is((select count(*)::integer from public.fleets), 1, 'one fleet is created');
select is((select count(*)::integer from public.fleet_memberships), 1, 'one membership is created');
select is((select count(*)::integer from public.fleet_membership_roles where role = 'owner'), 1, 'first owner role is created');
select is((select count(*)::integer from public.audit_events where action = 'fleet_created'), 1, 'creation is audited');

reset role;
select set_config(
  'request.jwt.claims',
  '{"sub":"30000000-0000-0000-0000-000000000002","role":"authenticated"}',
  true
);
set local role authenticated;

select throws_ok(
  $$select public.create_fleet('Blocked', 'blocked', null, null, 'draft')$$,
  'PGRST',
  null,
  'unconfirmed email is rejected'
);

reset role;
set local role anon;
select throws_ok(
  $$select public.create_fleet('Anonymous', 'anonymous', null, null, 'draft')$$,
  '42501',
  null,
  'anonymous cannot execute create_fleet'
);

select * from finish();

rollback;
