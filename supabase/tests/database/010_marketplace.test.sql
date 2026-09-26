begin;

create extension if not exists pgtap with schema extensions;
\ir ../_helpers.psql

select plan(13);
select pg_temp.seed_foundation();

update public.fleets set status = 'published' where id = '41000000-0000-0000-0000-000000000001';
insert into public.schools (
  id, provider, external_id, institution_type, name, postal_code, street,
  street_number, neighborhood, city_name, city_ibge_code, state_code, status
) values
  ('70000000-0000-0000-0000-000000000001', 'inep', 'market-school', 'school', 'Escola São João', '18000000', 'Rua A', '1', 'Centro', 'Teste', '3550000', 'SP', 'active'),
  ('70000000-0000-0000-0000-000000000002', 'emec', 'market-college', 'higher_education', 'Faculdade Teste', '18000000', 'Rua B', '2', 'Centro', 'Teste', '3550000', 'SP', 'active'),
  ('70000000-0000-0000-0000-000000000003', 'inep', 'market-inactive', 'school', 'Escola Inativa', '18000000', 'Rua C', '3', 'Centro', 'Teste', '3550000', 'SP', 'inactive');

select set_config(
  'request.jwt.claims',
  '{"sub":"40000000-0000-0000-0000-000000000001","role":"authenticated"}',
  true
);
set local role authenticated;

insert into public.fleet_service_cities (fleet_id, city_ibge_code, city_name, state_code, created_by)
values ('41000000-0000-0000-0000-000000000001', '3550000', 'Teste', 'SP', '40000000-0000-0000-0000-000000000001');
insert into public.fleet_service_schools (fleet_id, school_id, created_by)
values ('41000000-0000-0000-0000-000000000001', '70000000-0000-0000-0000-000000000001', '40000000-0000-0000-0000-000000000001');

reset role;
select set_config('request.jwt.claims', '', true);
set local role anon;

select is(
  (select count(*)::integer from public.search_schools('sao joao', '3550000', 'school', 50, 0)),
  1,
  'anonymous search tolerates accents and returns active schools'
);
select is(
  (select name from public.search_schools(null, '3550000', 'higher_education', 50, 0) limit 1),
  'Faculdade Teste',
  'institution type and city filter are applied'
);
select is(
  (select count(*)::integer from public.search_schools('inativa', '3550000', null, 50, 0)),
  0,
  'inactive schools are hidden'
);
select throws_ok(
  $$select * from public.search_schools(null, null, null, 50, 0)$$,
  'PGRST', null, 'search requires a query or city'
);
select throws_ok(
  $$select * from public.search_schools('teste', 'bad', null, 50, 0)$$,
  'PGRST', null, 'invalid city filter is rejected'
);
select throws_ok(
  $$select * from public.search_schools('teste', '3550000', null, 0, 0)$$,
  'PGRST', null, 'invalid pagination is rejected'
);
select is(
  (select count(*)::integer from public.search_marketplace('3550000', '70000000-0000-0000-0000-000000000001', 50, 0)),
  1,
  'marketplace returns published fleets with city and school coverage'
);
select is(
  (select count(*)::integer from public.search_marketplace('3550000', '70000000-0000-0000-0000-000000000002', 50, 0)),
  0,
  'marketplace requires institution coverage'
);
select is(
  (select count(*)::integer from public.search_marketplace('3550001', '70000000-0000-0000-0000-000000000001', 50, 0)),
  0,
  'marketplace filters by city coverage'
);
select throws_ok(
  $$select * from public.search_marketplace('bad', null, 50, 0)$$,
  'PGRST', null, 'invalid marketplace city is rejected'
);

reset role;
select is(
  (select count(*)::integer from public.audit_events where action = 'service_city_added' and fleet_id = '41000000-0000-0000-0000-000000000001'),
  1,
  'service city insertion is audited'
);
select is(
  (select count(*)::integer from public.audit_events where action = 'service_school_added' and fleet_id = '41000000-0000-0000-0000-000000000001'),
  1,
  'service school insertion is audited'
);
select ok(
  not exists (
    select 1 from public.audit_events
    where action in ('service_city_added', 'service_school_added')
      and metadata ?| array['email', 'street', 'latitude', 'longitude']
  ),
  'coverage audit is sanitized'
);

select * from finish();

rollback;
