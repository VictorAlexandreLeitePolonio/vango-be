begin;
create extension if not exists pgtap with schema extensions;
\ir ../_helpers.psql
select no_plan();
select pg_temp.seed_cycle_2_users();
select pg_temp.seed_foundation();
insert into public.schools(id,provider,external_id,institution_type,name,postal_code,street,street_number,neighborhood,city_name,city_ibge_code,state_code,status)
values
('63000000-0000-0000-0000-000000000021','inep','coverage-a','school','alpha','18000000','Main','1','Center','Other City','3550308','SP','active'),
('63000000-0000-0000-0000-000000000022','inep','coverage-b','school','Alpha','18000000','Main','1','Center','Other City','3550308','SP','active'),
('63000000-0000-0000-0000-000000000023','inep','coverage-c','school','Inactive','18000000','Main','1','Center','Other City','3550308','SP','inactive'),
('63000000-0000-0000-0000-000000000024','inep','coverage-d','school','Uncovered','18000000','Main','1','Center','Other City','3550308','SP','active');
insert into public.fleet_service_schools(fleet_id,school_id,created_by)
select '41000000-0000-0000-0000-000000000001', id, '40000000-0000-0000-0000-000000000001'
from public.schools where external_id in ('coverage-a','coverage-b','coverage-c');
create function pg_temp.coverage_error(p_sql text) returns text language plpgsql as $$
begin
 execute p_sql;
 return null;
exception when sqlstate 'PGRST' then return sqlerrm::jsonb->>'code';
 when undefined_function then return 'missing_rpc';
