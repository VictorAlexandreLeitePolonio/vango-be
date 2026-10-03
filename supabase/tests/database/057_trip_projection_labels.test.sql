begin;

create extension if not exists pgtap with schema extensions;
\ir ../_helpers.psql
\ir ../_planning.psql
\ir ../_operations.psql

select plan(15);
select lives_ok($$select pg_temp.seed_cycle_4()$$, 'fixture generates operational trips');

-- A second driver of fleet A who is not assigned to the generated trips.
select pg_temp.create_test_user('40000000-0000-0000-0000-000000000007', 'driver-a2@example.test');
insert into public.fleet_memberships (id, fleet_id, user_id) values (
  '42000000-0000-0000-0000-000000000007',
  '41000000-0000-0000-0000-000000000001',
  '40000000-0000-0000-0000-000000000007'
);
insert into public.fleet_membership_roles (membership_id, role)
values ('42000000-0000-0000-0000-000000000007', 'driver');

create temp table expected_labels on commit drop as
select r.name as route_name, v.plate as van_plate, v.public_name as van_public_name,
       s.full_name as student_full_name, t.service_date
from public.trips t
join public.routes r on r.id = t.route_id
join public.vans v on v.id = t.van_id
join public.trip_passengers tp on tp.trip_id = t.id
join public.students s on s.id = tp.student_id
where t.id = (select id from operation_ids where kind = 'going');
grant select on expected_labels to authenticated;

-- Fleet owner receives the operational labels.
select set_config('request.jwt.claims',
  '{"sub":"40000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select is(public.get_trip((select id from operation_ids where kind = 'going'))->'trip'->>'route_name',
  (select route_name from expected_labels), 'owner receives the route name');
select is(public.get_trip((select id from operation_ids where kind = 'going'))->'trip'->>'van_plate',
  (select van_plate from expected_labels), 'owner receives the van plate');
select is(public.get_trip((select id from operation_ids where kind = 'going'))->'trip'->>'van_public_name',
  (select van_public_name from expected_labels), 'owner receives the van public name');
select is(public.get_trip((select id from operation_ids where kind = 'going'))->'passengers'->0->>'student_full_name',
  (select student_full_name from expected_labels), 'owner receives the passenger full name');
select is((public.list_service_day('41000000-0000-0000-0000-000000000001',
    (select service_date from expected_labels))->'trips'->0->'trip'->>'route_name'),
  (select route_name from expected_labels), 'service day list carries the same labels');

-- Assigned driver receives the operational labels.
select set_config('request.jwt.claims',
  '{"sub":"40000000-0000-0000-0000-000000000003","role":"authenticated"}', true);
select is(public.get_trip((select id from operation_ids where kind = 'going'))->'trip'->>'van_plate',
  (select van_plate from expected_labels), 'assigned driver receives the van plate');
select is(public.get_trip((select id from operation_ids where kind = 'going'))->'passengers'->0->>'student_full_name',
  (select student_full_name from expected_labels), 'assigned driver receives the passenger full name');

-- Unassigned driver of the same fleet cannot read the trip.
select set_config('request.jwt.claims',
  '{"sub":"40000000-0000-0000-0000-000000000007","role":"authenticated"}', true);
select throws_ok($$select public.get_trip((select id from operation_ids where kind = 'going'))$$,
  'PGRST', null, 'unassigned driver cannot read the trip');
select is(jsonb_array_length(public.list_service_day('41000000-0000-0000-0000-000000000001',
    (select service_date from expected_labels))->'trips'),
  0, 'unassigned driver does not list the trip');

-- Owner of another fleet cannot read or list the trip.
select set_config('request.jwt.claims',
  '{"sub":"40000000-0000-0000-0000-000000000005","role":"authenticated"}', true);
select throws_ok($$select public.get_trip((select id from operation_ids where kind = 'going'))$$,
  'PGRST', null, 'owner of another fleet cannot read the trip');
select is(jsonb_array_length(public.list_service_day('41000000-0000-0000-0000-000000000001',
    (select service_date from expected_labels))->'trips'),
  0, 'owner of another fleet does not list the trip');

-- Guardian projection stays unchanged: no labels and no passenger names.
select set_config('request.jwt.claims',
  '{"sub":"60000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select ok(not (public.get_trip((select id from operation_ids where kind = 'going'))->'trip' ? 'route_name'),
  'guardian does not receive the route name');
select ok(not (public.get_trip((select id from operation_ids where kind = 'going'))->'trip' ? 'van_plate'),
  'guardian does not receive the van plate');
select ok(not exists (
  select 1 from jsonb_array_elements(
    public.get_trip((select id from operation_ids where kind = 'going'))->'passengers'
  ) passenger where passenger ? 'student_full_name'
), 'guardian does not receive passenger names');

select * from finish();

rollback;
