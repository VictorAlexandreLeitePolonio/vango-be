-- Fleet-managed students are confirmed by default (opt-out): they have no
-- profile or guardian account that can answer respond_trip, so without the
-- backend trigger they always expire at the deadline and can never board.
-- Guardian-created students keep the normal pending flow.
begin;

create extension if not exists pgtap with schema extensions;
\ir ../_helpers.psql
\ir ../_planning.psql
\ir ../_operations.psql

select no_plan();

create function pg_temp.as_user(p_sub uuid) returns void language sql as $$
  select set_config('request.jwt.claims',
    jsonb_build_object('sub', p_sub, 'role', 'authenticated')::text, true);
$$;

-- Captures the stable domain error code of a raising RPC call.
create function pg_temp.fleet_transport_error(p_sql text) returns text
language plpgsql as $$
begin
  execute p_sql;
  return null;
exception when sqlstate 'PGRST' then
  return sqlerrm::jsonb->>'code';
end;
$$;

-- The marketplace flow seeds the guardian-created minor, approves the join
-- request (all weekdays, both directions) and materializes the next weekday.
select pg_temp.seed_cycle_4();

-- Case 2: the guardian-created student keeps the normal pending flow.
select is((select confirmation_status from public.trip_passengers
  where trip_id = (select id from operation_ids where kind = 'going')
    and student_id = (select id from planning_ids where kind = 'minor')
    and removed_at is null), 'pending',
  'the guardian-created student stays pending after generation');

-- Two fleet-managed students (no profile, no guardian): one stays unguarded,
-- one receives an active guardian row that opts it out of auto-confirmation.
select pg_temp.as_user('40000000-0000-0000-0000-000000000001');
create temp table fleet_student_case on commit drop as
select student_id, enrollment_id,
  (select id from planning_ids where kind = 'school') as school_id,
  (select id from planning_ids where kind = 'going-schedule') as going_schedule_id,
  (select service_date from public.trips
    where id = (select id from operation_ids where kind = 'going')) as effective_on
from public.create_fleet_managed_student(
  '41000000-0000-0000-0000-000000000001', '91000000-0000-4000-8000-000000000016',
  'minor', 'Fleet Managed Unguarded', current_date - 3000, '18000000',
  'Main Street', '10', null, 'Center', 'Cidade Teste', '3550000', 'SP',
  -23.5, -46.6, (select id from planning_ids where kind = 'school'), 'morning',
  'Contact', 'contact@example.com', null);
create temp table guarded_student_case on commit drop as
select student_id, enrollment_id,
  (select id from planning_ids where kind = 'school') as school_id,
  (select id from planning_ids where kind = 'going-schedule') as going_schedule_id,
  (select service_date from public.trips
    where id = (select id from operation_ids where kind = 'going')) as effective_on
from public.create_fleet_managed_student(
  '41000000-0000-0000-0000-000000000001', '91000000-0000-4000-8000-000000000018',
  'minor', 'Fleet Managed Guarded', current_date - 3000, '18000000',
  'Main Street', '12', null, 'Center', 'Cidade Teste', '3550000', 'SP',
  -23.5, -46.6, (select id from planning_ids where kind = 'school'), 'morning',
  'Contact 3', 'contact3@example.com', null);
insert into public.student_guardians (student_id, guardian_user_id, is_primary, status)
values ((select student_id from guarded_student_case),
  '40000000-0000-0000-0000-000000000004', true, 'active');

select is(pg_temp.fleet_transport_error(format(
  'select * from public.assign_fleet_student_transport(%L,%L,%L::jsonb,%L::date,%L,%s)',
  enrollment_id, school_id,
  jsonb_build_array(
    jsonb_build_object('schedule_id', going_schedule_id, 'weekday', 1, 'direction', 'going'),
    jsonb_build_object('schedule_id', going_schedule_id, 'weekday', 3, 'direction', 'going')),
  effective_on, '92000000-0000-4000-8000-000000000016', 1)),
  null::text, 'the owner allocates the unguarded fleet student')
from fleet_student_case;
select is(pg_temp.fleet_transport_error(format(
  'select * from public.assign_fleet_student_transport(%L,%L,%L::jsonb,%L::date,%L,%s)',
  enrollment_id, school_id,
  jsonb_build_array(jsonb_build_object('schedule_id', going_schedule_id,
    'weekday', 3, 'direction', 'going')),
  effective_on, '92000000-0000-4000-8000-000000000018', 1)),
  null::text, 'the owner allocates the guardian-backed fleet student')
from guarded_student_case;

-- Materialize the Wednesday execution (weekday 3) after the allocations so
-- generate_trips inserts the fleet-managed passengers fresh.
select is(private.generate_trips(
  (select effective_on + 2 from fleet_student_case),
  (((select effective_on from fleet_student_case) - 1) + time '12:00') at time zone 'UTC'),
  2, 'the Wednesday date materializes both directional executions');

