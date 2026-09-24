begin;
create extension if not exists pgtap with schema extensions;
\ir ../_helpers.psql

select plan(65);
select has_column('public', 'fleet_enrollments', 'registration_command_id', 'owner registration has a command receipt');
select has_column('public', 'fleet_enrollments', 'registration_payload_hash', 'owner registration has a payload receipt');
select ok(exists (select 1 from pg_constraint where conname = 'fleet_enrollments_registration_receipt_valid'), 'source-specific receipt is constrained');
select ok(to_regclass('public.fleet_enrollments_registration_command_unique') is not null, 'command receipt is unique within fleet');
select ok(to_regprocedure('public.create_fleet_managed_student(uuid,uuid,text,text,date,text,text,text,text,text,text,text,text,numeric,numeric,uuid,text,text,text,text)') is not null, 'owner registration RPC exists');
select ok(to_regprocedure('public.list_fleet_students(uuid)') is not null, 'owner student list RPC exists');
select ok(has_function_privilege('authenticated', 'public.list_fleet_students(uuid)', 'EXECUTE'), 'authenticated may list');
select ok(not has_function_privilege('anon', 'public.list_fleet_students(uuid)', 'EXECUTE'), 'anonymous may not list');
select ok(has_function_privilege('authenticated', 'public.create_fleet_managed_student(uuid,uuid,text,text,date,text,text,text,text,text,text,text,text,numeric,numeric,uuid,text,text,text,text)', 'EXECUTE'), 'authenticated may register');
select ok(not has_function_privilege('anon', 'public.create_fleet_managed_student(uuid,uuid,text,text,date,text,text,text,text,text,text,text,text,numeric,numeric,uuid,text,text,text,text)', 'EXECUTE'), 'anonymous may not register');

