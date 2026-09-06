begin;

create extension if not exists pgtap with schema extensions;
\ir ../_helpers.psql

select plan(11);
select pg_temp.seed_cycle_2_users();

insert into public.fleets (id, name, slug, status, created_by)
values ('61000000-0000-0000-0000-000000000001', 'Frota Marketplace', 'frota-marketplace', 'published', '60000000-0000-0000-0000-000000000005');
insert into public.fleet_memberships (id, fleet_id, user_id)
values ('62000000-0000-0000-0000-000000000001', '61000000-0000-0000-0000-000000000001', '60000000-0000-0000-0000-000000000005');
insert into public.fleet_membership_roles (membership_id, role)
values ('62000000-0000-0000-0000-000000000001', 'owner');
insert into public.schools (
  id, provider, external_id, institution_type, name, postal_code, street,
  street_number, neighborhood, city_name, city_ibge_code, state_code
) values (
  '63000000-0000-0000-0000-000000000001', 'inep', 'request-school', 'school',
  'Teste Escola Request', '18000000', 'Rua Escola', '1', 'Centro', 'Teste', '3550000', 'SP'
);
insert into public.fleet_service_cities (fleet_id, city_ibge_code, city_name, state_code, created_by)
values ('61000000-0000-0000-0000-000000000001', '3550000', 'Teste', 'SP', '60000000-0000-0000-0000-000000000005');
insert into public.fleet_service_schools (fleet_id, school_id, created_by)
values ('61000000-0000-0000-0000-000000000001', '63000000-0000-0000-0000-000000000001', '60000000-0000-0000-0000-000000000005');

select set_config('request.jwt.claims', '{"sub":"60000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.create_minor_student('Teste Menor Request', '2015-02-03', '18000000', 'Rua Menor', '10', null, 'Centro', 'Teste', '3550000', 'SP', null, null);

select lives_ok(
  $$select public.submit_fleet_join_request(
    '61000000-0000-0000-0000-000000000001',
    (select id from public.students where full_name = 'Teste Menor Request'),
    '63000000-0000-0000-0000-000000000001',
    'morning', array['going']::text[], array[1, 3, 5]::smallint[]
  )$$,
  'primary guardian submits marketplace request'
);
select is(
  (select count(*)::integer from public.fleet_join_requests where status = 'pending'),
  1,
  'one pending request is created'
);
select is(
  (select street from public.fleet_join_requests where status = 'pending'),
  'Rua Menor',
  'request stores an address snapshot'
);
select throws_ok(
  $$select public.submit_fleet_join_request(
    '61000000-0000-0000-0000-000000000001',
    (select id from public.students where full_name = 'Teste Menor Request'),
    '63000000-0000-0000-0000-000000000001',
    'morning', array['going']::text[], array[1]::smallint[]
  )$$,
  'PGRST', null, 'duplicate pending request is rejected'
);
select throws_ok(
  $$select public.submit_fleet_join_request(
    '61000000-0000-0000-0000-000000000001',
    (select id from public.students where full_name = 'Teste Menor Request'),
    '63000000-0000-0000-0000-000000000001',
    'morning', array['going', 'going']::text[], array[1]::smallint[]
  )$$,
  'PGRST', null, 'duplicate directions are rejected'
);

reset role;
insert into public.student_guardians (student_id, guardian_user_id, is_primary, status)
select id, '60000000-0000-0000-0000-000000000002', false, 'active'
from public.students where full_name = 'Teste Menor Request';

select set_config('request.jwt.claims', '{"sub":"60000000-0000-0000-0000-000000000002","role":"authenticated"}', true);
set local role authenticated;
select throws_ok(
  $$select public.submit_fleet_join_request(
    '61000000-0000-0000-0000-000000000001',
    (select id from public.students where full_name = 'Teste Menor Request'),
    '63000000-0000-0000-0000-000000000001',
    'morning', array['going']::text[], array[1]::smallint[]
  )$$,
  'PGRST', null, 'secondary guardian cannot submit a request'
);

reset role;
select set_config('request.jwt.claims', '{"sub":"60000000-0000-0000-0000-000000000003","role":"authenticated"}', true);
set local role authenticated;
select public.create_adult_student('Teste Adulto Request', (current_date - interval '18 years')::date, '18000000', 'Rua Adulto', '20', null, 'Centro', 'Teste', '3550000', 'SP', null, null);
select lives_ok(
  $$select public.submit_fleet_join_request(
    '61000000-0000-0000-0000-000000000001',
    (select id from public.students where full_name = 'Teste Adulto Request'),
    '63000000-0000-0000-0000-000000000001',
    'evening', array['return']::text[], array[2, 4]::smallint[]
  )$$,
  'adult student submits own request'
);

reset role;
select set_config('request.jwt.claims', '{"sub":"60000000-0000-0000-0000-000000000005","role":"authenticated"}', true);
set local role authenticated;
select is(
  (select count(*)::integer from public.list_fleet_join_requests('61000000-0000-0000-0000-000000000001', 'pending', 50, 0)),
  2,
  'owner lists pending requests for own fleet'
);
select is(
  (select street from public.list_fleet_join_requests('61000000-0000-0000-0000-000000000001', 'pending', 50, 0) where student_full_name = 'Teste Menor Request'),
  'Rua Menor',
  'owner projection includes address while request is pending'
);

reset role;
select set_config('request.jwt.claims', '{"sub":"60000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select lives_ok(
  $$select public.cancel_fleet_join_request((select id from public.fleet_join_requests where student_id = (select id from public.students where full_name = 'Teste Menor Request')))$$,
  'requester cancels pending request'
);
select is(
  (select status from public.fleet_join_requests where student_id = (select id from public.students where full_name = 'Teste Menor Request')),
  'cancelled',
  'request status becomes cancelled'
);

select * from finish();

rollback;