-- Case 1: the fleet-managed minor is confirmed by default at materialization.
select is((select confirmation_status from public.trip_passengers
  where trip_id = (select t.id from public.trips t
      join public.routes r on r.id = t.route_id and r.fleet_id = t.fleet_id
    where t.schedule_id = (select going_schedule_id from fleet_student_case)
      and t.service_date = (select effective_on + 2 from fleet_student_case)
      and r.direction = 'going')
    and student_id = (select student_id from fleet_student_case)
    and removed_at is null), 'confirmed',
  'the fleet-managed passenger is auto-confirmed at materialization');
select isnt((select confirmation_at from public.trip_passengers
  where trip_id = (select t.id from public.trips t
      join public.routes r on r.id = t.route_id and r.fleet_id = t.fleet_id
    where t.schedule_id = (select going_schedule_id from fleet_student_case)
      and t.service_date = (select effective_on + 2 from fleet_student_case)
      and r.direction = 'going')
    and student_id = (select student_id from fleet_student_case)), null,
  'the auto-confirmation records its timestamp');
select is((select confirmation_by from public.trip_passengers
  where trip_id = (select t.id from public.trips t
      join public.routes r on r.id = t.route_id and r.fleet_id = t.fleet_id
    where t.schedule_id = (select going_schedule_id from fleet_student_case)
      and t.service_date = (select effective_on + 2 from fleet_student_case)
      and r.direction = 'going')
    and student_id = (select student_id from fleet_student_case)), null,
  'no user is recorded as the confirmer');

-- Case 3: an active guardian opts the fleet-managed student out.
select is((select confirmation_status from public.trip_passengers
  where trip_id = (select t.id from public.trips t
      join public.routes r on r.id = t.route_id and r.fleet_id = t.fleet_id
    where t.schedule_id = (select going_schedule_id from fleet_student_case)
      and t.service_date = (select effective_on + 2 from fleet_student_case)
      and r.direction = 'going')
    and student_id = (select student_id from guarded_student_case)
    and removed_at is null), 'pending',
  'a fleet-managed student with an active guardian stays pending');

-- Case 4: the deadline closure spares the auto-confirmed passenger.
select is(private.close_confirmations(
  (select confirmation_deadline from public.trips
   where id = (select t.id from public.trips t
       join public.routes r on r.id = t.route_id and r.fleet_id = t.fleet_id
     where t.schedule_id = (select going_schedule_id from fleet_student_case)
       and t.service_date = (select effective_on + 2 from fleet_student_case)
       and r.direction = 'going'))) >= 1, true,
  'the deadline closure processes the due trips');
select is((select confirmation_status from public.trip_passengers
  where trip_id = (select t.id from public.trips t
      join public.routes r on r.id = t.route_id and r.fleet_id = t.fleet_id
    where t.schedule_id = (select going_schedule_id from fleet_student_case)
      and t.service_date = (select effective_on + 2 from fleet_student_case)
      and r.direction = 'going')
    and student_id = (select student_id from fleet_student_case)), 'confirmed',
  'the auto-confirmed passenger survives the deadline');
select is((select confirmation_status from public.trip_passengers
  where trip_id = (select t.id from public.trips t
      join public.routes r on r.id = t.route_id and r.fleet_id = t.fleet_id
    where t.schedule_id = (select going_schedule_id from fleet_student_case)
      and t.service_date = (select effective_on + 2 from fleet_student_case)
      and r.direction = 'going')
    and student_id = (select id from planning_ids where kind = 'minor')), 'expired',
  'the guardian-created passenger expires at the deadline');

-- Case 5: a reconciliation-style reset is confirmed again.
update public.trip_passengers
set confirmation_status = 'pending', confirmation_by = null, confirmation_at = null
where trip_id = (select t.id from public.trips t
    join public.routes r on r.id = t.route_id and r.fleet_id = t.fleet_id
  where t.schedule_id = (select going_schedule_id from fleet_student_case)
    and t.service_date = (select effective_on + 2 from fleet_student_case)
    and r.direction = 'going')
  and student_id = (select student_id from fleet_student_case);
select is((select confirmation_status from public.trip_passengers
  where trip_id = (select t.id from public.trips t
      join public.routes r on r.id = t.route_id and r.fleet_id = t.fleet_id
    where t.schedule_id = (select going_schedule_id from fleet_student_case)
      and t.service_date = (select effective_on + 2 from fleet_student_case)
      and r.direction = 'going')
    and student_id = (select student_id from fleet_student_case)), 'confirmed',
  'the reinstated passenger is auto-confirmed again');

-- Case 6: another fleet's guardian-created passenger is never touched, and
-- every passenger row keeps its own trip fleet.
update public.fleets set status = 'published'
where id = '41000000-0000-0000-0000-000000000002';
select pg_temp.as_user('40000000-0000-0000-0000-000000000005');
insert into public.fleet_service_cities (fleet_id, city_ibge_code, city_name,
  state_code, created_by)