end;
$$;
select set_config('request.jwt.claims','{"sub":"40000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
set local role authenticated;
select is(pg_temp.coverage_error($$select * from public.list_fleet_service_schools('41000000-0000-0000-0000-000000000001')$$),null::text,'owner can read school options for an unpublished fleet');


select is((select array_agg(id) from public.list_fleet_service_schools('41000000-0000-0000-0000-000000000001')), array['63000000-0000-0000-0000-000000000021'::uuid,'63000000-0000-0000-0000-000000000022'::uuid], 'active covered schools in another city are ordered by name then ID');
select is((select count(*)::integer from public.list_fleet_service_schools('41000000-0000-0000-0000-000000000001') r cross join lateral jsonb_object_keys(to_jsonb(r)) k),4,'school projection has exactly ID and name');
select throws_ok('select * from public.schools','42501',null,'school table remains restricted');
select is(pg_temp.coverage_error($$select * from public.list_fleet_service_schools('41000000-0000-0000-0000-000000000099')$$),'not_found','missing fleet is hidden');
select set_config('request.jwt.claims','{"sub":"40000000-0000-0000-0000-000000000005","role":"authenticated"}',true);
select is(pg_temp.coverage_error($$select * from public.list_fleet_service_schools('41000000-0000-0000-0000-000000000001')$$),'not_found','other owner cannot read options');
select set_config('request.jwt.claims','{"sub":"40000000-0000-0000-0000-000000000003","role":"authenticated"}',true);
select is(pg_temp.coverage_error($$select * from public.list_fleet_service_schools('41000000-0000-0000-0000-000000000001')$$),'not_found','driver cannot read options');
select set_config('request.jwt.claims','{"sub":"60000000-0000-0000-0000-000000000004","role":"authenticated"}',true);
select is(pg_temp.coverage_error($$select * from public.list_fleet_service_schools('41000000-0000-0000-0000-000000000001')$$),'email_unverified','unconfirmed user cannot read options');
reset role;
select ok(not has_function_privilege('anon','public.list_fleet_service_schools(uuid)','EXECUTE'),'anonymous has no execute privilege');
insert into public.fleet_service_cities(fleet_id,city_ibge_code,city_name,state_code,created_by) values
('41000000-0000-0000-0000-000000000001','3550000','Test City','SP','40000000-0000-0000-0000-000000000001'),
('41000000-0000-0000-0000-000000000002','3550308','Other City','SP','40000000-0000-0000-0000-000000000005');
create function pg_temp.register_coverage(p_command uuid default '92000000-0000-0000-0000-000000000001',p_city text default 'Test City',p_ibge text default '3550000',p_state text default 'SP')
returns table(student_id uuid,enrollment_id uuid) language sql as $$
select * from public.create_fleet_managed_student('41000000-0000-0000-0000-000000000001',p_command,'minor','Coverage Student','2015-01-01','18000000','Main','1',null,'Center',p_city,p_ibge,p_state,-23.5,-47.5,'63000000-0000-0000-0000-000000000021','morning','Contact','contact@example.test',null);
$$;
create temp table coverage_counts as select
(select count(*) from public.students) students,
(select count(*) from public.fleet_enrollments) enrollments,
(select count(*) from public.fleet_student_contacts) contacts,
(select count(*) from public.audit_events where action='fleet_student_registered') audits;
select set_config('request.jwt.claims','{"sub":"40000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
set local role authenticated;
select is(pg_temp.coverage_error($$select * from pg_temp.register_coverage(p_city=>'Other City',p_ibge=>'3550308')$$),'invalid_input','city covered only by another fleet is rejected');
reset role;
select is((select count(*) from public.students),(select students from coverage_counts),'rejection creates no student');
select is((select count(*) from public.fleet_enrollments),(select enrollments from coverage_counts),'rejection creates no enrollment');
select is((select count(*) from public.fleet_student_contacts),(select contacts from coverage_counts),'rejection creates no contact');
select is((select count(*) from public.audit_events where action='fleet_student_registered'),(select audits from coverage_counts),'rejection creates no audit');

set local role authenticated;
select is(pg_temp.coverage_error($$select * from pg_temp.register_coverage(p_ibge=>'9999999')$$),'invalid_input','absent city is rejected');
select is(pg_temp.coverage_error($$select * from pg_temp.register_coverage(p_city=>'Wrong City')$$),'invalid_input','wrong city name is rejected');
select is(pg_temp.coverage_error($$select * from pg_temp.register_coverage(p_state=>'RJ')$$),'invalid_input','wrong UF is rejected');
select is(pg_temp.coverage_error($$select * from pg_temp.register_coverage(p_city=>null)$$),'invalid_input','null city is rejected');
select is(pg_temp.coverage_error($$select * from pg_temp.register_coverage(p_ibge=>null)$$),'invalid_input','null IBGE is rejected');
select is(pg_temp.coverage_error($$select * from pg_temp.register_coverage(p_state=>null)$$),'invalid_input','null UF is rejected');
select is(pg_temp.coverage_error($$select * from pg_temp.register_coverage(p_ibge=>'bad')$$),'invalid_input','malformed IBGE is rejected');
select is(pg_temp.coverage_error($$select * from pg_temp.register_coverage(p_state=>'sP')$$),'invalid_input','existing uppercase UF validation is rejected');
create temp table coverage_receipt as select * from pg_temp.register_coverage();
select is((select count(*)::integer from coverage_receipt),1,'covered city registers without fleet publication');
select is((select student_id from pg_temp.register_coverage(p_city=>'  Test City  ')),(select student_id from coverage_receipt),'canonical trim replay keeps the original receipt');
select is(pg_temp.coverage_error($$select * from pg_temp.register_coverage(p_city=>'test city')$$),'idempotency_conflict','city case changes preserve the original payload hash contract');
select lives_ok($$select * from pg_temp.register_coverage('92000000-0000-0000-0000-000000000002',p_city=>'  test CITY  ')$$,'new city comparison trims and folds case');
reset role;
delete from public.fleet_service_cities where fleet_id='41000000-0000-0000-0000-000000000001';
set local role authenticated;
select is(pg_temp.coverage_error($$select * from pg_temp.register_coverage('92000000-0000-0000-0000-000000000003')$$),'invalid_input','new command fails after city coverage removal');
select is((select student_id from pg_temp.register_coverage()),(select student_id from coverage_receipt),'replay succeeds after city coverage removal');
reset role;
delete from public.fleet_service_schools where fleet_id='41000000-0000-0000-0000-000000000001';
set local role authenticated;
select is((select count(*)::integer from public.list_fleet_service_schools('41000000-0000-0000-0000-000000000001')),0,'authorized owner receives empty options after coverage removal');
select is((select student_id from pg_temp.register_coverage()),(select student_id from coverage_receipt),'replay succeeds after school coverage removal');
reset role;
update public.fleet_enrollments set status='ended',ended_at=now(),ended_by='40000000-0000-0000-0000-000000000001',end_reason='Coverage test' where id=(select enrollment_id from coverage_receipt);
set local role authenticated;
select is((select enrollment_id from pg_temp.register_coverage()),(select enrollment_id from coverage_receipt),'ended enrollment receipt is replayable');
reset role;
select is((select status from public.fleet_enrollments where id=(select enrollment_id from coverage_receipt)),'ended','replay does not reactivate enrollment');
update public.fleet_memberships set status='suspended',suspended_at=now() where id='42000000-0000-0000-0000-000000000001';
set local role authenticated;
select is(pg_temp.coverage_error($$select * from pg_temp.register_coverage()$$),'forbidden','revoked owner cannot replay');
select is(pg_temp.coverage_error($$select * from public.list_fleet_service_schools('41000000-0000-0000-0000-000000000001')$$),'not_found','inactive owner cannot read options');
select set_config('request.jwt.claims','{}',true);
select is(pg_temp.coverage_error($$select * from public.list_fleet_service_schools('41000000-0000-0000-0000-000000000001')$$),'unauthenticated','missing user is rejected internally');
reset role;
create function pg_temp.api_error_detail() returns jsonb language plpgsql as $$
declare v_detail text;
begin
 perform private.raise_api_error('not_found','Fleet not found',404);
 return null;
exception when sqlstate 'PGRST' then
 get stacked diagnostics v_detail = pg_exception_detail;
 return v_detail::jsonb;
end;
$$;
select is(pg_temp.api_error_detail(),'{"status":404,"headers":{}}'::jsonb,'domain error detail meets the PostgREST custom-error contract');
select * from finish();
rollback;
