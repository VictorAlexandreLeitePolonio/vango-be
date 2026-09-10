begin;

create extension if not exists pgtap with schema extensions;
\ir ../_helpers.psql
\ir ../_approval.psql

select plan(15);
select pg_temp.seed_cycle_2_users();
create temp table enrollment_test_ids(kind text primary key, id uuid) on commit drop;
grant all on enrollment_test_ids to authenticated;

insert into public.fleets (id, name, slug, status, created_by)
values ('61000000-0000-0000-0000-000000000001', 'Frota Enrollment', 'frota-enrollment', 'published', '60000000-0000-0000-0000-000000000005');
insert into public.fleet_memberships (id, fleet_id, user_id)
values ('62000000-0000-0000-0000-000000000001', '61000000-0000-0000-0000-000000000001', '60000000-0000-0000-0000-000000000005');
insert into public.fleet_membership_roles (membership_id, role)
values ('62000000-0000-0000-0000-000000000001', 'owner');
insert into public.schools (
  id, provider, external_id, institution_type, name, postal_code, street,
  street_number, neighborhood, city_name, city_ibge_code, state_code
) values (
  '63000000-0000-0000-0000-000000000001', 'inep', 'enrollment-school', 'school',
  'Teste Escola Enrollment', '18000000', 'Rua Escola', '1', 'Centro', 'Teste', '3550000', 'SP'
);
insert into public.fleet_service_cities (fleet_id, city_ibge_code, city_name, state_code, created_by)
values ('61000000-0000-0000-0000-000000000001', '3550000', 'Teste', 'SP', '60000000-0000-0000-0000-000000000005');
insert into public.fleet_service_schools (fleet_id, school_id, created_by)
values ('61000000-0000-0000-0000-000000000001', '63000000-0000-0000-0000-000000000001', '60000000-0000-0000-0000-000000000005');

