begin;
create extension if not exists pgtap with schema extensions;
\ir ../_helpers.psql
\ir ../_planning.psql
\ir ../_operations.psql
select no_plan();
select pg_temp.seed_cycle_4();
create temp table original_passenger as
select p.*,t.service_date,t.revision trip_revision from public.trip_passengers p
join public.trips t on t.id=p.trip_id where p.id=(select id from operation_ids where kind='passenger');
create temp table original_stops as select s.* from public.trip_stops s join original_passenger p on p.trip_id=s.trip_id;
update public.trip_passengers set confirmation_status='confirmed',confirmation_by='60000000-0000-0000-0000-000000000001',confirmation_at=now()
where id=(select id from original_passenger);
update public.transport_reservations set status='cancelled',cancelled_at=now(),cancellation_reason='test replacement'
where enrollment_id=(select enrollment_id from original_passenger) and schedule_id=(select id from planning_ids where kind='going-schedule');
select private.reconcile_enrollment_trips(enrollment_id,'schedule',service_date,now()) from original_passenger;
select ok((select removed_at is not null from public.trip_passengers where id=o.id),'A is removed when no longer reserved') from original_passenger o;
update public.transport_reservations set status='active',cancelled_at=null,cancellation_reason=null
where enrollment_id=(select enrollment_id from original_passenger) and schedule_id=(select id from planning_ids where kind='going-schedule');
select private.reconcile_enrollment_trips(enrollment_id,'schedule',service_date,now()) from original_passenger;
select ok((select removed_at is null and confirmation_status='pending' and confirmation_by is null and confirmation_at is null
 and operation_status='waiting' from public.trip_passengers where id=o.id),'restored A reuses passenger and clears old confirmation') from original_passenger o;
select is((select count(*) from public.trip_stops s where s.trip_id=o.trip_id),4::bigint,'A-B-A has no duplicate semantic stops') from original_passenger o;
select is((select count(*) from public.trip_stops s join original_stops old using(id)),4::bigint,'original stop identities survive');
select is(private.reconcile_enrollment_trips(enrollment_id,'schedule',service_date,now()),0,'repeated reconciliation is a no-op') from original_passenger;
update public.trip_passengers set removed_at=now(),removal_reason='enrollment ended' where id=(select id from original_passenger);
select is(private.reconcile_enrollment_trips(enrollment_id,'schedule',service_date,now()),0,'unrelated removal is not restored') from original_passenger;
update public.trip_passengers set removal_reason='superseded by schedule change',operation_status='absent' where id=(select id from original_passenger);
select is(private.reconcile_enrollment_trips(enrollment_id,'schedule',service_date,now()),0,'operational absence is not reset') from original_passenger;
update public.trip_passengers set operation_status='waiting' where id=(select id from original_passenger);
update public.trips set status='confirmation_closed' where id=(select trip_id from original_passenger);
select is(private.reconcile_enrollment_trips(enrollment_id,'schedule',service_date,now()),0,'closed trip is not restored') from original_passenger;
-- A closed trip with already-removed participation is not changed by another program.
update public.route_student_schedules set status='cancelled',cancelled_at=now(),cancellation_reason='test removed A'
where enrollment_id=(select enrollment_id from original_passenger) and schedule_id=(select id from planning_ids where kind='going-schedule');
update public.transport_reservations set status='cancelled',cancelled_at=now(),cancellation_reason='test removed A'
where enrollment_id=(select enrollment_id from original_passenger) and schedule_id=(select id from planning_ids where kind='going-schedule');
select is(private.transport_change_date_is_open(o.fleet_id,o.enrollment_id,
 jsonb_build_array(jsonb_build_object('schedule_id',(select id from planning_ids where kind='return-schedule'),
 'weekday',extract(isodow from o.service_date)::integer,'direction','return')),o.service_date,now()),
 true,'closed removed A does not block a replacement that only uses B') from original_passenger o;
-- Reproduce the compact positions produced by an applied route calculation.
update public.trips set status='scheduled' where id=(select trip_id from original_passenger);
select public.request_trip_route_calculation(trip_id) as calculation_revision from original_passenger \gset
select public.apply_trip_route_result(o.trip_id,:calculation_revision::bigint,
 jsonb_build_object('revision',:calculation_revision::bigint,
 'orderedPointIds',(select jsonb_agg(s.id order by s.position) from public.trip_stops s where s.trip_id=o.trip_id),
 'distanceMeters',100,'durationSeconds',120,'calculatedAt',clock_timestamp(),'legs',(select jsonb_agg(jsonb_build_object('fromId',id,'toId',next_id,'distanceMeters',10,'durationSeconds',10) order by position)
 from (select id,position,lead(id) over(order by position) next_id from public.trip_stops where trip_id=o.trip_id) legs where next_id is not null))) from original_passenger o;
update public.schools set latitude=-23.5,longitude=-46.6 where id=(select id from planning_ids where kind='school');
create temp table added_student as select * from public.create_fleet_managed_student(
 '41000000-0000-0000-0000-000000000001','95000000-0000-4000-8000-000000000016',
 'minor','Added After Calculation',current_date-3650,'18000000','Street','10',null,'Center','Cidade Teste','3550000','SP',-23.5,-46.6,
 (select id from planning_ids where kind='school'),'morning','Contact','test@example.com',null);
select * from public.assign_fleet_student_transport((select enrollment_id from added_student),
 (select id from planning_ids where kind='school'),jsonb_build_array(jsonb_build_object(
 'schedule_id',(select id from planning_ids where kind='going-schedule'),
 'weekday',(select extract(isodow from service_date)::integer from original_passenger),'direction','going')),
 (select service_date from original_passenger),'96000000-0000-4000-8000-000000000016',1);
select is((select count(*) from public.trip_stops s join added_student a on a.student_id=s.student_id
 where s.trip_id=o.trip_id and s.kind='home'),1::bigint,'allocation after compact route calculation creates a home stop') from original_passenger o;
select ok((select h.position<school.position and school.position<dest.position
 from public.trip_stops h join added_student a on a.student_id=h.student_id
 join public.trip_stops school on school.trip_id=h.trip_id and school.kind='school'
 join public.trip_stops dest on dest.trip_id=h.trip_id and dest.kind='destination'
 where h.trip_id=o.trip_id and h.kind='home'),'new home remains before school and destination on going route') from original_passenger o;

select * from finish();
rollback;
