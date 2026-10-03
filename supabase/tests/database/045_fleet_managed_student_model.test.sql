begin;

create extension if not exists pgtap with schema extensions;
\ir ../_helpers.psql

select plan(66);
select pg_temp.seed_cycle_2_users();
select pg_temp.seed_foundation();
insert into public.fleet_memberships (id, fleet_id, user_id)
values (
  '42000000-0000-0000-0000-000000000006',
  '41000000-0000-0000-0000-000000000002',
  '60000000-0000-0000-0000-000000000003'
);
insert into public.fleet_membership_roles (membership_id, role)
values ('42000000-0000-0000-0000-000000000006', 'student');
create temp table prd9_test_ids(kind text primary key, id uuid) on commit drop;
grant all on prd9_test_ids to authenticated;

update public.fleets
set status = 'published'
where id = '41000000-0000-0000-0000-000000000001';
insert into public.schools (
  id, provider, external_id, institution_type, name, postal_code, street,
  street_number, neighborhood, city_name, city_ibge_code, state_code
) values (
  '63000000-0000-0000-0000-000000000001', 'inep', 'prd9-school', 'school',
  'PRD9 Test School', '18000000', 'Main Street', '1', 'Center', 'Test City',
  '3550000', 'SP'
);
insert into public.fleet_service_cities (fleet_id, city_ibge_code, city_name, state_code, created_by)
values ('41000000-0000-0000-0000-000000000001', '3550000', 'Test City', 'SP', '40000000-0000-0000-0000-000000000001');
insert into public.fleet_service_schools (fleet_id, school_id, created_by)
values ('41000000-0000-0000-0000-000000000001', '63000000-0000-0000-0000-000000000001', '40000000-0000-0000-0000-000000000001');

select set_config(
  'request.jwt.claims',
  '{"sub":"60000000-0000-0000-0000-000000000001","role":"authenticated"}',
  true
);
set local role authenticated;

select lives_ok(
  $$select public.create_minor_student(
    'PRD9 Minor', '2015-02-03', '18000000', 'Main Street', '10', null,
    'Center', 'Test City', '3550000', 'SP', null, null
  )$$,
  'guardian creates a minor student'
);
select is(
  (select registration_origin from public.students where full_name = 'PRD9 Minor'),
  'guardian_created',
  'guardian-created minor records its origin'
);
select is(
  (select profile_id from public.students where full_name = 'PRD9 Minor'),
  null::uuid,
  'guardian-created minor has no student profile'
);

reset role;
select set_config(
  'request.jwt.claims',
  '{"sub":"60000000-0000-0000-0000-000000000003","role":"authenticated"}',
  true
);
set local role authenticated;

select lives_ok(
  $$select public.create_adult_student(
    'PRD9 Adult', (current_date - interval '18 years')::date,
    '18000000', 'Main Street', '20', null, 'Center', 'Test City',
    '3550000', 'SP', null, null
  )$$,
  'adult creates a student profile'
);
select is(
  (select registration_origin from public.students where full_name = 'PRD9 Adult'),
  'self_created',
  'self-created adult records its origin'
);
select is(
  (select profile_id from public.students where full_name = 'PRD9 Adult'),
  '60000000-0000-0000-0000-000000000003'::uuid,
  'self-created adult is linked to the authenticated profile'
);