select set_config('request.jwt.claims', '{"sub":"60000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.create_minor_student('Teste Menor Enrollment', '2015-02-03', '18000000', 'Rua Menor', '10', null, 'Centro', 'Teste', '3550000', 'SP', null, null);
select lives_ok(
  $$select public.submit_fleet_join_request('61000000-0000-0000-0000-000000000001', (select id from public.students where full_name = 'Teste Menor Enrollment'), '63000000-0000-0000-0000-000000000001', 'morning', array['going']::text[], array[1]::smallint[])$$,
  'minor request is submitted for approval'
);

reset role;
select set_config('request.jwt.claims', '{"sub":"60000000-0000-0000-0000-000000000003","role":"authenticated"}', true);
set local role authenticated;
select public.create_adult_student('Teste Adulto Enrollment', (current_date - interval '18 years')::date, '18000000', 'Rua Adulto', '20', null, 'Centro', 'Teste', '3550000', 'SP', null, null);
select lives_ok(
  $$select public.submit_fleet_join_request('61000000-0000-0000-0000-000000000001', (select id from public.students where full_name = 'Teste Adulto Enrollment'), '63000000-0000-0000-0000-000000000001', 'evening', array['return']::text[], array[2]::smallint[])$$,
  'adult request is submitted for approval'
);

reset role;
insert into enrollment_test_ids(kind, id)
select case when s.full_name = 'Teste Menor Enrollment' then 'minor-request' else 'adult-request' end, r.id
from public.fleet_join_requests r
join public.students s on s.id = r.student_id
where s.full_name in ('Teste Menor Enrollment', 'Teste Adulto Enrollment');
select set_config('request.jwt.claims', '{"sub":"60000000-0000-0000-0000-000000000005","role":"authenticated"}', true);
insert into enrollment_test_ids(kind, id)
select 'approval-schedule', pg_temp.seed_approval_schedule(
  (select id from enrollment_test_ids where kind = 'minor-request')
);
set local role authenticated;
select lives_ok(
  $$select public.approve_transport_request(
    (select id from enrollment_test_ids where kind = 'minor-request'),
    jsonb_build_array(jsonb_build_object('schedule_id',
      (select id from enrollment_test_ids where kind = 'approval-schedule'), 'weekday', 1)),
    current_date + 1)$$,
  'owner approves minor request with the required reservation'
);
select is(
  (select status from public.list_fleet_join_requests('61000000-0000-0000-0000-000000000001', 'approved', 50, 0) where student_full_name = 'Teste Menor Enrollment'),
  'approved',
  'approved request changes status atomically'
);
reset role;
select is(
  (select count(*)::integer from public.fleet_enrollments where student_id = (select id from public.students where full_name = 'Teste Menor Enrollment') and status = 'active'),
  1,
  'approval creates one active enrollment'
);
select set_config('request.jwt.claims', '{"sub":"60000000-0000-0000-0000-000000000005","role":"authenticated"}', true);
set local role authenticated;
select is(
  (select count(*)::integer from public.fleet_membership_roles fmr join public.fleet_memberships fm on fm.id = fmr.membership_id where fm.fleet_id = '61000000-0000-0000-0000-000000000001' and fm.user_id = '60000000-0000-0000-0000-000000000001' and fmr.role = 'guardian'),
  1,
  'minor primary receives guardian role'
);
select lives_ok(
  $$select public.decide_fleet_join_request((select id from enrollment_test_ids where kind = 'adult-request'), 'rejected')$$,
  'owner rejects adult request'
);
select is(
  (select street from public.list_fleet_join_requests('61000000-0000-0000-0000-000000000001', 'rejected', 50, 0) where student_full_name = 'Teste Adulto Enrollment'),
  null,
  'rejected request projection hides residential address'
);
select throws_ok(
  $$select public.decide_fleet_join_request((select id from enrollment_test_ids where kind = 'adult-request'), 'approved')$$,
  'PGRST', null, 'rejected request cannot be decided again'
);

reset role;
insert into enrollment_test_ids(kind, id)
select 'minor-enrollment', e.id
from public.fleet_enrollments e
where e.student_id = (select id from public.students where full_name = 'Teste Menor Enrollment');
select set_config('request.jwt.claims', '{"sub":"60000000-0000-0000-0000-000000000005","role":"authenticated"}', true);
set local role authenticated;
select lives_ok(
  $$select public.end_fleet_enrollment((select id from enrollment_test_ids where kind = 'minor-enrollment'), 'family changed address')$$,
  'owner ends enrollment with a reason'
);
reset role;
select is(
  (select status from public.fleet_enrollments where student_id = (select id from public.students where full_name = 'Teste Menor Enrollment')),
  'ended',
  'enrollment status becomes ended'
);
select set_config('request.jwt.claims', '{"sub":"60000000-0000-0000-0000-000000000005","role":"authenticated"}', true);
set local role authenticated;
select is(
  (select count(*)::integer from public.fleet_membership_roles fmr join public.fleet_memberships fm on fm.id = fmr.membership_id where fm.fleet_id = '61000000-0000-0000-0000-000000000001' and fm.user_id = '60000000-0000-0000-0000-000000000001' and fmr.role = 'guardian'),
  0,
  'derived guardian role is removed after enrollment ends'
);
select is(
  (select count(*)::integer from public.fleet_membership_roles fmr join public.fleet_memberships fm on fm.id = fmr.membership_id where fm.fleet_id = '61000000-0000-0000-0000-000000000001' and fm.user_id = '60000000-0000-0000-0000-000000000005' and fmr.role = 'owner'),
  1,
  'manual owner role remains intact'
);
select is(
  (select street from public.list_fleet_join_requests('61000000-0000-0000-0000-000000000001', 'approved', 50, 0) where student_full_name = 'Teste Menor Enrollment'),
  null,
  'ended enrollment projection hides address'
);
select throws_ok(
  $$select public.end_fleet_enrollment((select id from enrollment_test_ids where kind = 'minor-enrollment'), 'again')$$,
  'PGRST', null, 'ended enrollment cannot be ended again'
);

select * from finish();

rollback;
