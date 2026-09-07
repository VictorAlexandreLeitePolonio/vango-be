begin;

create extension if not exists pgtap with schema extensions;
\ir ../_helpers.psql

select plan(13);
select pg_temp.seed_foundation();

insert into public.schools (
  id, provider, external_id, institution_type, name, postal_code, street,
  street_number, neighborhood, city_name, city_ibge_code, state_code
) values (
  '70000000-0000-0000-0000-000000000001', 'inep', 'fixture-school', 'school',
  'Teste Escola Ativa', '18000000', 'Rua Escolar', '1', 'Centro',
  'Teste', '3550000', 'SP'
);

select set_config(
  'request.jwt.claims',
  '{"sub":"40000000-0000-0000-0000-000000000001","role":"authenticated"}',
  true
);
set local role authenticated;

select lives_ok(
  $$insert into public.fleet_service_cities (fleet_id, city_ibge_code, city_name, state_code, created_by)
    values ('41000000-0000-0000-0000-000000000001', '3550000', 'Teste', 'SP', '40000000-0000-0000-0000-000000000001')$$,
  'owner inserts own service city'
);
select lives_ok(
  $$insert into public.fleet_service_schools (fleet_id, school_id, created_by)
    values ('41000000-0000-0000-0000-000000000001', '70000000-0000-0000-0000-000000000001', '40000000-0000-0000-0000-000000000001')$$,
  'owner inserts own service school'
);
select is((select count(*)::integer from public.fleet_service_cities), 1, 'owner reads own city coverage');
select is((select count(*)::integer from public.fleet_service_schools), 1, 'owner reads own school coverage');

select throws_ok(
  $$insert into public.schools (provider, external_id, institution_type, name, postal_code, street, street_number, neighborhood, city_name, city_ibge_code, state_code)
    values ('inep', 'blocked', 'school', 'Blocked', '18000000', 'Rua', '1', 'Centro', 'Teste', '3550000', 'SP')$$,
  '42501', null, 'authenticated cannot write schools'
);
select throws_ok(
  $$insert into public.students (student_type, full_name, birth_date, postal_code, street, street_number, neighborhood, city_name, city_ibge_code, state_code, created_by)
    values ('minor', 'Blocked', '2018-01-01', '18000000', 'Rua', '1', 'Centro', 'Teste', '3550000', 'SP', '40000000-0000-0000-0000-000000000001')$$,
  '42501', null, 'authenticated cannot write students directly'
);
select throws_ok(
  $$insert into public.fleet_join_requests (fleet_id, requester_user_id, student_id, school_id, origin, shift, directions, weekdays, postal_code, street, street_number, neighborhood, city_name, city_ibge_code, state_code)
    values ('41000000-0000-0000-0000-000000000001', '40000000-0000-0000-0000-000000000001', '70000000-0000-0000-0000-000000000001', '70000000-0000-0000-0000-000000000001', 'marketplace', 'morning', array['going'], array[1]::smallint[], '18000000', 'Rua', '1', 'Centro', 'Teste', '3550000', 'SP')$$,
  '42501', null, 'authenticated cannot write join requests directly'
);

select throws_ok(
  $$insert into public.fleet_service_cities (fleet_id, city_ibge_code, city_name, state_code, created_by)
    values ('41000000-0000-0000-0000-000000000002', '3550000', 'Teste', 'SP', '40000000-0000-0000-0000-000000000001')$$,
  '42501', null, 'owner cannot insert coverage for another fleet'
);

select lives_ok(
  $$delete from public.fleet_service_schools
    where fleet_id = '41000000-0000-0000-0000-000000000001'
      and school_id = '70000000-0000-0000-0000-000000000001'$$,
  'owner removes own school coverage'
);

reset role;
select set_config('request.jwt.claims', '', true);
set local role anon;
select throws_ok(
  $$select count(*) from public.fleet_service_cities$$,
  '42501', null, 'anonymous cannot read coverage tables'
);

select ok(
  not has_table_privilege('authenticated', 'public.schools', 'select'),
  'authenticated has no direct schools privilege'
);
select ok(
  not has_table_privilege('anon', 'public.students', 'select'),
  'anonymous has no direct student privilege'
);

reset role;
select cmp_ok(
  (select count(*)::integer from public.fleet_membership_role_sources where source_type = 'manual'),
  '>=',
  5,
  'foundation memberships have manual role sources'
);

select * from finish();

rollback;