reset role;
select set_config(
  'request.jwt.claims',
  '{"sub":"60000000-0000-0000-0000-000000000002","role":"authenticated"}',
  true
);
set local role authenticated;
select public.create_minor_student(
  'PRD9 Secondary Minor', '2014-03-04', '18000000', 'Main Street', '70', null,
  'Center', 'Test City', '3550000', 'SP', null, null
);
insert into prd9_test_ids(kind, id)
select 'second-request', public.submit_fleet_join_request(
  '41000000-0000-0000-0000-000000000001',
  (select id from public.students where full_name = 'PRD9 Secondary Minor'),
  '63000000-0000-0000-0000-000000000001', 'morning',
  array['going']::text[], array[1]::smallint[]
);
reset role;
select lives_ok(
  $$insert into public.students (
    student_type, registration_origin, full_name, birth_date, postal_code,
    street, street_number, neighborhood, city_name, city_ibge_code,
    state_code, created_by
  ) values (
    'minor', 'fleet_owner_created', 'PRD9 Owner Minor', '2015-01-01',
    '18000000', 'Main Street', '30', 'Center', 'Test City', '3550000', 'SP',
    '60000000-0000-0000-0000-000000000005'
  )$$,
  'fleet owner can register a minor without an account'
);
select lives_ok(
  $$insert into public.students (
    student_type, registration_origin, full_name, birth_date, postal_code,
    street, street_number, neighborhood, city_name, city_ibge_code,
    state_code, created_by
  ) values (
    'adult', 'fleet_owner_created', 'PRD9 Owner Adult', '2000-01-01',
    '18000000', 'Main Street', '40', 'Center', 'Test City', '3550000', 'SP',
    '60000000-0000-0000-0000-000000000005'
  )$$,
  'fleet owner can register an adult before account creation'
);
select set_config(
  'request.jwt.claims',
  '{"sub":"60000000-0000-0000-0000-000000000001","role":"authenticated"}',
  true
);
set local role authenticated;
select lives_ok(
  $$insert into prd9_test_ids(kind, id)
    select 'source-request', public.submit_fleet_join_request(
      '41000000-0000-0000-0000-000000000001',
      (select id from public.students where full_name = 'PRD9 Minor'),
      '63000000-0000-0000-0000-000000000001', 'morning',
      array['going']::text[], array[1]::smallint[]
    )$$,
  'guardian can create a pending request for source-pairing tests'
);
reset role;
select lives_ok(
  $$insert into public.fleet_enrollments (
    fleet_id, student_id, source_type, source_request_id, school_id, shift,
    registration_command_id, registration_payload_hash
  ) values (
    '41000000-0000-0000-0000-000000000001',
    (select id from public.students where full_name = 'PRD9 Owner Minor'),
    'owner_registration', null, '63000000-0000-0000-0000-000000000001', 'morning',
    '90000000-0000-0000-0000-000000000045', extensions.digest('minor fixture', 'sha256')
  )$$,
  'owner registration creates an enrollment without a request'
);
insert into public.fleet_enrollments (
  fleet_id, student_id, source_type, source_request_id, school_id, shift,
  registration_command_id, registration_payload_hash
) values (
  '41000000-0000-0000-0000-000000000002',
  (select id from public.students where full_name = 'PRD9 Owner Adult'),
  'owner_registration', null, '63000000-0000-0000-0000-000000000001', 'morning',
  '90000000-0000-0000-0000-000000000046', extensions.digest('adult fixture', 'sha256')
);
select throws_ok(
  $$do $body$
  declare
    v_enrollment_id uuid;
  begin
    insert into public.fleet_enrollments (
      fleet_id, student_id, source_type, source_request_id, school_id, shift
    ) values (
      '41000000-0000-0000-0000-000000000001',
      (select id from public.students where full_name = 'PRD9 Owner Adult'),
      'join_request', null, '63000000-0000-0000-0000-000000000001', 'morning'
    ) returning id into v_enrollment_id;
    delete from public.fleet_enrollments where id = v_enrollment_id;
  end;
  $body$;$$,
  '23514', null,
  'join-request enrollment requires a request id'
);
select throws_ok(
  $$do $body$
  declare
    v_enrollment_id uuid;
  begin
    insert into public.fleet_enrollments (
      fleet_id, student_id, source_type, source_request_id, school_id, shift
    ) values (
      '41000000-0000-0000-0000-000000000001',
      (select id from public.students where full_name = 'PRD9 Owner Adult'),
      'owner_registration',
      (select id from prd9_test_ids where kind = 'source-request'),
      '63000000-0000-0000-0000-000000000001', 'morning'
    ) returning id into v_enrollment_id;
    delete from public.fleet_enrollments where id = v_enrollment_id;
  end;
  $body$;$$,
  '23514', null,
  'owner-registration enrollment cannot reference a request'
);
select throws_ok(
  $$do $body$
  declare
    v_enrollment_id uuid;
  begin
    insert into public.fleet_enrollments (
      fleet_id, student_id, source_type, source_request_id
    ) values (
      '41000000-0000-0000-0000-000000000001',
      (select id from public.students where full_name = 'PRD9 Owner Adult'),
      'owner_registration', null
    ) returning id into v_enrollment_id;
    delete from public.fleet_enrollments where id = v_enrollment_id;
  end;
  $body$;$$,
  '23514', null,
  'owner-registration enrollment requires school and shift'
);
insert into public.fleet_enrollments (
  fleet_id, student_id, source_type, source_request_id, school_id, shift
) values (
  '41000000-0000-0000-0000-000000000001',
  (select id from public.students where full_name = 'PRD9 Minor'),
  'join_request', (select id from prd9_test_ids where kind = 'source-request'),
  '63000000-0000-0000-0000-000000000001', 'morning'
);
select throws_ok(
  $$update public.fleet_enrollments
    set source_type = 'join_request',
        source_request_id = (select id from prd9_test_ids where kind = 'second-request')
    where student_id = (select id from public.students where full_name = 'PRD9 Owner Minor')$$,
  '23514', null,
  'enrollment source type cannot be changed'
);
update public.fleet_enrollments
set source_type = 'owner_registration', source_request_id = null
where student_id = (select id from public.students where full_name = 'PRD9 Owner Minor');
select throws_ok(
  $$update public.fleet_enrollments
    set source_request_id = (select id from prd9_test_ids where kind = 'second-request')
    where student_id = (select id from public.students where full_name = 'PRD9 Minor')$$,
  '23514', null,
  'enrollment request provenance cannot be changed'
);
select lives_ok(
  $$update public.fleet_enrollments
    set shift = 'evening'
    where student_id = (select id from public.students where full_name = 'PRD9 Owner Minor')$$,
  'operational enrollment fields remain updatable'
);
select throws_ok(
  $$do $body$
  declare
    v_student_id uuid;
  begin
    insert into public.students (
      student_type, registration_origin, full_name, birth_date, postal_code,
      street, street_number, neighborhood, city_name, city_ibge_code,
      state_code, created_by
    ) values (
      'minor', 'self_created', 'PRD9 Invalid Minor', '2015-01-01',
      '18000000', 'Main Street', '50', 'Center', 'Test City', '3550000', 'SP',
      '60000000-0000-0000-0000-000000000005'
    ) returning id into v_student_id;
    delete from public.students where id = v_student_id;
  end;
  $body$;$$,
  '23514', null,
  'minor cannot have self-created origin'
);
select throws_ok(
  $$do $body$
  declare
    v_student_id uuid;
  begin
    insert into public.students (
      student_type, profile_id, registration_origin, full_name, birth_date,
      postal_code, street, street_number, neighborhood, city_name,
      city_ibge_code, state_code, created_by
    ) values (
      'adult', '60000000-0000-0000-0000-000000000005', 'guardian_created',
      'PRD9 Invalid Adult', '2000-01-01', '18000000', 'Main Street', '60',
      'Center', 'Test City', '3550000', 'SP',
      '60000000-0000-0000-0000-000000000005'
    ) returning id into v_student_id;
    delete from public.students where id = v_student_id;
  end;
  $body$;$$,
  '23514', null,
  'adult cannot have guardian-created origin'
);
select throws_ok(
  $$update public.students
    set registration_origin = 'guardian_created'
    where full_name = 'PRD9 Owner Minor'$$,
  '23514', null,
  'student registration origin cannot be changed'
);
update public.students
set registration_origin = 'fleet_owner_created'
where full_name = 'PRD9 Owner Minor';
select lives_ok(
  $$update public.students
    set profile_id = '60000000-0000-0000-0000-000000000002'
    where full_name = 'PRD9 Owner Adult'$$,
  'owner-created adult can later link a profile'
);
select is(
  (select registration_origin from public.students where full_name = 'PRD9 Owner Adult'),
  'fleet_owner_created',
  'linking a profile preserves owner-created origin'
);
select lives_ok(
  $$update public.students
    set full_name = 'PRD9 Owner Minor Updated'
    where full_name = 'PRD9 Owner Minor'$$,
  'unrelated student fields remain updatable'
);
select is(
  (select full_name from public.students where id = (
    select id from public.students where registration_origin = 'fleet_owner_created' and student_type = 'minor'
  )),
  'PRD9 Owner Minor Updated',
  'unrelated update is persisted'
);

