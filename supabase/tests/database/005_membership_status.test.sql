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
  $$select public.set_fleet_membership_status(
    '42000000-0000-0000-0000-000000000003', 'suspended'
  )$$,
  'owner suspends an existing member'
);

select ok(
  (select status = 'suspended' and suspended_at is not null and left_at is null
   from public.fleet_memberships
   where id = '42000000-0000-0000-0000-000000000003'),
  'suspension timestamps are coherent'
);

select lives_ok(
  $$select public.set_fleet_membership_status(
    '42000000-0000-0000-0000-000000000003', 'active'
  )$$,
  'owner reactivates a member'
);

select ok(
  (select status = 'active' and suspended_at is null and left_at is null
   from public.fleet_memberships
   where id = '42000000-0000-0000-0000-000000000003'),
  'reactivation clears status timestamps'
);

select lives_ok(
  $$select public.set_fleet_membership_status(
    '42000000-0000-0000-0000-000000000003', 'left'
  )$$,
  'owner marks a member as left'
);

reset role;
select set_config(
  'request.jwt.claims',
  '{"sub":"40000000-0000-0000-0000-000000000004","role":"authenticated"}',
  true
);
set local role authenticated;

select throws_ok(
  $$select public.set_fleet_membership_status(
    '42000000-0000-0000-0000-000000000003', 'active'
  )$$,
  'PGRST', null, 'non-owner cannot change membership status'
);

reset role;
select set_config(
  'request.jwt.claims',
  '{"sub":"40000000-0000-0000-0000-000000000001","role":"authenticated"}',
  true
);
set local role authenticated;

select public.set_fleet_membership_status(
  '42000000-0000-0000-0000-000000000002', 'suspended'
);

select throws_ok(
  $$select public.set_fleet_membership_status(
    '42000000-0000-0000-0000-000000000001', 'suspended'
  )$$,
  'PGRST', null, 'last active owner cannot be suspended'
);

select * from finish();
rollback;
