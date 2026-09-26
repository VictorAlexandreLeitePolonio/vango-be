begin;
create extension if not exists pgtap with schema extensions;
\ir ../_fleet_transport.psql
select no_plan();
select has_function('private','transport_change_date_is_open',
 array['uuid','uuid','jsonb','date','timestamp with time zone'],
 'requested effective date has a shared cutoff predicate');
select pg_temp.seed_fleet_transport();
update public.route_schedules set valid_from='2030-04-01',valid_until='2030-05-31',starts_at='07:00',ends_at='08:00'
where id=(select going_schedule_id from transport_case);
update public.route_schedules set valid_from='2030-04-01',valid_until='2030-05-31'
where id=(select return_schedule_id from transport_case);
select is(private.transport_change_date_is_open(fleet_id,enrollment_id,allocations,'2030-04-01','2030-04-01 09:29:59+00'),
 true,'first allocation immediately before cutoff is open') from transport_case;
select is(private.transport_change_date_is_open(fleet_id,enrollment_id,allocations,'2030-04-01','2030-04-01 09:30:00+00'),
 false,'cutoff equality is closed') from transport_case;
select is(private.transport_change_date_is_open(fleet_id,enrollment_id,allocations,'2030-04-08','2030-04-01 09:30:00+00'),
 true,'a later safe date is accepted without rewriting') from transport_case;
select is(private.transport_change_date_is_open(fleet_id,enrollment_id,allocations,'2030-06-03','2030-04-01 09:29:59+00'),
 false,'date after schedule validity is rejected') from transport_case;
select is(private.transport_change_date_is_open(fleet_id,enrollment_id,allocations,'-infinity','2030-04-01 09:29:59+00'),
 false,'nonfinite effective date is rejected') from transport_case;
-- The server timezone must not determine the service-day boundary.
set local timezone='UTC';
update public.route_schedules set timezone='Pacific/Auckland' where id=(select going_schedule_id from transport_case);
select is(private.transport_change_date_is_open(fleet_id,enrollment_id,allocations,'2030-04-01','2030-03-31 17:29:59+00'),
 true,'Auckland cutoff uses local service date') from transport_case;
select is(private.transport_change_date_is_open(fleet_id,enrollment_id,allocations,'2030-04-01','2030-03-31 17:30:00+00'),
 false,'Auckland cutoff equality is closed') from transport_case;
update public.route_schedules set timezone='America/Sao_Paulo' where id=(select going_schedule_id from transport_case);
insert into public.route_student_schedules(fleet_id,enrollment_id,route_id,schedule_id,weekday,direction,valid_from,valid_until)
select c.fleet_id,c.enrollment_id,s.route_id,s.id,1,'going','2030-04-01',s.valid_until
from transport_case c join public.route_schedules s on s.id=c.going_schedule_id;
select is(private.transport_change_date_is_open(fleet_id,enrollment_id,allocations,'2030-04-01','2030-04-01 09:00:00+00'),
 false,'replacement cannot rewrite the local current day') from transport_case;
-- A long confirmation window can close a removed old day before the local-date floor.
update public.route_schedules set confirmation_minutes=1440 where id=(select going_schedule_id from transport_case);
select is(private.transport_change_date_is_open(fleet_id,enrollment_id,jsonb_build_array(allocations->2),'2030-04-01','2030-03-31 11:00:00+00'),
 false,'closed cutoff of removed old Monday blocks replacing with Friday only') from transport_case;
select * from finish();
rollback;
