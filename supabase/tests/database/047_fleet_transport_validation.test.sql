begin;
create extension if not exists pgtap with schema extensions;
\ir ../_fleet_transport.psql
select no_plan();
select has_function('private', 'normalize_fleet_transport_allocations', array['jsonb'],
  'explicit allocation normalization is available');
create function pg_temp.allocation_error(p_input jsonb) returns text language plpgsql as $$
begin
  perform private.normalize_fleet_transport_allocations(p_input);
  return null;
exception when sqlstate 'PGRST' then
  return sqlerrm::jsonb->>'code';
end;
$$;
select is(private.normalize_fleet_transport_allocations('[
 {"schedule_id":"22222222-2222-4222-8222-222222222222","weekday":5,"direction":"return"},
 {"schedule_id":"11111111-1111-4111-8111-111111111111","weekday":1,"direction":"going"},
 {"schedule_id":"11111111-1111-4111-8111-111111111111","weekday":3,"direction":"going"}
]'::jsonb)->0->>'direction', 'going', 'explicit pairs are canonically sorted');
select is(pg_temp.allocation_error(input), 'invalid_input', description)
from (values
 ('[]'::jsonb, 'empty allocations cannot suspend transport'),
 ('null'::jsonb, 'null allocations are rejected'),
 ('{}'::jsonb, 'nonarray allocations are rejected'),
 ('[{"schedule_id":"11111111-1111-4111-8111-111111111111","weekday":1.5,"direction":"going"}]'::jsonb, 'fractional weekday is rejected'),
 ('[{"schedule_id":"11111111-1111-4111-8111-111111111111","weekday":0,"direction":"going"}]'::jsonb, 'weekday zero is rejected'),
 ('[{"schedule_id":"11111111-1111-4111-8111-111111111111","weekday":8,"direction":"going"}]'::jsonb, 'weekday eight is rejected'),
 ('[{"schedule_id":"bad","weekday":1,"direction":"going"}]'::jsonb, 'malformed UUID is rejected'),
 ('[{"schedule_id":"11111111-1111-4111-8111-111111111111","weekday":1,"direction":"other"}]'::jsonb, 'unknown direction is rejected'),
 ('[{"schedule_id":"11111111-1111-4111-8111-111111111111","weekday":1}]'::jsonb, 'missing direction is rejected'),
 ('[{"schedule_id":"11111111-1111-4111-8111-111111111111","weekday":1,"direction":"going","extra":true}]'::jsonb, 'unknown property is rejected'),
 ('[{"schedule_id":"11111111-1111-4111-8111-111111111111","weekday":1,"direction":"going"},{"schedule_id":"22222222-2222-4222-8222-222222222222","weekday":1,"direction":"going"}]'::jsonb, 'duplicate pair is rejected')
) cases(input, description);
select pg_temp.seed_fleet_transport();
select has_function('private','validate_transport_allocations',
  array['uuid','uuid','uuid','uuid','text','jsonb','date'],
  'direct and marketplace paths share allocation validation');
select is(jsonb_array_length(private.validate_transport_allocations(
  fleet_id,student_id,enrollment_id,school_id,'morning',allocations,effective_on)),
  3, 'shared validator preserves three asymmetric pairs') from transport_case;
select is(pg_temp.fleet_transport_error(format(
  'select private.validate_transport_allocations(%L,%L,%L,%L,%L,%L::jsonb,%L::date)',
  fleet_id,student_id,enrollment_id,school_id,'afternoon',allocations,effective_on)),
  'invalid_input','shift mismatch is rejected') from transport_case;
select is(pg_temp.fleet_transport_error(format(
  'select private.validate_transport_allocations(%L,%L,%L,%L,%L,%L::jsonb,%L::date)',
  fleet_id,student_id,enrollment_id,school_id,'morning',
  jsonb_set(allocations,'{0,direction}','"return"'),effective_on)),
  'invalid_input','forged direction is rejected') from transport_case;
-- Controlled schedules overlap overnight; no production scheduling command permits this.
update public.route_schedules set starts_at='22:00',ends_at='02:00',ends_next_day=true,weekdays=array[1]::smallint[]
where id=(select going_schedule_id from transport_case);
update public.route_schedules set starts_at='01:00',ends_at='03:00',weekdays=array[2]::smallint[]
where id=(select return_schedule_id from transport_case);
insert into public.route_student_schedules(fleet_id,enrollment_id,route_id,schedule_id,weekday,direction,valid_from,valid_until)
select c.fleet_id,c.enrollment_id,s.route_id,s.id,1,'going',c.effective_on,s.valid_until
from transport_case c join public.route_schedules s on s.id=c.going_schedule_id;
insert into public.transport_reservations(fleet_id,enrollment_id,student_id,route_student_schedule_id,route_id,schedule_id,van_id,weekday,direction,valid_from,valid_until)
select c.fleet_id,c.enrollment_id,c.student_id,rss.id,s.route_id,s.id,r.van_id,1,'going',c.effective_on,s.valid_until
from transport_case c join public.route_schedules s on s.id=c.going_schedule_id
join public.routes r on r.id=s.route_id join public.route_student_schedules rss on rss.enrollment_id=c.enrollment_id;
select is(private.student_schedule_conflicts(student_id,return_schedule_id,2::smallint,effective_on+1,enrollment_id),
 true,'retained previous-day overnight execution still conflicts') from transport_case;
select is(private.reservation_has_capacity(return_schedule_id,2::smallint,effective_on+1,1,enrollment_id),
 false,'retained previous-day overnight execution still consumes the last seat') from transport_case;
select is(private.reservation_has_capacity(going_schedule_id,1::smallint,effective_on,1,enrollment_id),
 true,'superseded own seat can be reused') from transport_case;
select * from finish();
rollback;
