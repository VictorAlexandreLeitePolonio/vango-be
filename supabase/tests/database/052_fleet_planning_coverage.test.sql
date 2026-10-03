begin;
create extension if not exists pgtap with schema extensions;
\ir ../_fleet_planning.psql
select no_plan();
select pg_temp.seed_fleet_transport();
-- Owner B has no city coverage; inserting a known school must fail at the database boundary.
select set_config('request.jwt.claims','{"sub":"40000000-0000-0000-0000-000000000005","role":"authenticated"}',true);
set local role authenticated;
select is(pg_temp.fleet_transport_error($q$insert into public.fleet_service_schools(fleet_id,school_id,created_by)
 values('41000000-0000-0000-0000-000000000002','65000000-0000-0000-0000-000000000001','40000000-0000-0000-0000-000000000005')$q$),
 'invalid_input','A school requires its municipality in the same fleet');
reset role;
select set_config('request.jwt.claims','{"sub":"40000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
set local role authenticated;
select is(pg_temp.fleet_transport_error($q$delete from public.fleet_service_cities where fleet_id='41000000-0000-0000-0000-000000000001'$q$), 'resource_in_use','Linked schools protect city removal');
reset role;
select has_table('private','school_publications','Publication evidence is separate from public institution data');
select has_table('public','catalog_municipalities','Authoritative municipality lookup exists');
delete from private.school_publications;
insert into public.fleet_service_cities(fleet_id,city_ibge_code,city_name,state_code,created_by)
 values('41000000-0000-0000-0000-000000000002','3550000','Cidade Teste','SP','40000000-0000-0000-0000-000000000005');
select set_config('request.jwt.claims','{"sub":"40000000-0000-0000-0000-000000000005","role":"authenticated"}',true);
set local role authenticated;
select is(pg_temp.fleet_transport_error($q$insert into public.fleet_service_schools(fleet_id,school_id,created_by)
 values('41000000-0000-0000-0000-000000000002','65000000-0000-0000-0000-000000000001','40000000-0000-0000-0000-000000000005')$q$), 'invalid_input','Unpublished coordinates cannot become selectable');
reset role;
delete from public.fleet_service_cities where fleet_id='41000000-0000-0000-0000-000000000002';
set local role authenticated;
select is(pg_temp.fleet_transport_error($q$insert into public.fleet_service_cities(fleet_id,city_ibge_code,city_name,state_code,created_by)
 values('41000000-0000-0000-0000-000000000002','3550000','Forged name','SP','40000000-0000-0000-0000-000000000005')$q$), 'invalid_input','Caller cannot forge authoritative municipality metadata');
reset role;
select is((select count(*)::integer from public.search_schools(null,'3550000',null,50,0)),0,'Search hides unpublished institutions');
select set_config('request.jwt.claims','{"sub":"40000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select is(pg_temp.fleet_transport_error(format('select public.save_route(%L,null,%L::jsonb)',fleet_id,
 jsonb_set(pg_temp.route_config((select id from planning_ids where kind='going-route')),'{schools}','[]'))), 'invalid_input','Legacy route writer rejects empty school lists') from transport_case;
select is((select count(*)::integer from public.list_fleet_service_schools('41000000-0000-0000-0000-000000000001')),0,'Registration selection also hides unpublished schools');
select * from finish();
rollback;
