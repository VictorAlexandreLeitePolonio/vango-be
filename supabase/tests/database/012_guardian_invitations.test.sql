begin;

create extension if not exists pgtap with schema extensions;
\ir ../_helpers.psql

select plan(10);
select pg_temp.seed_cycle_2_users();

select set_config(
  'request.jwt.claims',
  '{"sub":"60000000-0000-0000-0000-000000000001","role":"authenticated"}',
  true
);
set local role authenticated;
select public.create_minor_student(
  'Teste Dependente', '2015-02-03', '18000000', 'Rua Dependente', '10', null,
  'Centro', 'Teste', '3550000', 'SP', null, null
);

reset role;
insert into public.fleets (id, name, slug, status, created_by)
values ('61000000-0000-0000-0000-000000000001', 'Frota Guardião', 'frota-guardiao', 'published', '60000000-0000-0000-0000-000000000005');
insert into public.fleet_memberships (id, fleet_id, user_id)
values ('62000000-0000-0000-0000-000000000001', '61000000-0000-0000-0000-000000000001', '60000000-0000-0000-0000-000000000005');
insert into public.fleet_membership_roles (membership_id, role)
values ('62000000-0000-0000-0000-000000000001', 'owner');
insert into public.schools (
  id, provider, external_id, institution_type, name, postal_code, street,
  street_number, neighborhood, city_name, city_ibge_code, state_code
) values (
  '63000000-0000-0000-0000-000000000001', 'inep', 'guardian-school', 'school',
  'Teste Escola', '18000000', 'Rua Escola', '1', 'Centro', 'Teste', '3550000', 'SP'
);
insert into public.fleet_service_cities (fleet_id, city_ibge_code, city_name, state_code, created_by)
values ('61000000-0000-0000-0000-000000000001', '3550000', 'Teste', 'SP', '60000000-0000-0000-0000-000000000005');
insert into public.fleet_service_schools (fleet_id, school_id, created_by)
values ('61000000-0000-0000-0000-000000000001', '63000000-0000-0000-0000-000000000001', '60000000-0000-0000-0000-000000000005');
insert into public.fleet_join_requests (
  id, fleet_id, requester_user_id, student_id, school_id, origin, shift,
  directions, weekdays, postal_code, street, street_number, neighborhood,
  city_name, city_ibge_code, state_code, status, decided_by, decided_at
)
select '64000000-0000-0000-0000-000000000001', '61000000-0000-0000-0000-000000000001',
       '60000000-0000-0000-0000-000000000001', s.id, '63000000-0000-0000-0000-000000000001',
       'marketplace', 'morning', array['going'], array[1]::smallint[], s.postal_code,
       s.street, s.street_number, s.neighborhood, s.city_name, s.city_ibge_code,
       s.state_code, 'approved', '60000000-0000-0000-0000-000000000005', now()
from public.students s where s.full_name = 'Teste Dependente';
insert into public.fleet_enrollments (id, fleet_id, student_id, source_request_id)
select '65000000-0000-0000-0000-000000000001', '61000000-0000-0000-0000-000000000001', s.id, '64000000-0000-0000-0000-000000000001'
from public.students s where s.full_name = 'Teste Dependente';

create temp table guardian_tokens(token text) on commit drop;
grant all on guardian_tokens to authenticated;
create temp table mismatch_tokens(token text) on commit drop;
grant all on mismatch_tokens to authenticated;

select set_config(
  'request.jwt.claims',
  '{"sub":"60000000-0000-0000-0000-000000000001","role":"authenticated"}',
  true
);
set local role authenticated;
insert into guardian_tokens
select public.create_student_guardian_invitation((select id from public.students where full_name = 'Teste Dependente'), ' secondary@example.test ');
select ok((select length(token) = 64 from guardian_tokens), 'primary receives a hashed-token guardian invitation');
select throws_ok(
  $$select public.create_student_guardian_invitation((select id from public.students where full_name = 'Teste Dependente'), 'SECONDARY@example.test')$$,
  'PGRST', null, 'duplicate pending guardian invitation is rejected'
);
insert into mismatch_tokens
select public.create_student_guardian_invitation((select id from public.students where full_name = 'Teste Dependente'), 'other@example.test');

reset role;
select ok(
  (select expires_at between created_at + interval '13 days 23 hours' and created_at + interval '14 days 1 hour' from public.student_guardian_invitations order by created_at desc limit 1),
  'guardian invitation expires after fourteen days'
);

select set_config(
  'request.jwt.claims',
  '{"sub":"60000000-0000-0000-0000-000000000002","role":"authenticated"}',
  true
);
set local role authenticated;
select throws_ok(
  $$select public.respond_student_guardian_invitation((select token from mismatch_tokens), true)$$,
  'PGRST', null, 'email mismatch cannot accept guardian invitation'
);
select lives_ok(
  $$select public.respond_student_guardian_invitation((select token from guardian_tokens), true)$$,
  'matching confirmed email accepts guardian invitation'
);
select is(
  (select status from public.student_guardians where guardian_user_id = '60000000-0000-0000-0000-000000000002'),
  'active',
  'secondary guardian becomes active'
);
select is(
  (select count(*)::integer from public.fleet_membership_roles fmr join public.fleet_memberships fm on fm.id = fmr.membership_id where fm.fleet_id = '61000000-0000-0000-0000-000000000001' and fm.user_id = '60000000-0000-0000-0000-000000000002' and fmr.role = 'guardian'),
  1,
  'secondary guardian receives derived fleet role'
);

reset role;
select set_config(
  'request.jwt.claims',
  '{"sub":"60000000-0000-0000-0000-000000000001","role":"authenticated"}',
  true
);
set local role authenticated;
select lives_ok(
  $$select public.remove_student_guardian((select id from public.students where full_name = 'Teste Dependente'), '60000000-0000-0000-0000-000000000002')$$,
  'primary removes secondary guardian'
);
select is(
  (select count(*)::integer from public.fleet_membership_roles fmr join public.fleet_memberships fm on fm.id = fmr.membership_id where fm.fleet_id = '61000000-0000-0000-0000-000000000001' and fm.user_id = '60000000-0000-0000-0000-000000000002' and fmr.role = 'guardian'),
  0,
  'removal clears only derived guardian role'
);
select throws_ok(
  $$select public.remove_student_guardian((select id from public.students where full_name = 'Teste Dependente'), '60000000-0000-0000-0000-000000000001')$$,
  'PGRST', null, 'primary guardian cannot be removed'
);

select * from finish();

rollback;