select has_column(
  'public', 'students', 'registration_origin',
  'students records their registration origin'
);
select has_column(
  'public', 'fleet_enrollments', 'source_type',
  'enrollments record their source type'
);
select has_table(
  'public', 'fleet_student_contacts',
  'fleet student contacts are stored in a dedicated table'
);
select has_column('public', 'fleet_student_contacts', 'id', 'contacts have an id');
select has_column('public', 'fleet_student_contacts', 'fleet_id', 'contacts retain the fleet id');
select has_column('public', 'fleet_student_contacts', 'enrollment_id', 'contacts link to an enrollment');
select has_column('public', 'fleet_student_contacts', 'contact_type', 'contacts identify the contact type');
select has_column('public', 'fleet_student_contacts', 'full_name', 'contacts store a full name');
select has_column('public', 'fleet_student_contacts', 'email', 'contacts can store an email');
select has_column('public', 'fleet_student_contacts', 'phone', 'contacts can store a phone');
select has_column('public', 'fleet_student_contacts', 'is_primary', 'contacts identify the primary contact');
select has_column('public', 'fleet_student_contacts', 'created_at', 'contacts record creation time');
select has_column('public', 'fleet_student_contacts', 'updated_at', 'contacts record update time');
select lives_ok(
  $$insert into public.fleet_student_contacts (
    id, fleet_id, enrollment_id, contact_type, full_name, email, is_primary
  ) values (
    '67000000-0000-0000-0000-000000000001',
    '41000000-0000-0000-0000-000000000001',
    (select id from public.fleet_enrollments where student_id = (
      select id from public.students where full_name = 'PRD9 Owner Minor Updated'
    ) and fleet_id = '41000000-0000-0000-0000-000000000001'),
    'guardian', 'Primary Contact', 'primary@example.test', true
  )$$,
  'a primary guardian contact can be attached to a direct enrollment'
);
select lives_ok(
  $$insert into public.fleet_student_contacts (
    id, fleet_id, enrollment_id, contact_type, full_name, phone, is_primary
  ) values (
    '67000000-0000-0000-0000-000000000002',
    '41000000-0000-0000-0000-000000000001',
    (select id from public.fleet_enrollments where student_id = (
      select id from public.students where full_name = 'PRD9 Owner Minor Updated'
    ) and fleet_id = '41000000-0000-0000-0000-000000000001'),
    'student', 'Secondary Contact', '555-0110', false
  )$$,
  'an enrollment can have a secondary contact'
);
select lives_ok(
  $$insert into public.fleet_student_contacts (
    id, fleet_id, enrollment_id, contact_type, full_name, email, is_primary
  ) values (
    '67000000-0000-0000-0000-000000000003',
    '41000000-0000-0000-0000-000000000002',
    (select id from public.fleet_enrollments where fleet_id = '41000000-0000-0000-0000-000000000002'),
    'student', 'Fleet B Contact', 'fleet-b@example.test', true
  )$$,
  'another fleet can store its own primary contact'
);
select throws_ok(
  $$insert into public.fleet_student_contacts (
    fleet_id, enrollment_id, contact_type, full_name, email, is_primary
  ) values (
    '41000000-0000-0000-0000-000000000001',
    (select id from public.fleet_enrollments where student_id = (
      select id from public.students where full_name = 'PRD9 Owner Minor Updated'
    ) and fleet_id = '41000000-0000-0000-0000-000000000001'),
    'guardian', '  ', 'blank-name@example.test', false
  )$$,
  '23514', null,
  'contact name cannot be blank'
);
select throws_ok(
  $$insert into public.fleet_student_contacts (
    fleet_id, enrollment_id, contact_type, full_name, email, phone, is_primary
  ) values (
    '41000000-0000-0000-0000-000000000001',
    (select id from public.fleet_enrollments where student_id = (
      select id from public.students where full_name = 'PRD9 Owner Minor Updated'
    ) and fleet_id = '41000000-0000-0000-0000-000000000001'),
    'guardian', 'Blank Email', '  ', '555-0111', false
  )$$,
  '23514', null,
  'provided email cannot be blank'
);
select throws_ok(
  $$insert into public.fleet_student_contacts (
    fleet_id, enrollment_id, contact_type, full_name, email, phone, is_primary
  ) values (
    '41000000-0000-0000-0000-000000000001',
    (select id from public.fleet_enrollments where student_id = (
      select id from public.students where full_name = 'PRD9 Owner Minor Updated'
    ) and fleet_id = '41000000-0000-0000-0000-000000000001'),
    'guardian', 'Blank Phone', 'blank-phone@example.test', '  ', false
  )$$,
  '23514', null,
  'provided phone cannot be blank'
);
select throws_ok(
  $$insert into public.fleet_student_contacts (
    fleet_id, enrollment_id, contact_type, full_name, is_primary
  ) values (
    '41000000-0000-0000-0000-000000000001',
    (select id from public.fleet_enrollments where student_id = (
      select id from public.students where full_name = 'PRD9 Owner Minor Updated'
    ) and fleet_id = '41000000-0000-0000-0000-000000000001'),
    'guardian', 'No Contact Method', false
  )$$,
  '23514', null,
  'contact requires a nonblank email or phone'
);
select throws_ok(
  $$insert into public.fleet_student_contacts (
    fleet_id, enrollment_id, contact_type, full_name, email, is_primary
  ) values (
    '41000000-0000-0000-0000-000000000001',
    (select id from public.fleet_enrollments where student_id = (
      select id from public.students where full_name = 'PRD9 Owner Minor Updated'
    ) and fleet_id = '41000000-0000-0000-0000-000000000001'),
    'emergency', 'Invalid Contact Type', 'invalid-type@example.test', false
  )$$,
  '23514', null,
  'contact type is limited to guardian or student'
);
select throws_ok(
  $$insert into public.fleet_student_contacts (
    fleet_id, enrollment_id, contact_type, full_name, email, is_primary
  ) values (
    '41000000-0000-0000-0000-000000000002',
    (select id from public.fleet_enrollments where student_id = (
      select id from public.students where full_name = 'PRD9 Owner Minor Updated'
    ) and fleet_id = '41000000-0000-0000-0000-000000000001'),
    'guardian', 'Mismatched Fleet', 'mismatch@example.test', false
  )$$,
  '23503', null,
  'contact fleet must match its enrollment fleet'
);
select throws_ok(
  $$insert into public.fleet_student_contacts (
    fleet_id, enrollment_id, contact_type, full_name, email, is_primary
  ) values (
    '41000000-0000-0000-0000-000000000001',
    (select id from public.fleet_enrollments where student_id = (
      select id from public.students where full_name = 'PRD9 Owner Minor Updated'
    ) and fleet_id = '41000000-0000-0000-0000-000000000001'),
    'guardian', 'Duplicate Primary', 'duplicate@example.test', true
  )$$,
  '23505', null,
  'each enrollment has at most one primary contact'
);
update public.fleet_student_contacts
set updated_at = '2000-01-01 00:00:00+00', phone = '555-0112'
where id = '67000000-0000-0000-0000-000000000001';
select ok(
  (select updated_at > '2000-01-01 00:00:00+00'::timestamptz
   from public.fleet_student_contacts
   where id = '67000000-0000-0000-0000-000000000001'),
  'contact updates refresh updated_at'
);
select ok(
  (select relrowsecurity
   from pg_catalog.pg_class
   where oid = 'public.fleet_student_contacts'::regclass),
  'row-level security is enabled for private contacts'
);
select ok(
  has_table_privilege('authenticated', 'public.fleet_student_contacts', 'SELECT'),
  'authenticated users can read contacts through RLS'
);
select ok(
  exists (
    select 1
    from pg_catalog.pg_policies
    where schemaname = 'public'
      and tablename = 'fleet_student_contacts'
      and policyname = 'fleet_student_contacts_select_owners'
  ),
  'contact reads use the owner-only policy'
);
select ok(
  not has_table_privilege('anon', 'public.fleet_student_contacts', 'SELECT'),
  'anonymous users cannot read contacts'
);
select ok(
  not has_table_privilege('authenticated', 'public.fleet_student_contacts', 'INSERT'),
  'authenticated users cannot insert contacts directly'
);
select ok(
  not has_table_privilege('authenticated', 'public.fleet_student_contacts', 'UPDATE'),
  'authenticated users cannot update contacts directly'
);
select ok(
  not has_table_privilege('authenticated', 'public.fleet_student_contacts', 'DELETE'),
  'authenticated users cannot delete contacts directly'
);
select is(
  (select count(*)::integer
   from public.student_guardians sg
   join public.students s on s.id = sg.student_id
   where s.full_name = 'PRD9 Owner Minor Updated'),
  0,
  'a pre-auth contact does not create a guardian relationship'
);
select set_config(
  'request.jwt.claims',
  '{"sub":"40000000-0000-0000-0000-000000000001","role":"authenticated"}',
  true
);
set local role authenticated;
select is(
  (select count(*)::integer from public.fleet_student_contacts),
  2,
  'owner can read contacts from their fleet'
);
reset role;
select set_config(
  'request.jwt.claims',
  '{"sub":"40000000-0000-0000-0000-000000000005","role":"authenticated"}',
  true
);
set local role authenticated;
select is(
  (select count(*)::integer from public.fleet_student_contacts),
  1,
  'owner cannot read contacts from another fleet'
);
reset role;
select set_config(
  'request.jwt.claims',
  '{"sub":"40000000-0000-0000-0000-000000000003","role":"authenticated"}',
  true
);
set local role authenticated;
select is(
  (select count(*)::integer from public.fleet_student_contacts),
  0,
  'driver cannot read private contacts'
);
reset role;
select set_config(
  'request.jwt.claims',
  '{"sub":"40000000-0000-0000-0000-000000000004","role":"authenticated"}',
  true
);
set local role authenticated;
select is(
  (select count(*)::integer from public.fleet_student_contacts),
  0,
  'guardian cannot read private contacts'
);
reset role;
select set_config(
  'request.jwt.claims',
  '{"sub":"60000000-0000-0000-0000-000000000003","role":"authenticated"}',
  true
);
set local role authenticated;
select is(
  (select count(*)::integer from public.fleet_student_contacts),
  0,
  'student cannot read private contacts'
);
reset role;
select set_config(
  'request.jwt.claims',
  '{"sub":"60000000-0000-0000-0000-000000000004","role":"authenticated"}',
  true
);
set local role authenticated;
select throws_ok(
  $$insert into public.fleet_student_contacts (
    fleet_id, enrollment_id, contact_type, full_name, email, is_primary
  ) values (
    '41000000-0000-0000-0000-000000000001',
    '67000000-0000-0000-0000-000000000001',
    'guardian', 'Unauthorized Insert', 'unauthorized@example.test', false
  )$$,
  '42501', null,
  'authenticated users cannot insert contacts directly'
);
select throws_ok(
  $$update public.fleet_student_contacts set phone = '555-0123'$$,
  '42501', null,
  'authenticated users cannot update contacts directly'
);
select throws_ok(
  $$delete from public.fleet_student_contacts$$,
  '42501', null,
  'authenticated users cannot delete contacts directly'
);
reset role;
set local role anon;
select throws_ok(
  $$select count(*) from public.fleet_student_contacts$$,
  '42501', null,
  'anonymous users cannot select contacts'
);
reset role;
select lives_ok(
  $$insert into public.audit_events (
    fleet_id, actor_user_id, action, entity_type, entity_id
  )
  select
    '41000000-0000-0000-0000-000000000001',
    '40000000-0000-0000-0000-000000000001',
    action,
    'student',
    (select id from public.students where full_name = 'PRD9 Owner Minor Updated')
  from unnest(array[
    'fleet_created', 'fleet_updated', 'member_roles_changed',
    'membership_status_changed', 'service_city_added', 'service_city_removed',
    'service_school_added', 'service_school_removed', 'student_updated',
    'secondary_guardian_added', 'secondary_guardian_removed',
    'join_request_created', 'join_request_cancelled', 'join_request_approved',
    'join_request_rejected', 'fleet_invitation_created',
    'fleet_invitation_accepted', 'fleet_invitation_declined',
    'fleet_invitation_cancelled', 'enrollment_ended', 'van_created',
    'van_updated', 'van_deactivated', 'driver_invitation_created',
    'driver_invitation_accepted', 'route_created', 'route_updated',
    'route_status_changed', 'route_schedule_created', 'route_schedule_updated',
    'transport_reservation_created', 'transport_reservation_cancelled',
    'join_request_waitlisted', 'join_request_changed',
    'enrollment_school_updated', 'service_enabled', 'service_disabled'
  ]::text[]) as actions(action)$$,
  'all currently valid audit actions remain accepted for students'
);
select lives_ok(
  $$insert into public.audit_events (
    fleet_id, actor_user_id, action, entity_type, entity_id
  ) values (
    '41000000-0000-0000-0000-000000000001',
    '40000000-0000-0000-0000-000000000001',
    'fleet_student_registered', 'student',
    (select id from public.students where full_name = 'PRD9 Owner Minor Updated')
  )$$,
  'student registration action is accepted by the audit contract'
);

select * from finish();

rollback;
