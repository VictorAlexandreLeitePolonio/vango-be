begin;

create extension if not exists pgtap with schema extensions;
\ir ../_helpers.psql
\ir ../_approval.psql

select plan(11);
select pg_temp.seed_foundation();
select pg_temp.seed_cycle_2_users();
create temp table privacy_test_ids(kind text primary key, id uuid) on commit drop;
grant all on privacy_test_ids to authenticated;

update public.fleets set status = 'published' where id = '41000000-0000-0000-0000-000000000001';
insert into public.schools (
  id, provider, external_id, institution_type, name, postal_code, street,
  street_number, neighborhood, city_name, city_ibge_code, state_code
) values (
  '70000000-0000-0000-0000-000000000001', 'inep', 'privacy-school', 'school',
  'Teste Escola Privacidade', '18000000', 'Rua Privada', '10', 'Centro', 'Teste', '3550000', 'SP'
);
insert into public.fleet_service_cities (fleet_id, city_ibge_code, city_name, state_code, created_by)
values
  ('41000000-0000-0000-0000-000000000001', '3550000', 'Teste', 'SP', '40000000-0000-0000-0000-000000000001'),
  ('41000000-0000-0000-0000-000000000002', '3550000', 'Teste', 'SP', '40000000-0000-0000-0000-000000000005');
insert into public.fleet_service_schools (fleet_id, school_id, created_by)
values
  ('41000000-0000-0000-0000-000000000001', '70000000-0000-0000-0000-000000000001', '40000000-0000-0000-0000-000000000001'),
  ('41000000-0000-0000-0000-000000000002', '70000000-0000-0000-0000-000000000001', '40000000-0000-0000-0000-000000000005');

select set_config('request.jwt.claims', '{"sub":"60000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.create_minor_student('Teste Menor Privacidade', '2015-02-03', '18000000', 'Rua Residencial', '99', null, 'Centro', 'Teste', '3550000', 'SP', -23.5, -47.5);
select public.submit_fleet_join_request('41000000-0000-0000-0000-000000000001', (select id from public.students where full_name = 'Teste Menor Privacidade'), '70000000-0000-0000-0000-000000000001', 'morning', array['going']::text[], array[1]::smallint[]);

reset role;
insert into privacy_test_ids(kind, id)
select 'request', id from public.fleet_join_requests where student_id = (select id from public.students where full_name = 'Teste Menor Privacidade');
select set_config('request.jwt.claims', '{"sub":"40000000-0000-0000-0000-000000000005","role":"authenticated"}', true);
set local role authenticated;
select throws_ok(
  $$select * from public.list_fleet_join_requests('41000000-0000-0000-0000-000000000001', null, 50, 0)$$,
  'PGRST', null, 'owner of another tenant cannot list requests'
);
select throws_ok(
  $$select public.decide_fleet_join_request((select id from privacy_test_ids where kind = 'request'), 'approved')$$,
  'PGRST', null, 'owner of another tenant cannot decide requests'
);

reset role;
select set_config('request.jwt.claims', '', true);
set local role anon;
select throws_ok(
  $$select count(*) from public.students$$,
  '42501', null, 'anonymous cannot read students'
);
select lives_ok(
  $$select * from public.search_schools('privacidade', '3550000', null, 50, 0)$$,
  'anonymous can use public school search'
);
select throws_ok(
  $$select public.create_adult_student('Blocked', '2000-01-01', '18000000', 'Rua', '1', null, 'Centro', 'Teste', '3550000', 'SP', null, null)$$,
  '42501', null, 'anonymous cannot execute student commands'
);

reset role;
select set_config('request.jwt.claims', '{"sub":"40000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
insert into privacy_test_ids(kind, id)
select 'approval-schedule', pg_temp.seed_approval_schedule(
  (select id from privacy_test_ids where kind = 'request')
);
set local role authenticated;
select lives_ok(
  $$select public.approve_transport_request(
    (select id from privacy_test_ids where kind = 'request'),
    jsonb_build_array(jsonb_build_object('schedule_id',
      (select id from privacy_test_ids where kind = 'approval-schedule'), 'weekday', 1)),
    current_date + 1)$$,
  'tenant owner approves own request with allocation'
);
select is(
  (select count(*)::integer from public.audit_events where action = 'join_request_approved' and fleet_id = '41000000-0000-0000-0000-000000000001'),
  1,
  'approval writes one tenant audit event'
);

reset role;
select ok(
  not exists (
    select 1
    from public.audit_events a
    cross join lateral jsonb_object_keys(a.metadata) key_name
    where key_name in ('email', 'token', 'token_hash', 'postal_code', 'street', 'latitude', 'longitude')
  ),
  'audit metadata has no sensitive keys'
);
select ok(
  not exists (
    select 1 from information_schema.role_table_grants
    where table_schema = 'public'
      and table_name in ('students', 'student_guardians', 'student_guardian_invitations', 'fleet_invitations', 'fleet_join_requests', 'fleet_enrollments')
      and grantee in ('anon', 'authenticated')
      and privilege_type in ('INSERT', 'UPDATE', 'DELETE')
  ),
  'transactional tables expose no direct writes'
);
select ok(
  not exists (
    select 1 from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.prosecdef
      and not ('search_path=""' = any(p.proconfig))
      and p.proname in ('create_minor_student', 'create_adult_student', 'update_student', 'submit_fleet_join_request', 'decide_fleet_join_request', 'accept_fleet_invitation')
  ),
  'critical security definer functions set an empty search path'
);
select is(
  (select count(*)::integer from public.schools),
  1,
  'privacy fixture does not turn into persistent catalog data'
);

select * from finish();

rollback;