select pg_temp.seed_cycle_2_users();
select pg_temp.seed_foundation();
insert into public.schools (
  id, provider, external_id, institution_type, name, postal_code, street,
  street_number, neighborhood, city_name, city_ibge_code, state_code
) values (
  '63000000-0000-0000-0000-000000000010', 'inep', 'prd10-school', 'school',
  'PRD10 School', '18000000', 'Main Street', '1', 'Center', 'Test City', '3550000', 'SP'
);
insert into public.fleet_service_schools(fleet_id, school_id, created_by)
values ('41000000-0000-0000-0000-000000000001', '63000000-0000-0000-0000-000000000010', '40000000-0000-0000-0000-000000000001');
create temp table prd10_result(student_id uuid, enrollment_id uuid) on commit drop;
grant all on prd10_result to authenticated;
select set_config('request.jwt.claims', '{"sub":"40000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
set local role authenticated;
insert into prd10_result
select * from public.create_fleet_managed_student(
  '41000000-0000-0000-0000-000000000001', '90000000-0000-0000-0000-000000000010',
  'minor', '  PRD10 Minor  ', '2015-02-03', '18000000', 'Main Street', '10',
  '', 'Center', 'Test City', '3550000', 'SP', -90, 180,
  '63000000-0000-0000-0000-000000000010', 'morning',
  'Primary Contact', 'PARENT@EXAMPLE.COM', null
);
select is((select count(*)::integer from prd10_result), 1, 'owner registers one student');
reset role;
select is((select registration_origin from public.students where id = (select student_id from prd10_result)), 'fleet_owner_created', 'student origin is owner-created');
select is((select profile_id from public.students where id = (select student_id from prd10_result)), null::uuid, 'owner-created student has no profile');
select is((select latitude from public.students where id = (select student_id from prd10_result)), -90::numeric, 'latitude boundary persists');
select is((select longitude from public.students where id = (select student_id from prd10_result)), 180::numeric, 'longitude boundary persists');
select is((select contact_type from public.fleet_student_contacts where enrollment_id = (select enrollment_id from prd10_result)), 'guardian', 'minor receives guardian contact');
select is((select count(*)::integer from public.audit_events where action = 'fleet_student_registered' and entity_id = (select student_id from prd10_result)), 1, 'registration has one audit event');
set local role authenticated;
select is((select student_id from public.create_fleet_managed_student(
  '41000000-0000-0000-0000-000000000001', '90000000-0000-0000-0000-000000000010',
  'minor', 'PRD10 Minor', '2015-02-03', '18000000', 'Main Street', '10',
  null, 'Center', 'Test City', '3550000', 'SP', -90, 180,
  '63000000-0000-0000-0000-000000000010', 'morning',
  'Primary Contact', 'parent@example.com', null
)), (select student_id from prd10_result), 'canonical replay returns original student');
reset role;
select is((select count(*)::integer from public.fleet_enrollments where registration_command_id = '90000000-0000-0000-0000-000000000010'), 1, 'replay leaves one enrollment');
set local role authenticated;
select is((select full_name from public.list_fleet_students('41000000-0000-0000-0000-000000000001') where student_id = (select student_id from prd10_result)), 'PRD10 Minor', 'owner list returns active student');
select throws_ok($$select * from public.list_fleet_students('41000000-0000-0000-0000-000000000002')$$, 'PGRST', null, 'other fleet list is hidden');
reset role;
create function pg_temp.register_prd10(
  p_command uuid, p_name text default 'PRD10 Minor', p_lat numeric default -90,
  p_lon numeric default 180, p_shift text default 'morning',
  p_school uuid default '63000000-0000-0000-0000-000000000010',
  p_type text default 'minor', p_birth date default '2015-02-03',
  p_contact text default 'Primary Contact'
) returns table(student_id uuid, enrollment_id uuid)
language sql
as $body$
  select * from public.create_fleet_managed_student(
    '41000000-0000-0000-0000-000000000001', p_command, p_type, p_name,
    p_birth, '18000000', 'Main Street', '10', null, 'Center', 'Test City',
    '3550000', 'SP', p_lat, p_lon, p_school, p_shift,
    p_contact, 'parent@example.com', null
  );
$body$;
create function pg_temp.prd10_error(p_sql text) returns text
language plpgsql as $body$
begin
  execute p_sql;
  return null;
exception when sqlstate 'PGRST' then
  return sqlerrm::jsonb->>'code';
end;
$body$;
grant execute on function pg_temp.register_prd10(uuid,text,numeric,numeric,text,uuid,text,date,text) to authenticated;
grant execute on function pg_temp.prd10_error(text) to authenticated;
set local role authenticated;
select is(pg_temp.prd10_error($$select * from pg_temp.register_prd10('90000000-0000-0000-0000-000000000010', 'Changed Name')$$), 'idempotency_conflict', 'changed payload conflicts');
select is(pg_temp.prd10_error($$select * from pg_temp.register_prd10('90000000-0000-0000-0000-000000000011', p_lat => null)$$), 'invalid_input', 'missing latitude is rejected');
select is(pg_temp.prd10_error($$select * from pg_temp.register_prd10('90000000-0000-0000-0000-000000000011', p_lat => 91)$$), 'invalid_input', 'out-of-range latitude is rejected');
select is(pg_temp.prd10_error($$select * from pg_temp.register_prd10('90000000-0000-0000-0000-000000000011', p_lon => 'NaN'::numeric)$$), 'invalid_input', 'non-finite longitude is rejected');
select is(pg_temp.prd10_error($$select * from pg_temp.register_prd10('90000000-0000-0000-0000-000000000011', p_shift => 'invalid')$$), 'invalid_input', 'unsupported shift is rejected');
select is(pg_temp.prd10_error($$select * from pg_temp.register_prd10('90000000-0000-0000-0000-000000000011', p_school => '63000000-0000-0000-0000-000000000011')$$), 'invalid_input', 'uncovered school is rejected');
select is(pg_temp.prd10_error($$select * from pg_temp.register_prd10('90000000-0000-0000-0000-000000000011', p_type => 'adult')$$), 'invalid_input', 'age and type mismatch is rejected');
select is(pg_temp.prd10_error($$select * from pg_temp.register_prd10('90000000-0000-0000-0000-000000000011', p_contact => '')$$), 'invalid_input', 'blank contact name is rejected');
reset role;
select is((select count(*)::integer from public.students where full_name = 'PRD10 Minor'), 1, 'invalid calls left no student');
select is((select count(*)::integer from public.fleet_student_contacts where enrollment_id = (select enrollment_id from prd10_result)), 1, 'replay left one contact');
select is((select count(*)::integer from public.audit_events where entity_id = (select student_id from prd10_result) and action = 'fleet_student_registered'), 1, 'replay left one audit event');
set local role authenticated;
select ok(not exists (
  select 1 from public.list_fleet_students('41000000-0000-0000-0000-000000000001') row_data
  cross join lateral jsonb_object_keys(to_jsonb(row_data)) exposed(key)
  where exposed.key = any(array['profile_id','email','phone','latitude','longitude','registration_command_id','registration_payload_hash'])
), 'list projection excludes private fields');
select ok((select to_jsonb(row_data) ?& array['enrollment_id','student_id','student_type','full_name','postal_code','street','street_number','address_complement','neighborhood','city_name','state_code','school_id','school_name','shift']
  from public.list_fleet_students('41000000-0000-0000-0000-000000000001') row_data limit 1), 'list includes every approved field');
select is((select count(*)::integer from public.list_fleet_students('41000000-0000-0000-0000-000000000001') row_data
  cross join lateral jsonb_object_keys(to_jsonb(row_data)) exposed(key)
  where row_data.student_id = (select student_id from prd10_result)), 14, 'list returns exactly fourteen fields');
select set_config('request.jwt.claims', '{"sub":"40000000-0000-0000-0000-000000000002","role":"authenticated"}', true);
select is(pg_temp.prd10_error($$select * from pg_temp.register_prd10('90000000-0000-0000-0000-000000000010')$$), 'idempotency_conflict', 'another owner cannot replay the command');
select set_config('request.jwt.claims', '{"sub":"40000000-0000-0000-0000-000000000003","role":"authenticated"}', true);
select is(pg_temp.prd10_error($$select * from pg_temp.register_prd10('90000000-0000-0000-0000-000000000012')$$), 'forbidden', 'driver cannot register');
select set_config('request.jwt.claims', '{"sub":"40000000-0000-0000-0000-000000000005","role":"authenticated"}', true);
select is(pg_temp.prd10_error($$select * from pg_temp.register_prd10('90000000-0000-0000-0000-000000000012')$$), 'forbidden', 'owner from another fleet cannot register');
select set_config('request.jwt.claims', '{"sub":"60000000-0000-0000-0000-000000000004","role":"authenticated"}', true);
select is(pg_temp.prd10_error($$select * from pg_temp.register_prd10('90000000-0000-0000-0000-000000000012')$$), 'email_unverified', 'unconfirmed user cannot register');
select set_config('request.jwt.claims', '{"sub":"40000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select is(pg_temp.prd10_error($$select * from public.list_fleet_students('41000000-0000-0000-0000-000000000099')$$), 'not_found', 'missing fleet is hidden');
reset role;
select throws_ok($$update public.fleet_enrollments set registration_command_id = '90000000-0000-0000-0000-000000000099' where id = (select enrollment_id from prd10_result)$$, '23514', null, 'receipt command cannot change');
select throws_ok($$update public.fleet_enrollments set registration_payload_hash = extensions.digest('changed', 'sha256') where id = (select enrollment_id from prd10_result)$$, '23514', null, 'receipt hash cannot change');
create function pg_temp.fail_prd10_audit() returns trigger language plpgsql as $body$
begin
  if new.action = 'fleet_student_registered' then
    raise exception 'controlled audit failure';
  end if;
  return new;
end;
$body$;
create trigger prd10_audit_failure before insert on public.audit_events
for each row execute function pg_temp.fail_prd10_audit();
set local role authenticated;
select is(pg_temp.prd10_error($$select * from pg_temp.register_prd10('90000000-0000-0000-0000-000000000013', 'Rollback Student')$$), 'registration_failed', 'audit failure returns sanitized error');
reset role;
drop trigger prd10_audit_failure on public.audit_events;
select is((select count(*)::integer from public.students where full_name = 'Rollback Student'), 0, 'audit failure rolls back student');
select is((select count(*)::integer from public.fleet_enrollments where registration_command_id = '90000000-0000-0000-0000-000000000013'), 0, 'audit failure rolls back enrollment');
select is((select count(*)::integer from public.fleet_student_contacts where fleet_id = '41000000-0000-0000-0000-000000000001'), 1, 'audit failure rolls back contact');
select is((select count(*)::integer from public.audit_events where action = 'fleet_student_registered' and fleet_id = '41000000-0000-0000-0000-000000000001'), 1, 'audit failure adds no event');
update public.fleet_enrollments set status = 'ended', ended_at = now(),
  ended_by = '40000000-0000-0000-0000-000000000001', end_reason = 'Test end'
where id = (select enrollment_id from prd10_result);
set local role authenticated;
select is((select count(*)::integer from public.list_fleet_students('41000000-0000-0000-0000-000000000001') where student_id = (select student_id from prd10_result)), 0, 'ended enrollment is absent from list');
select ok((select student_id from pg_temp.register_prd10('90000000-0000-0000-0000-000000000014')) <> (select student_id from prd10_result), 'new command creates a distinct logical student');
create temp table prd10_adult as
select * from pg_temp.register_prd10(
  '90000000-0000-0000-0000-000000000015', 'PRD10 Adult',
  p_type => 'adult', p_birth => '2000-01-01'
);
reset role;
select is((select contact_type from public.fleet_student_contacts where enrollment_id = (select enrollment_id from prd10_adult)), 'student', 'adult receives student contact');
select is((select profile_id from public.students where id = (select student_id from prd10_adult)), null::uuid, 'adult owner registration has no profile');
select is((select count(*)::integer from public.student_guardians where student_id in (select student_id from prd10_result union select student_id from prd10_adult)), 0, 'owner registration creates no guardian links');
select is((select count(*)::integer from public.fleet_join_requests where student_id in (select student_id from prd10_result union select student_id from prd10_adult)), 0, 'owner registration creates no join requests');
select is((select metadata ?| array['full_name','birth_date','street','latitude','longitude','email','phone','registration_payload_hash'] from public.audit_events where entity_id = (select student_id from prd10_adult) and action = 'fleet_student_registered'), false, 'audit metadata excludes personal data');
select is((select count(*)::integer from public.fleet_enrollments where fleet_id = '41000000-0000-0000-0000-000000000001' and source_type = 'owner_registration' and registration_command_id in ('90000000-0000-0000-0000-000000000014','90000000-0000-0000-0000-000000000015')), 2, 'both new commands have receipts');
set local role authenticated;
select is((select count(*)::integer from public.list_fleet_students('41000000-0000-0000-0000-000000000001') where student_id = (select student_id from prd10_adult)), 1, 'owner list includes adult');
select is((select count(*)::integer from public.list_fleet_students('41000000-0000-0000-0000-000000000001') where student_id = (select student_id from prd10_result)), 0, 'owner list still excludes ended student');
reset role;
insert into public.students (
  id, student_type, registration_origin, full_name, birth_date, postal_code,
  street, street_number, neighborhood, city_name, city_ibge_code, state_code, created_by
) values (
  '81000000-0000-0000-0000-000000000010', 'minor', 'guardian_created', 'aaa',
  '2014-01-01', '18000000', 'Main Street', '20', 'Center', 'Test City',
  '3550000', 'SP', '40000000-0000-0000-0000-000000000004'
);
insert into public.fleet_join_requests (
  id, fleet_id, requester_user_id, student_id, school_id, origin, shift,
  directions, weekdays, postal_code, street, street_number, neighborhood,
  city_name, city_ibge_code, state_code
) values (
  '82000000-0000-0000-0000-000000000010',
  '41000000-0000-0000-0000-000000000001',
  '40000000-0000-0000-0000-000000000004',
  '81000000-0000-0000-0000-000000000010',
  '63000000-0000-0000-0000-000000000010', 'marketplace', 'morning',
  array['going'], array[1]::smallint[], '18000000', 'Main Street', '20',
  'Center', 'Test City', '3550000', 'SP'
);
insert into public.fleet_enrollments (
  fleet_id, student_id, source_type, source_request_id, school_id, shift
) values (
  '41000000-0000-0000-0000-000000000001',
  '81000000-0000-0000-0000-000000000010', 'join_request',
  '82000000-0000-0000-0000-000000000010',
  '63000000-0000-0000-0000-000000000010', 'morning'
);
set local role authenticated;
select is((select count(*)::integer from public.list_fleet_students('41000000-0000-0000-0000-000000000001') where student_id = '81000000-0000-0000-0000-000000000010'), 1, 'owner list includes join-request enrollment');
select is((select student_id from public.list_fleet_students('41000000-0000-0000-0000-000000000001') limit 1), '81000000-0000-0000-0000-000000000010'::uuid, 'list orders names case-insensitively');
select is((select count(*)::integer from public.list_fleet_students('41000000-0000-0000-0000-000000000001') where student_id = (select student_id from prd10_adult)), 1, 'list includes both enrollment origins');
reset role;
select is((select count(*)::integer from public.fleet_enrollments where source_request_id = '82000000-0000-0000-0000-000000000010' and registration_command_id is null and registration_payload_hash is null), 1, 'join-request receipt fields remain null');
set local role authenticated;
select student_id from pg_temp.register_prd10('90000000-0000-0000-0000-000000000016', 'AAA');
reset role;
create temp table prd10_expected_order as
select array_agg(id order by id) ids from public.students where lower(full_name) = 'aaa';
grant select on prd10_expected_order to authenticated;
set local role authenticated;
select is(
  (select array_agg(student_id order by ordinality) from public.list_fleet_students('41000000-0000-0000-0000-000000000001') with ordinality listed(enrollment_id,student_id,student_type,full_name,postal_code,street,street_number,address_complement,neighborhood,city_name,state_code,school_id,school_name,shift,ordinality) where lower(full_name) = 'aaa'),
  (select ids from prd10_expected_order),
  'case-fold-equal names use student ID as tie-breaker'
);
reset role;
select throws_ok($$insert into public.fleet_enrollments(fleet_id,student_id,source_type,school_id,shift)
  values ('41000000-0000-0000-0000-000000000001',
  (select student_id from prd10_result),'owner_registration',
  '63000000-0000-0000-0000-000000000010','morning')$$,
  '23514', null, 'owner registration requires a receipt');
select throws_ok($$insert into public.fleet_enrollments(fleet_id,student_id,source_type,source_request_id,school_id,shift,registration_command_id,registration_payload_hash)
  values ('41000000-0000-0000-0000-000000000001',
  (select student_id from prd10_result),'join_request',
  '82000000-0000-0000-0000-000000000010',
  '63000000-0000-0000-0000-000000000010','morning',
  '90000000-0000-0000-0000-000000000099',extensions.digest('invalid', 'sha256'))$$,
  '23514', null, 'join-request enrollment rejects owner receipt');
select throws_ok($$insert into public.fleet_enrollments(fleet_id,student_id,source_type,school_id,shift,registration_command_id,registration_payload_hash)
  values ('41000000-0000-0000-0000-000000000001',
  (select student_id from prd10_result),'owner_registration',
  '63000000-0000-0000-0000-000000000010','morning',
  '90000000-0000-0000-0000-000000000010',extensions.digest('duplicate', 'sha256'))$$,
  '23505', null, 'same-fleet command receipt is unique');
delete from public.fleet_service_schools
where fleet_id = '41000000-0000-0000-0000-000000000001'
  and school_id = '63000000-0000-0000-0000-000000000010';
set local role authenticated;
select is(
  (select student_id from pg_temp.register_prd10('90000000-0000-0000-0000-000000000010')),
  (select student_id from prd10_result),
  'replay succeeds after school coverage is removed'
);
select * from finish();
rollback;
