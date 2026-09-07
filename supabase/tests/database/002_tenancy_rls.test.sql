begin;

create extension if not exists pgtap with schema extensions;
\ir ../_helpers.psql

select plan(8);

select pg_temp.create_test_user('20000000-0000-0000-0000-000000000001', 'owner-a@example.test');
select pg_temp.create_test_user('20000000-0000-0000-0000-000000000002', 'member-a@example.test');
select pg_temp.create_test_user('20000000-0000-0000-0000-000000000003', 'owner-b@example.test');

insert into public.fleets (id, name, slug, created_by)
values
  ('21000000-0000-0000-0000-000000000001', 'Fleet A', 'fleet-a', '20000000-0000-0000-0000-000000000001'),
  ('21000000-0000-0000-0000-000000000002', 'Fleet B', 'fleet-b', '20000000-0000-0000-0000-000000000003');

insert into public.fleet_memberships (id, fleet_id, user_id)
values
  ('22000000-0000-0000-0000-000000000001', '21000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001'),
  ('22000000-0000-0000-0000-000000000002', '21000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000002'),
  ('22000000-0000-0000-0000-000000000003', '21000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000003');

insert into public.fleet_membership_roles (membership_id, role)
values
  ('22000000-0000-0000-0000-000000000001', 'owner'),
  ('22000000-0000-0000-0000-000000000002', 'driver'),
  ('22000000-0000-0000-0000-000000000002', 'guardian'),
  ('22000000-0000-0000-0000-000000000003', 'owner');

select set_config(
  'request.jwt.claims',
  '{"sub":"20000000-0000-0000-0000-000000000002","role":"authenticated"}',
  true
);
set local role authenticated;

select is((select count(*)::integer from public.profiles), 1, 'member reads only own profile');
select is((select count(*)::integer from public.fleets), 1, 'member reads only own fleet');
select is((select count(*)::integer from public.fleet_memberships), 1, 'member reads only own membership');
select is((select count(*)::integer from public.fleet_membership_roles), 2, 'member reads own roles');

update public.profiles
set full_name = 'Member A'
where id = '20000000-0000-0000-0000-000000000002';

select is((select full_name from public.profiles), 'Member A', 'member updates own profile');

select throws_ok(
  $$insert into public.fleets (name, slug, created_by)
    values ('Blocked', 'blocked', '20000000-0000-0000-0000-000000000002')$$,
  '42501',
  null,
  'direct fleet insert is denied'
);

select is((select count(*)::integer from public.audit_events), 0, 'non-owner reads no audit events');

reset role;
select set_config('request.jwt.claims', '', true);
set local role anon;

select throws_ok(
  $$select count(*) from public.fleets$$,
  '42501',
  null,
  'anonymous cannot read fleets'
);

select * from finish();

rollback;
