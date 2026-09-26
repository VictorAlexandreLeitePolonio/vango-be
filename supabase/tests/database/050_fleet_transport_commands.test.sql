begin;
create extension if not exists pgtap with schema extensions;
\ir ../_fleet_transport.psql
select no_plan();
select has_function('public','assign_fleet_student_transport',
 array['uuid','uuid','jsonb','date','uuid','bigint'], 'owner allocation command publishes the receipt contract');
select pg_temp.seed_fleet_transport();
select is(pg_temp.fleet_transport_error(format(
 'select * from public.assign_fleet_student_transport(%L,%L,%L::jsonb,%L::date,%L,%s)',
 enrollment_id,school_id,allocations,effective_on,command_a,initial_revision)),
 null::text,'owner can allocate without marketplace request') from transport_case;
select is((select count(*) from public.transport_reservations r where r.enrollment_id=c.enrollment_id and r.status='active'),
 3::bigint,'three explicit pairs persist as three reservations') from transport_case c;
select is((select routing_revision from public.fleet_enrollments where id=c.enrollment_id),
 c.initial_revision+1,'accepted command advances enrollment revision once') from transport_case c;
create function pg_temp.assign_transport(p_command uuid default null,p_revision bigint default null,
 p_allocations jsonb default null,p_effective_on date default null) returns bigint language sql as $$
 select result.routing_revision from transport_case c cross join lateral public.assign_fleet_student_transport(
 c.enrollment_id,c.school_id,coalesce(p_allocations,c.allocations),coalesce(p_effective_on,c.effective_on),
 coalesce(p_command,c.command_a),coalesce(p_revision,c.initial_revision)) result;
$$;
create temp table registered_origin as select e.registration_command_id,e.registration_payload_hash,e.source_type,e.school_id
from public.fleet_enrollments e where e.id=(select enrollment_id from transport_case);
set local role authenticated;
select is(pg_temp.assign_transport(),(select initial_revision+1 from transport_case),'identical replay returns original revision');
select is(pg_temp.assign_transport(p_allocations => (select jsonb_agg(value order by ord desc)
 from transport_case c,jsonb_array_elements(c.allocations) with ordinality x(value,ord))),
 (select initial_revision+1 from transport_case),'array order does not change command identity');
select is(pg_temp.fleet_transport_error($$select pg_temp.assign_transport(p_revision=>999)$$),
 'idempotency_conflict','changing replay revision conflicts');
select is(pg_temp.fleet_transport_error($$select pg_temp.assign_transport(p_command=>'93000000-0000-4000-8000-000000000016')$$),
 'revision_conflict','fresh stale edit conflicts');
select is(pg_temp.assign_transport((select command_b from transport_case),(select initial_revision+1 from transport_case),
 (select jsonb_build_array(allocations->0) from transport_case)),(select initial_revision+2 from transport_case),
 'B completely replaces A');
select is(pg_temp.assign_transport(),(select initial_revision+1 from transport_case),'late A replay returns historical receipt');
reset role;
select is((select count(*) from public.transport_reservations r where r.enrollment_id=c.enrollment_id and r.status='active'),
 1::bigint,'late replay did not revert B') from transport_case c;
select is((select count(*) from private.fleet_student_transport_commands r where r.enrollment_id=c.enrollment_id),
 2::bigint,'exactly two accepted commands have receipts') from transport_case c;
select is((select count(*) from public.audit_events a where a.entity_id=c.enrollment_id and a.action='fleet_student_transport_assigned'),
 2::bigint,'replays have no new allocation audit') from transport_case c;
select is((select jsonb_build_array(registration_command_id,registration_payload_hash,source_type,school_id)
 from public.fleet_enrollments where id=c.enrollment_id),
 (select jsonb_build_array(registration_command_id,registration_payload_hash,source_type,school_id) from registered_origin),
 'allocation preserves registration provenance and school') from transport_case c;