values ('41000000-0000-0000-0000-000000000002', '3550000', 'Cidade Teste', 'SP',
  '40000000-0000-0000-0000-000000000005');
insert into public.fleet_service_schools (fleet_id, school_id, created_by)
values ('41000000-0000-0000-0000-000000000002',
  (select id from planning_ids where kind = 'school'),
  '40000000-0000-0000-0000-000000000005');
select lives_ok($$select public.enable_owner_driving(
  '41000000-0000-0000-0000-000000000002', '94000000-0000-4000-8000-000000000021')$$,
  'the second fleet owner becomes its own driver');
create temp table fleet_b_ids (kind text primary key, id uuid) on commit drop;
-- Each step is its own statement so the next one can read the previous id.
insert into fleet_b_ids values
  ('fleet', '41000000-0000-0000-0000-000000000002'::uuid);
insert into fleet_b_ids values
  ('van', public.save_van('41000000-0000-0000-0000-000000000002', null,
    'CYC-5858', 'Micro', 'Van Frota B 58', 30));
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
        (select id from planning_ids where kind = 'school'), 'position', 1)))));
insert into fleet_b_ids values
  ('schedule', public.save_route_schedule(
    (select id from fleet_b_ids where kind = 'route'), null,
    jsonb_build_object('weekdays', jsonb_build_array(1), 'starts_at', '08:00',
      'ends_at', '09:00', 'ends_next_day', false, 'timezone', 'America/Sao_Paulo',
      'valid_from', (current_date + 1)::text, 'valid_until', (current_date + 90)::text,
      'confirmation_minutes', 30)));
insert into fleet_b_ids values
  ('student', public.create_minor_student('Aluno Frota B', current_date - 3000,
    '18000000', 'Rua B', '5', null, 'Centro', 'Cidade Teste', '3550000', 'SP',
    -23.5, -46.6));
insert into fleet_b_ids values
  ('request', public.submit_fleet_join_request(
    '41000000-0000-0000-0000-000000000002',
    (select id from fleet_b_ids where kind = 'student'),
    (select id from planning_ids where kind = 'school'), 'morning',
    array['going']::text[], array[1]::smallint[]));
insert into fleet_b_ids values
  ('enrollment', public.approve_transport_request(
    (select id from fleet_b_ids where kind = 'request'),
    jsonb_build_array(jsonb_build_object('schedule_id',
      (select id from fleet_b_ids where kind = 'schedule'), 'weekday', 1,
      'direction', 'going')),
    (select effective_on from fleet_student_case)));
select is(private.generate_trips(
  (select effective_on from fleet_student_case),
  (((select effective_on from fleet_student_case) - 1) + time '12:00') at time zone 'UTC'),
  1, 'the second fleet materializes its own execution');
select is((select p.confirmation_status
  from public.trip_passengers p
  where p.fleet_id = (select id from fleet_b_ids where kind = 'fleet')
    and p.removed_at is null), 'pending',
  'the second fleet guardian-created passenger stays pending');
select is((select count(*)::bigint from public.trip_passengers p
  join public.trips t on t.id = p.trip_id and t.fleet_id = p.fleet_id
  where p.fleet_id <> t.fleet_id), 0::bigint,
  'every passenger row carries its trip fleet');

-- Scope: only unguarded fleet-managed students are ever auto-confirmed.
select is((select count(*)::bigint from public.trip_passengers p
  join public.students s on s.id = p.student_id
  where p.confirmation_status = 'confirmed'
    and (s.registration_origin <> 'fleet_owner_created' or s.profile_id is not null))
  + (select count(*)::bigint from public.trip_passengers p
  join public.student_guardians g on g.student_id = p.student_id and g.status = 'active'
  where p.confirmation_status = 'confirmed'), 0::bigint,
  'only unguarded fleet-managed students are ever auto-confirmed');

-- Case 7: the assigned driver operates the auto-confirmed passenger.
select pg_temp.as_user('40000000-0000-0000-0000-000000000003');
select is(public.start_trip(
  (select t.id from public.trips t
      join public.routes r on r.id = t.route_id and r.fleet_id = t.fleet_id
    where t.schedule_id = (select going_schedule_id from fleet_student_case)
      and t.service_date = (select effective_on + 2 from fleet_student_case)
      and r.direction = 'going'),
  '93000000-0000-4000-8000-000000000019'), 'active',
  'the driver starts the trip with the auto-confirmed passenger');
select is(public.record_passenger_event(
  (select t.id from public.trips t
      join public.routes r on r.id = t.route_id and r.fleet_id = t.fleet_id
    where t.schedule_id = (select going_schedule_id from fleet_student_case)
      and t.service_date = (select effective_on + 2 from fleet_student_case)
      and r.direction = 'going'),
  (select student_id from fleet_student_case), 'boarded',
  '93000000-0000-4000-8000-000000000020'), 'boarded',
  'the driver boards the auto-confirmed fleet-managed student');

select * from finish();

rollback;
