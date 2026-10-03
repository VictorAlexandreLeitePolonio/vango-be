-- Regression suite for daily trip materialization over direct owner
-- allocations (issue #19): passenger materialization, idempotent repetition,
-- timezone targeting, generation snapshots, immutability of started trips,
-- tenant isolation, and private-function privileges.
begin;

create extension if not exists pgtap with schema extensions;
\ir ../_fleet_transport.psql

select no_plan();
select pg_temp.seed_fleet_transport();

-- Claims helpers: the RPCs authorize through request.jwt.claims.
create function pg_temp.as_user(p_sub uuid) returns void language sql as $$
  select set_config('request.jwt.claims',
    jsonb_build_object('sub', p_sub, 'role', 'authenticated')::text, true);
$$;
create function pg_temp.as_owner() returns void language sql as
  $$ select pg_temp.as_user('40000000-0000-0000-0000-000000000001') $$;
create function pg_temp.as_driver() returns void language sql as
  $$ select pg_temp.as_user('40000000-0000-0000-0000-000000000003') $$;
create function pg_temp.as_foreign_owner() returns void language sql as
  $$ select pg_temp.as_user('40000000-0000-0000-0000-000000000005') $$;

-- The local late-evening clock whose LOCAL tomorrow is the allocated Monday;
-- its UTC date already crossed midnight, so a UTC-based implementation would
-- materialize one day later.
create function pg_temp.owner_clock() returns timestamptz language sql as $$
  select (((select effective_on from transport_case) - 1) + time '23:30')
    at time zone 'America/Sao_Paulo'
$$;

create function pg_temp.trip_for(p_schedule uuid, p_date date) returns uuid
language sql as $$
  select t.id from public.trips t
  where t.fleet_id = '41000000-0000-0000-0000-000000000001'
    and t.schedule_id = p_schedule and t.service_date = p_date
$$;

-- The owner publishes the three explicit fixture pairs from the next Monday.
select pg_temp.as_owner();
select is(pg_temp.fleet_transport_error(format(
  'select * from public.assign_fleet_student_transport(%L,%L,%L::jsonb,%L::date,%L,%s)',
  enrollment_id, school_id, allocations, effective_on, command_a, initial_revision)),
  null::text, 'owner publishes the direct allocation') from transport_case;

-- Late-evening run_daily_operations: the local tomorrow is materialized.
select lives_ok(
  $$select private.run_daily_operations(pg_temp.owner_clock())$$,
  'late-evening orchestrator run materializes the local tomorrow');
select is((select count(*)::bigint from public.service_days), 1::bigint,
  'exactly one service day exists for the single timezone');
select is((select service_date from public.service_days),
  (select effective_on from transport_case),
  'the service day is the local tomorrow');
select is((select count(*)::bigint from public.trips), 2::bigint,
  'going and return executions are materialized');
select is((select count(*)::bigint from public.trips
  where service_date = (select effective_on + 1 from transport_case)), 0::bigint,
  'the UTC-shifted date is never materialized');

-- Passenger materialization from the direct allocation.
select is((select count(*)::bigint from public.trip_passengers p
  join public.trips t on t.id = p.trip_id and t.fleet_id = p.fleet_id
  where t.schedule_id = (select going_schedule_id from transport_case)
    and t.service_date = (select effective_on from transport_case)), 1::bigint,
  'the allocated student appears exactly once in the going execution');
select is((select student_id from public.trip_passengers p
  join public.trips t on t.id = p.trip_id and t.fleet_id = p.fleet_id
  where t.schedule_id = (select going_schedule_id from transport_case)
    and t.service_date = (select effective_on from transport_case)),
  (select student_id from transport_case),
  'the passenger is the fleet-managed minor');
select is((select count(*)::bigint from public.trip_passengers p
  join public.trips t on t.id = p.trip_id and t.fleet_id = p.fleet_id
  where t.schedule_id = (select return_schedule_id from transport_case)
    and t.service_date = (select effective_on from transport_case)), 0::bigint,
  'a student allocated to another weekday does not appear in this execution');
select is((select count(*)::bigint from public.trip_passengers
  where enrollment_id = (select adult_enrollment_id from transport_case)), 0::bigint,
  'a student without allocation never appears');

-- Repeated execution is idempotent across every touched table.
create temp table materialization_counts on commit drop as
select jsonb_build_object(
  'service_days', (select count(*) from public.service_days),
  'trips', (select count(*) from public.trips),
  'passengers', (select count(*) from public.trip_passengers),
  'stops', (select count(*) from public.trip_stops),
  'assignments', (select count(*) from public.trip_assignments)) as counts;
select lives_ok(
  $$select private.run_daily_operations(pg_temp.owner_clock())$$,
  'repeated run_daily_operations is safe');
select lives_ok($$select private.generate_trips(
  (select effective_on from transport_case), pg_temp.owner_clock())$$,
  'repeated direct generation is safe');
select is((select jsonb_build_object(
  'service_days', (select count(*) from public.service_days),
  'trips', (select count(*) from public.trips),
  'passengers', (select count(*) from public.trip_passengers),
  'stops', (select count(*) from public.trip_stops),
  'assignments', (select count(*) from public.trip_assignments))),
  (select counts from materialization_counts),
  'repeated execution changes no counts');

-- Timezone formulas: planned start and confirmation deadline.
select is((select count(*)::bigint from public.trips t
  join public.route_schedules rs on rs.id = t.schedule_id
  where t.planned_start_at is distinct from
      ((t.service_date + rs.starts_at) at time zone rs.timezone)
     or t.confirmation_deadline is distinct from
        t.planned_start_at - make_interval(mins => rs.confirmation_minutes)), 0::bigint,
  'planned start and deadline follow the schedule timezone and cutoff');

-- The Friday return execution carries the weekday-5 allocation.
select is(private.generate_trips(
  (select effective_on + 4 from transport_case), pg_temp.owner_clock()), 2,
  'the Friday date materializes both directional executions');
select is((select count(*)::bigint from public.trip_passengers p
  join public.trips t on t.id = p.trip_id and t.fleet_id = p.fleet_id
  where t.schedule_id = (select return_schedule_id from transport_case)
    and t.service_date = (select effective_on + 4 from transport_case)
    and p.enrollment_id = (select enrollment_id from transport_case)
    and p.removed_at is null), 1::bigint,
  'the student appears on its own allocated weekday');

-- Generation snapshots: resources, addresses and ordered stops.
select is((select jsonb_build_array(van_id, driver_user_id) from public.trips
  where id = pg_temp.trip_for((select going_schedule_id from transport_case),
    (select effective_on from transport_case))),
  jsonb_build_array((select id from planning_ids where kind = 'van'),
    (select driver_id from transport_case)),
  'the trip snapshots the route van and driver at generation time');
select is((select count(*)::bigint from public.trip_assignments a
  where a.trip_id = pg_temp.trip_for((select going_schedule_id from transport_case),
      (select effective_on from transport_case))
    and a.valid_until is null and a.reason = 'generated'
    and a.van_id = (select id from planning_ids where kind = 'van')
    and a.driver_user_id = (select driver_id from transport_case)), 1::bigint,
  'generation records the current assignment with reason generated');
select is((select jsonb_build_object(
    'postal_code', address_snapshot->>'postal_code',
    'street', address_snapshot->>'street',
    'street_number', address_snapshot->>'street_number',
    'neighborhood', address_snapshot->>'neighborhood',
    'city_name', address_snapshot->>'city_name',
    'city_ibge_code', address_snapshot->>'city_ibge_code',
    'state_code', address_snapshot->>'state_code')
  from public.trip_stops
  where trip_id = pg_temp.trip_for((select going_schedule_id from transport_case),
      (select effective_on from transport_case))
    and kind = 'home'),
  jsonb_build_object('postal_code', '18000000', 'street', 'Main Street',
    'street_number', '10', 'neighborhood', 'Center', 'city_name', 'Cidade Teste',
    'city_ibge_code', '3550000', 'state_code', 'SP'),
  'the home stop snapshots the registered student address');
select is((select count(*)::bigint from public.trip_stops
  where trip_id = pg_temp.trip_for((select going_schedule_id from transport_case),
      (select effective_on from transport_case))
    and kind = 'home' and latitude = -23.5::numeric
    and longitude = -46.6::numeric), 1::bigint,
  'the home stop carries the student coordinates');
select is((select jsonb_build_object('school_id', school_id, 'name', address_snapshot->>'name')
  from public.trip_stops
  where trip_id = pg_temp.trip_for((select going_schedule_id from transport_case),
      (select effective_on from transport_case))
    and kind = 'school'),
  jsonb_build_object('school_id', (select school_id from transport_case),
    'name', 'Escola Ciclo 3'),
  'the school stop snapshots the institution');
select is((select array_agg(position order by position) from public.trip_stops
  where trip_id = pg_temp.trip_for((select going_schedule_id from transport_case),
    (select effective_on from transport_case))),
  array[1, 1000, 100001, 200000]::integer[],
  'going ordering places homes before schools with fixed endpoints');
select is((select array_agg(position order by position) from public.trip_stops
  where trip_id = pg_temp.trip_for((select return_schedule_id from transport_case),
    (select effective_on + 4 from transport_case))),
  array[1, 1001, 100000, 200000]::integer[],
  'return ordering places schools before homes');

-- Started trips are immutable; the replacement only reaches later executions.
select is(private.close_confirmations(
  (select confirmation_deadline from public.trips
   where id = pg_temp.trip_for((select going_schedule_id from transport_case),
     (select effective_on from transport_case)))), 1,
  'confirmations close exactly at the deadline');
select is(public.override_trip_participation(
  pg_temp.trip_for((select going_schedule_id from transport_case),
    (select effective_on from transport_case)),
  (select student_id from transport_case), true,
  'owner confirms the fleet-managed minor after the cutoff',
  '76000000-0000-4000-8000-000000000009'), 'confirmed',
  'the owner override confirms the fleet-managed minor');
select pg_temp.as_driver();
select is(public.start_trip(
  pg_temp.trip_for((select going_schedule_id from transport_case),
    (select effective_on from transport_case)),
  '78000000-0000-4000-8000-000000000009'), 'active',
  'the assigned driver starts the materialized trip');
select pg_temp.as_owner();

create temp table active_trip_before on commit drop as
select
  (select jsonb_build_object('removed_at', p.removed_at, 'status', p.confirmation_status)
   from public.trip_passengers p
   where p.trip_id = pg_temp.trip_for((select going_schedule_id from transport_case),
       (select effective_on from transport_case))
     and p.enrollment_id = (select enrollment_id from transport_case)) as passenger,
  (select jsonb_agg(to_jsonb(s) order by s.position) from public.trip_stops s
   where s.trip_id = pg_temp.trip_for((select going_schedule_id from transport_case),
     (select effective_on from transport_case))) as stops,
  (select revision from public.trips
   where id = pg_temp.trip_for((select going_schedule_id from transport_case),
     (select effective_on from transport_case))) as revision;

select is(pg_temp.fleet_transport_error(format(
  'select * from public.assign_fleet_student_transport(%L,%L,%L::jsonb,%L::date,%L,%s)',
  enrollment_id, school_id,
  jsonb_build_array(jsonb_build_object('schedule_id', going_schedule_id,
    'weekday', 1, 'direction', 'going')),
  effective_on + 7, command_b, initial_revision + 1)),
  null::text, 'the replacement from a later date is accepted') from transport_case;
select is(private.generate_trips(
  (select effective_on + 7 from transport_case), pg_temp.owner_clock()), 2,
  'the replacement date materializes fresh executions');
select is((select jsonb_build_object('removed_at', p.removed_at, 'status', p.confirmation_status)
  from public.trip_passengers p
  where p.trip_id = pg_temp.trip_for((select going_schedule_id from transport_case),
      (select effective_on from transport_case))
    and p.enrollment_id = (select enrollment_id from transport_case)),
  (select passenger from active_trip_before),
  'the started trip keeps its passenger unchanged');
select is((select jsonb_agg(to_jsonb(s) order by s.position) from public.trip_stops s
  where s.trip_id = pg_temp.trip_for((select going_schedule_id from transport_case),
    (select effective_on from transport_case))),
  (select stops from active_trip_before),
  'the started trip keeps its stops unchanged');
select is((select revision from public.trips
  where id = pg_temp.trip_for((select going_schedule_id from transport_case),
    (select effective_on from transport_case))),
  (select revision from active_trip_before),
  'the started trip revision is untouched');
select is((select count(*)::bigint from public.trip_passengers
  where trip_id = pg_temp.trip_for((select going_schedule_id from transport_case),
      (select effective_on + 7 from transport_case))
    and enrollment_id = (select enrollment_id from transport_case)
    and removed_at is null), 1::bigint,
  'the not-started replacement execution receives the new allocation');

-- Tenant isolation: a second fleet never leaks into the first fleet trips.
insert into public.fleet_service_cities (fleet_id, city_ibge_code, city_name,
  state_code, created_by)
values ('41000000-0000-0000-0000-000000000002', '3550000', 'Cidade Teste', 'SP',
  '40000000-0000-0000-0000-000000000005');
insert into public.fleet_service_schools (fleet_id, school_id, created_by)
values ('41000000-0000-0000-0000-000000000002',
  (select school_id from transport_case), '40000000-0000-0000-0000-000000000005');

select pg_temp.as_foreign_owner();
select lives_ok($$select public.enable_owner_driving(
  '41000000-0000-0000-0000-000000000002', '96000000-0000-4000-8000-000000000021')$$,
  'the second fleet owner becomes its own driver');
create temp table fleet_b_ids (kind text primary key, id uuid) on commit drop;
-- Each step is its own statement so the next one can read the previous id.
insert into fleet_b_ids values
  ('fleet', '41000000-0000-0000-0000-000000000002'::uuid);
insert into fleet_b_ids values
  ('van', public.save_van('41000000-0000-0000-0000-000000000002', null,
    'CYC-5678', 'Micro', 'Van Frota B', 30));
insert into fleet_b_ids values
  ('route', public.save_route('41000000-0000-0000-0000-000000000002', null,
    jsonb_build_object('name', 'Frota B ida', 'direction', 'going', 'shift', 'morning',
      'van_id', (select id from fleet_b_ids where kind = 'van'),
      'driver_user_id', '40000000-0000-0000-0000-000000000005'::uuid,
      'origin', jsonb_build_object('latitude', -23.6, 'longitude', -46.7,
        'label', 'Base B'),
      'destination', jsonb_build_object('latitude', -23.5610, 'longitude', -46.6550,
        'label', 'Escola'),
      'schools', jsonb_build_array(jsonb_build_object('school_id',
        (select school_id from transport_case), 'position', 1)))));
insert into fleet_b_ids values
  ('schedule', public.save_route_schedule(
    (select id from fleet_b_ids where kind = 'route'), null,
    jsonb_build_object('weekdays', jsonb_build_array(1), 'starts_at', '08:00',
      'ends_at', '09:00', 'ends_next_day', false, 'timezone', 'America/Sao_Paulo',
      'valid_from', current_date + 1, 'valid_until', current_date + 90,
      'confirmation_minutes', 30)));
insert into fleet_b_ids values
  ('enrollment', (select enrollment_id from public.create_fleet_managed_student(
    '41000000-0000-0000-0000-000000000002', '96000000-0000-4000-8000-000000000022',
    'minor', 'Frota B Aluno', current_date - 3000, '18000000', 'B Street', '5',
    null, 'Center', 'Cidade Teste', '3550000', 'SP', -23.5, -46.6,
    (select school_id from transport_case), 'morning', 'Contact B',
    'contact-b@example.test', null)));
select lives_ok($$select public.assign_fleet_student_transport(
  (select id from fleet_b_ids where kind = 'enrollment'),
  (select school_id from transport_case),
  jsonb_build_array(jsonb_build_object('schedule_id',
    (select id from fleet_b_ids where kind = 'schedule'), 'weekday', 1,
    'direction', 'going')),
  (select effective_on from transport_case),
  '96000000-0000-4000-8000-000000000023', 1)$$,
  'the second fleet publishes its own allocation');
select is((select routing_revision from public.fleet_enrollments
  where id = (select id from fleet_b_ids where kind = 'enrollment')), 2::bigint,
  'the second fleet allocation advances its revision');
select is(private.generate_trips(
  (select effective_on from transport_case), pg_temp.owner_clock()), 1,
  'the second fleet materializes its own execution while the first stays idempotent');
select is((select count(*)::bigint from public.trip_passengers p
  join public.trips t on t.id = p.trip_id and t.fleet_id = p.fleet_id
  where t.schedule_id = (select id from fleet_b_ids where kind = 'schedule')), 1::bigint,
  'the second fleet execution carries exactly its own student');
select is((select count(*)::bigint from public.trip_passengers p
  where p.fleet_id = (select id from fleet_b_ids where kind = 'fleet')
    and p.enrollment_id <> (select id from fleet_b_ids where kind = 'enrollment')), 0::bigint,
  'no foreign enrollment rides a second fleet execution');
select is((select count(*)::bigint from public.trip_passengers p
  join public.trips t on t.id = p.trip_id and t.fleet_id = p.fleet_id
  where t.fleet_id = (select fleet_id from transport_case)
    and p.enrollment_id = (select id from fleet_b_ids where kind = 'enrollment')), 0::bigint,
  'the first fleet never carries the second fleet enrollment');
select is((select count(*)::bigint from public.trip_passengers p
  join public.trips t on t.id = p.trip_id and t.fleet_id = p.fleet_id
  where p.fleet_id <> t.fleet_id), 0::bigint,
  'every passenger row carries its trip fleet');
select is((select count(*)::bigint from public.trip_stops s
  join public.trips t on t.id = s.trip_id and t.fleet_id = s.fleet_id
  where s.fleet_id <> t.fleet_id), 0::bigint,
  'every stop row carries its trip fleet');

-- Private orchestrators are never executable by clients.
select ok(not has_function_privilege('authenticated',
  'private.generate_trips(date, timestamp with time zone)', 'EXECUTE'),
  'authenticated cannot execute private.generate_trips');
select ok(not has_function_privilege('anon',
  'private.generate_trips(date, timestamp with time zone)', 'EXECUTE'),
  'anon cannot execute private.generate_trips');
select ok(not has_function_privilege('authenticated',
  'private.run_daily_operations(timestamp with time zone)', 'EXECUTE'),
  'authenticated cannot execute private.run_daily_operations');
select ok(not has_function_privilege('anon',
  'private.run_daily_operations(timestamp with time zone)', 'EXECUTE'),
  'anon cannot execute private.run_daily_operations');

select * from finish();

rollback;
