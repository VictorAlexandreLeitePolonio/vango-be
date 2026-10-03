-- End-to-end MVP cycle (issue #23): an owner who also drives configures a
-- fleet from scratch through public RPCs, allocates a fleet-managed student,
-- lets the daily operations job materialize the service day, and runs the
-- trip to completion (start, boarding, live GPS, school arrival, drop-off,
-- finish). Every critical state is re-read through the client projections,
-- foreign tenants can neither read nor operate the trip, and rejected
-- commands leave no state behind.
begin;

create extension if not exists pgtap with schema extensions;
\ir ../_fleet_transport.psql

select no_plan();
-- Base world: users, fleets A/B, catalog city and the school (no fleet-B
-- planning data exists yet).
select pg_temp.seed_fleet_transport();

create function pg_temp.as_user(p_sub uuid) returns void language sql as $$
  select set_config('request.jwt.claims',
    jsonb_build_object('sub', p_sub, 'role', 'authenticated')::text, true);
$$;
-- Fleet B owner, who also drives its van.
create function pg_temp.as_owner_driver() returns void language sql as
  $$ select pg_temp.as_user('40000000-0000-0000-0000-000000000005') $$;
-- Fleet A owner: a foreign tenant for fleet B.
create function pg_temp.as_foreign_owner() returns void language sql as
  $$ select pg_temp.as_user('40000000-0000-0000-0000-000000000001') $$;
-- Fleet A driver: a foreign driver for fleet B.
create function pg_temp.as_foreign_driver() returns void language sql as
  $$ select pg_temp.as_user('40000000-0000-0000-0000-000000000003') $$;

create temp table e2e (kind text primary key, id uuid) on commit drop;
grant all on e2e to authenticated;
create function pg_temp.e2e(p_kind text) returns uuid language sql as
  $$ select id from e2e where kind = p_kind $$;
create function pg_temp.service_date() returns date language sql as
  $$ select effective_on from transport_case $$;
-- The evening before the service day, when the daily job runs.
create function pg_temp.job_clock() returns timestamptz language sql as $$
  select ((pg_temp.service_date() - 1) + time '20:00') at time zone 'America/Sao_Paulo'
$$;

-- 1-2. The owner enables driving and holds owner + driver in fleet B.
select pg_temp.as_owner_driver();
insert into e2e values ('fleet', '41000000-0000-0000-0000-000000000002');
select lives_ok($$select public.link_fleet_service_city(pg_temp.e2e('fleet'),
  '3550000', '9a000000-0000-4000-8000-000000000001')$$,
  'the owner covers the student city');
select lives_ok($$select public.link_fleet_service_school(pg_temp.e2e('fleet'),
  (select school_id from transport_case), '9a000000-0000-4000-8000-000000000002')$$,
  'the owner serves the school');
select lives_ok($$select public.enable_owner_driving(pg_temp.e2e('fleet'),
  '9a000000-0000-4000-8000-000000000003')$$,
  'the owner becomes a driver of the fleet');
select ok((select bool_or(
    (access->>'fleet_id')::uuid = pg_temp.e2e('fleet')
    and access->'roles' ? 'owner' and access->'roles' ? 'driver')
  from public.get_my_access_context() c, unnest(c.fleet_access) access),
  'the access context reports owner + driver for the fleet');

-- 3-4. Real van, route and weekly schedule.
insert into e2e values ('van', public.save_van(pg_temp.e2e('fleet'), null,
  'VAN2E26', 'Sprinter', 'Van E2E', 15));
insert into e2e values ('route', public.save_route(pg_temp.e2e('fleet'), null,
  jsonb_build_object('name', 'E2E ida', 'direction', 'going', 'shift', 'morning',
    'van_id', pg_temp.e2e('van'),
    'driver_user_id', '40000000-0000-0000-0000-000000000005'::uuid,
    'origin', jsonb_build_object('latitude', -23.6, 'longitude', -46.7, 'label', 'Garagem'),
    'destination', jsonb_build_object('latitude', -23.56, 'longitude', -46.655,
      'label', 'Garagem'),
    'schools', jsonb_build_array(jsonb_build_object('school_id',
      (select school_id from transport_case), 'position', 1)))));
insert into e2e values ('schedule', public.save_route_schedule(pg_temp.e2e('route'), null,
  jsonb_build_object('weekdays', jsonb_build_array(1), 'starts_at', '07:00',
    'ends_at', '08:00', 'ends_next_day', false, 'timezone', 'America/Sao_Paulo',
    'valid_from', current_date + 1, 'valid_until', current_date + 90,
    'confirmation_minutes', 30)));
select ok((select count(*) = 3 from e2e where kind in ('van', 'route', 'schedule')
  and id is not null), 'van, route and schedule are persisted');

-- 5-6. A fleet-managed student, allocated without any marketplace request.
insert into e2e select 'student', student_id from public.create_fleet_managed_student(
  pg_temp.e2e('fleet'), '9a000000-0000-4000-8000-000000000004', 'minor',
  'Aluno E2E', current_date - 3000, '18000000', 'Rua E2E', '42', null, 'Centro',
  'Cidade Teste', '3550000', 'SP', -23.55, -46.63,
  (select school_id from transport_case), 'morning', 'Contato E2E',
  'contato-e2e@example.test', null);
insert into e2e select 'enrollment', e.id from public.fleet_enrollments e
  where e.student_id = pg_temp.e2e('student');
select lives_ok($$select public.assign_fleet_student_transport(
  pg_temp.e2e('enrollment'), (select school_id from transport_case),
  jsonb_build_array(jsonb_build_object('schedule_id', pg_temp.e2e('schedule'),
    'weekday', 1, 'direction', 'going')),
  pg_temp.service_date(), '9a000000-0000-4000-8000-000000000005', 1)$$,
  'the owner allocates the student to the route');
select is((select count(*)::bigint from public.fleet_join_requests
  where student_id = pg_temp.e2e('student')), 0::bigint,
  'no marketplace request was created');

-- 7. The daily operations job materializes the service day.
reset role;
select lives_ok($$select private.run_daily_operations(pg_temp.job_clock())$$,
  'the daily operations job runs for the service day');
insert into e2e select 'trip', t.id from public.trips t
  where t.schedule_id = pg_temp.e2e('schedule') and t.service_date = pg_temp.service_date();

-- 8. The persisted trip and manifest are visible to the owner-driver.
select pg_temp.as_owner_driver();
select ok((select bool_or((item->'trip'->>'id')::uuid = pg_temp.e2e('trip'))
  from jsonb_array_elements(public.list_service_day(pg_temp.e2e('fleet'),
    pg_temp.service_date())->'trips') item),
  'list_service_day returns the materialized trip');
select is((public.get_trip(pg_temp.e2e('trip'))->'trip'->>'van_plate'), 'VAN2E26',
  'get_trip carries the real van plate');
select is((select jsonb_build_object('student', p->>'student_id',
    'name', p->>'student_full_name', 'confirmation', p->>'confirmation_status',
    'operation', p->>'operation_status')
  from jsonb_array_elements(public.get_trip(pg_temp.e2e('trip'))->'passengers') p),
  jsonb_build_object('student', pg_temp.e2e('student')::text, 'name', 'Aluno E2E',
    'confirmation', 'confirmed', 'operation', 'waiting'),
  'the manifest holds the auto-confirmed fleet-managed student');
select is((select array_agg(s->>'kind' order by (s->>'position')::int)
  from jsonb_array_elements(public.get_trip(pg_temp.e2e('trip'))->'stops') s),
  array['origin', 'home', 'school', 'destination'],
  'the going stops are ordered origin, home, school, destination');

-- 16. Foreign tenants can neither read nor operate the trip.
select pg_temp.as_foreign_owner();
select is(pg_temp.fleet_transport_error(format(
  'select public.get_trip(%L)', pg_temp.e2e('trip'))), 'not_found',
  'a foreign owner cannot read the trip');
select is(pg_temp.fleet_transport_error(format(
  'select public.start_trip(%L, %L)', pg_temp.e2e('trip'),
  '9a000000-0000-4000-8000-000000000010')), 'not_found',
  'a foreign owner cannot start the trip');
select pg_temp.as_foreign_driver();
select is(pg_temp.fleet_transport_error(format(
  'select public.record_passenger_event(%L, %L, %L, %L)', pg_temp.e2e('trip'),
  pg_temp.e2e('student'), 'boarded', '9a000000-0000-4000-8000-000000000011')),
  'not_found', 'a foreign driver cannot record passenger events');

-- 17. A rejected start (confirmation window open) changes nothing.
select pg_temp.as_owner_driver();
select is(pg_temp.fleet_transport_error(format(
  'select public.start_trip(%L, %L)', pg_temp.e2e('trip'),
  '9a000000-0000-4000-8000-000000000012')), 'confirmation_closed',
  'starting before the confirmation deadline is rejected');
select is(public.get_trip(pg_temp.e2e('trip'))->'trip'->>'status', 'scheduled',
  'the rejected start leaves the trip scheduled');

-- The job closes confirmations at the deadline.
reset role;
select is(private.close_confirmations(
  (select confirmation_deadline from public.trips where id = pg_temp.e2e('trip'))), 1,
  'confirmations close at the deadline');

-- 10. Start, then re-read: the trip stays active.
select pg_temp.as_owner_driver();
select is(public.start_trip(pg_temp.e2e('trip'), '9a000000-0000-4000-8000-000000000013'),
  'active', 'the owner-driver starts the trip');
select is(public.start_trip(pg_temp.e2e('trip'), '9a000000-0000-4000-8000-000000000013'),
  'active', 'replaying the same start command is idempotent');
select is(public.get_trip(pg_temp.e2e('trip'))->'trip'->>'status', 'active',
  'a fresh read returns the active trip');
select ok(public.get_trip(pg_temp.e2e('trip'))->'trip'->>'started_at' is not null,
  'the projection exposes started_at for telemetry sequencing');

-- 11. Boarding.
select is(public.record_passenger_event(pg_temp.e2e('trip'), pg_temp.e2e('student'),
  'boarded', '9a000000-0000-4000-8000-000000000014'), 'boarded',
  'the student boards');

-- 17. Finishing with a student on board is rejected and changes nothing.
select is(pg_temp.fleet_transport_error(format(
  'select public.finish_trip(%L, false, null, %L)', pg_temp.e2e('trip'),
  '9a000000-0000-4000-8000-000000000015')), 'passengers_on_board',
  'finishing with a boarded student is rejected');
select is(public.get_trip(pg_temp.e2e('trip'))->'trip'->>'status', 'active',
  'the rejected finish keeps the trip active');

-- 12. Live GPS under the open assignment (the payload the Flutter uploader sends).
insert into e2e select 'assignment', a.id from public.trip_assignments a
  where a.trip_id = pg_temp.e2e('trip') and a.valid_until is null;
-- The job ran with a simulated clock on the eve of a future service day, so
-- the generated assignment starts after the real "now" used for live GPS.
-- In production the job runs on the real eve; align the window to the start.
reset role;
update public.trip_assignments a set valid_from = t.started_at
  from public.trips t
  where a.id = pg_temp.e2e('assignment') and t.id = a.trip_id;
select pg_temp.as_owner_driver();
select ok((public.ingest_trip_locations(pg_temp.e2e('trip'), pg_temp.e2e('assignment'),
  jsonb_build_array(jsonb_build_object(
    'sequence', greatest(1, floor(extract(epoch from clock_timestamp() - t.started_at)
      * 1000))::int,
    'captured_at', clock_timestamp(), 'latitude', -23.552, 'longitude', -46.632,
    'accuracy', 8, 'speed', 10, 'heading', 90)), true)) is not null,
  'a live GPS batch is accepted')
from public.trips t where t.id = pg_temp.e2e('trip');
select is((select count(*)::bigint from public.trip_current_locations
  where trip_id = pg_temp.e2e('trip')), 1::bigint,
  'the current van location is persisted');
select pg_temp.as_foreign_driver();
select is(pg_temp.fleet_transport_error(format(
  'select public.ingest_trip_locations(%L, %L, %L::jsonb, true)', pg_temp.e2e('trip'),
  pg_temp.e2e('assignment'), jsonb_build_array(jsonb_build_object('sequence', 999999,
    'captured_at', clock_timestamp(), 'latitude', -23.5, 'longitude', -46.6,
    'accuracy', 5)))), 'not_found',
  'a foreign driver cannot inject GPS into the trip');

-- 13. School arrival and drop-off.
select pg_temp.as_owner_driver();
select lives_ok(format('select public.mark_trip_stop_reached(%L, %L)',
  (select s.id from public.trip_stops s where s.trip_id = pg_temp.e2e('trip')
    and s.kind = 'school'), '9a000000-0000-4000-8000-000000000016'),
  'the school stop is marked reached');
select is(public.record_passenger_event(pg_temp.e2e('trip'), pg_temp.e2e('student'),
  'dropped_off', '9a000000-0000-4000-8000-000000000017'), 'dropped_off',
  'the student is dropped off');

-- 14-15. Finish, then re-read: the trip stays completed with its history.
select is(public.finish_trip(pg_temp.e2e('trip'), false, null,
  '9a000000-0000-4000-8000-000000000018'), 'completed', 'the trip is finished');
select is((select jsonb_build_object('status', t->>'status',
    'ended', t->>'ended_at' is not null)
  from (select public.get_trip(pg_temp.e2e('trip'))->'trip' t) x),
  jsonb_build_object('status', 'completed', 'ended', true),
  'a fresh read returns the completed trip');
select is((select p->>'operation_status'
  from jsonb_array_elements(public.get_trip(pg_temp.e2e('trip'))->'passengers') p),
  'dropped_off', 'the passenger history survives completion');
select is((select s->>'reached_at' is not null
  from jsonb_array_elements(public.get_trip(pg_temp.e2e('trip'))->'stops') s
  where s->>'kind' = 'school'), true, 'the school arrival survives completion');

-- Live GPS after completion is rejected (tracking must stop with the trip).
select is(pg_temp.fleet_transport_error(format(
  'select public.ingest_trip_locations(%L, %L, %L::jsonb, true)', pg_temp.e2e('trip'),
  pg_temp.e2e('assignment'), jsonb_build_array(jsonb_build_object('sequence', 999998,
    'captured_at', clock_timestamp(), 'latitude', -23.5, 'longitude', -46.6,
    'accuracy', 5)))), 'invalid_transition',
  'live GPS after completion is rejected');

-- Every row of the cycle stays inside its own tenant.
reset role;
select is((select count(*)::bigint from public.trip_passengers p
  join public.trips t on t.id = p.trip_id where p.fleet_id <> t.fleet_id)
  + (select count(*)::bigint from public.trip_stops s
  join public.trips t on t.id = s.trip_id where s.fleet_id <> t.fleet_id)
  + (select count(*)::bigint from public.trip_assignments a
  join public.trips t on t.id = a.trip_id where a.fleet_id <> t.fleet_id), 0::bigint,
  'passengers, stops and assignments carry their trip fleet');
select is((select fleet_id from public.trips where id = pg_temp.e2e('trip')),
  pg_temp.e2e('fleet'), 'the trip belongs to the configuring fleet');

select * from finish();

rollback;
