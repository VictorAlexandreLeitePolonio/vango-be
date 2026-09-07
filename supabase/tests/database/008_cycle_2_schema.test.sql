begin;

create extension if not exists pgtap with schema extensions;
\ir ../_helpers.psql

select plan(22);

select has_table('public', 'schools', 'schools table exists');
select has_table('public', 'fleet_service_cities', 'fleet service cities table exists');
select has_table('public', 'fleet_service_schools', 'fleet service schools table exists');
select has_table('public', 'students', 'students table exists');
select has_table('public', 'student_guardians', 'student guardians table exists');
select has_table('public', 'student_guardian_invitations', 'guardian invitations table exists');
select has_table('public', 'fleet_invitations', 'fleet invitations table exists');
select has_table('public', 'fleet_join_requests', 'join requests table exists');
select has_table('public', 'fleet_enrollments', 'enrollments table exists');
select has_table('public', 'fleet_membership_role_sources', 'role sources table exists');

select is((select count(*)::integer from public.schools), 0, 'catalog starts empty');

select ok(
  exists (
    select 1 from pg_indexes
    where schemaname = 'public'
      and indexname = 'schools_provider_external_id_key'
  ),
  'school provider identity is unique'
);
select ok(
  exists (
    select 1 from pg_indexes
    where schemaname = 'public'
      and indexname = 'students_adult_profile_id_key'
  ),
  'adult profile identity is unique'
);
select ok(
  exists (
    select 1 from pg_indexes
    where schemaname = 'public'
      and indexname = 'student_guardians_one_primary_key'
  ),
  'one active primary guardian is enforced'
);
select ok(
  exists (
    select 1 from pg_indexes
    where schemaname = 'public'
      and indexname = 'fleet_join_requests_pending_student_fleet_key'
  ),
  'one pending request per student and fleet is indexed'
);
select ok(
  exists (
    select 1 from pg_indexes
    where schemaname = 'public'
      and indexname = 'fleet_enrollments_active_student_fleet_key'
  ),
  'one active enrollment per student and fleet is indexed'
);

select throws_ok(
  $$insert into public.schools (provider, external_id, institution_type, name, postal_code, street, street_number, neighborhood, city_name, city_ibge_code, state_code)
    values ('inep', 'bad', 'higher_education', 'Teste', '18000000', 'Rua A', '1', 'Centro', 'Teste', '3550000', 'SP')$$,
  '23514', null, 'provider and institution type must match'
);
select throws_ok(
  $$insert into public.schools (provider, external_id, institution_type, name, postal_code, street, street_number, neighborhood, city_name, city_ibge_code, state_code)
    values ('inep', 'bad-ibge', 'school', 'Teste', '18000000', 'Rua A', '1', 'Centro', 'Teste', '35500', 'SP')$$,
  '23514', null, 'city IBGE code must have seven digits'
);
select throws_ok(
  $$insert into public.schools (provider, external_id, institution_type, name, postal_code, street, street_number, neighborhood, city_name, city_ibge_code, state_code, latitude)
    values ('inep', 'bad-coordinates', 'school', 'Teste', '18000000', 'Rua A', '1', 'Centro', 'Teste', '3550000', 'SP', -23.5)$$,
  '23514', null, 'coordinates must be paired'
);

select ok(
  (select relrowsecurity from pg_class where oid = 'public.schools'::regclass),
  'schools has RLS enabled'
);
select ok(
  (select relrowsecurity from pg_class where oid = 'public.students'::regclass),
  'students has RLS enabled'
);
select ok(
  exists (select 1 from public.fleet_membership_role_sources where source_type = 'manual'),
  'manual role sources are available after foundation fixtures'
);

select * from finish();

rollback;