select ok(not has_table_privilege('authenticated','private.fleet_student_transport_commands','SELECT'), 'receipt reads are private');
select ok(not has_table_privilege('authenticated','private.fleet_student_transport_commands','INSERT'), 'receipt writes are private');
select ok(not has_function_privilege('anon','public.assign_fleet_student_transport(uuid,uuid,jsonb,date,uuid,bigint)','EXECUTE'), 'anonymous execution is revoked');
select throws_ok($$update private.fleet_student_transport_commands set routing_revision=100$$,'23514',null,'receipts cannot be rewritten');
select throws_ok($$delete from private.fleet_student_transport_commands$$,'23514',null,'receipts cannot be deleted');
-- A driver or foreign owner cannot discover a known enrollment through replay.
select set_config('request.jwt.claims','{"sub":"40000000-0000-0000-0000-000000000003","role":"authenticated"}',true);
set local role authenticated;
select is(pg_temp.fleet_transport_error($$select pg_temp.assign_transport()$$),'not_found','driver replay is denied');
reset role;
select set_config('request.jwt.claims','{"sub":"40000000-0000-0000-0000-000000000005","role":"authenticated"}',true);
set local role authenticated;
select is(pg_temp.fleet_transport_error($$select pg_temp.assign_transport()$$),'not_found','foreign owner replay is denied');
reset role;
select set_config('request.jwt.claims','{"sub":"40000000-0000-0000-0000-000000000002","role":"authenticated"}',true);
set local role authenticated;
select is(pg_temp.fleet_transport_error($$select pg_temp.assign_transport()$$),'idempotency_conflict','another owner cannot reuse actor-bound receipt');
reset role;
select set_config('request.jwt.claims','{"sub":"40000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
update public.schools set status='inactive' where id=(select school_id from transport_case);
set local role authenticated;
select is(pg_temp.assign_transport(),(select initial_revision+1 from transport_case),'replay precedes mutable school validation');
reset role;
update public.schools set status='active' where id=(select school_id from transport_case);
-- Fault injection happens after reservation/revision/audit writes, within a rollback-only test.
create temp table before_failure as select
 (select jsonb_agg(to_jsonb(r) order by r.id) from public.transport_reservations r) reservations,
 (select jsonb_agg(to_jsonb(e) order by e.id) from public.fleet_enrollments e) enrollments,
 (select count(*) from public.audit_events) audits;
create function pg_temp.fail_transport_receipt() returns trigger language plpgsql as $$
begin raise exception 'injected receipt failure'; end; $$;
create trigger injected_receipt_failure before insert on private.fleet_student_transport_commands
for each row execute function pg_temp.fail_transport_receipt();
set local role authenticated;
select is(pg_temp.fleet_transport_error($$select pg_temp.assign_transport('93000000-0000-4000-8000-000000000016',3)$$),
 'allocation_failed','receipt failure is sanitized');
reset role;
select is((select jsonb_agg(to_jsonb(r) order by r.id) from public.transport_reservations r),reservations,
 'receipt failure rolls back reservations') from before_failure;
select is((select jsonb_agg(to_jsonb(e) order by e.id) from public.fleet_enrollments e),enrollments,
 'receipt failure rolls back enrollment revision') from before_failure;
select is((select count(*) from public.audit_events),audits,'receipt failure rolls back audit') from before_failure;
drop trigger injected_receipt_failure on private.fleet_student_transport_commands;
set local role authenticated;
select is((select receipt.routing_revision from transport_case c cross join lateral public.assign_fleet_student_transport(
 c.adult_enrollment_id,c.school_id,jsonb_build_array(c.allocations->1),c.effective_on,
 '94000000-0000-4000-8000-000000000016',1) receipt),2::bigint,'unclaimed adult can receive direct allocation');
reset role;

create temp table marketplace_program as select public.approve_transport_request(
 (select id from planning_ids where kind='request'),
 (select jsonb_agg(jsonb_build_object('schedule_id',case direction when 'going' then c.going_schedule_id else c.return_schedule_id end,
 'weekday',day,'direction',direction)) from transport_case c cross join generate_series(1,5) day cross join unnest(array['going','return']) direction),
 (select effective_on from transport_case)) enrollment_id;
alter table marketplace_program add column before_revision bigint;
alter table marketplace_program add column request_id uuid;
update marketplace_program m set before_revision=e.routing_revision from public.fleet_enrollments e where e.id=m.enrollment_id;
update marketplace_program set request_id=public.request_schedule_change(enrollment_id,array['going'],array[1]::smallint[]);
select public.approve_transport_request(m.request_id,jsonb_build_array(c.allocations->0),
 private.next_change_date(m.request_id,now(),jsonb_build_array(c.allocations->0))) from marketplace_program m cross join transport_case c;
select is(e.routing_revision,m.before_revision+1,'marketplace replacement invalidates stale owner revision')
from marketplace_program m join public.fleet_enrollments e on e.id=m.enrollment_id;
select is(pg_temp.fleet_transport_error($$select pg_temp.assign_transport(
 '97000000-0000-4000-8000-000000000016',3,p_effective_on=>current_date+365)$$),
 'effective_date_conflict','public command classifies dates outside schedule validity');
select * from finish();
rollback;
