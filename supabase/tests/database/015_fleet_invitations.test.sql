begin;

create extension if not exists pgtap with schema extensions;
\ir ../_helpers.psql

select plan(10);
select pg_temp.seed_cycle_2_users();
create temp table fleet_invitation_test_tokens(kind text primary key, token text) on commit drop;
grant all on fleet_invitation_test_tokens to authenticated;

insert into public.fleets (id, name, slug, status, created_by)
values ('61000000-0000-0000-0000-000000000001', 'Frota Convite', 'frota-convite', 'published', '60000000-0000-0000-0000-000000000005');
insert into public.fleet_memberships (id, fleet_id, user_id)
values ('62000000-0000-0000-0000-000000000001', '61000000-0000-0000-0000-000000000001', '60000000-0000-0000-0000-000000000005');
insert into public.fleet_membership_roles (membership_id, role)
values ('62000000-0000-0000-0000-000000000001', 'owner');
insert into public.schools (
  id, provider, external_id, institution_type, name, postal_code, street,
  street_number, neighborhood, city_name, city_ibge_code, state_code
) values (
  '63000000-0000-0000-0000-000000000001', 'inep', 'invite-school', 'school',
  'Teste Escola Invite', '18000000', 'Rua Escola', '1', 'Centro', 'Teste', '3550000', 'SP'
);
insert into public.fleet_service_cities (fleet_id, city_ibge_code, city_name, state_code, created_by)
values ('61000000-0000-0000-0000-000000000001', '3550000', 'Teste', 'SP', '60000000-0000-0000-0000-000000000005');
insert into public.fleet_service_schools (fleet_id, school_id, created_by)
values ('61000000-0000-0000-0000-000000000001', '63000000-0000-0000-0000-000000000001', '60000000-0000-0000-0000-000000000005');

select set_config('request.jwt.claims', '{"sub":"60000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.create_minor_student('Teste Menor Invite', '2015-02-03', '18000000', 'Rua Menor', '10', null, 'Centro', 'Teste', '3550000', 'SP', null, null);

reset role;
select set_config('request.jwt.claims', '{"sub":"60000000-0000-0000-0000-000000000005","role":"authenticated"}', true);
set local role authenticated;
insert into fleet_invitation_test_tokens(kind, token)
select 'guardian', public.create_fleet_invitation('61000000-0000-0000-0000-000000000001', ' primary@example.test ', 'guardian');
select throws_ok(
  $$select public.create_fleet_invitation('61000000-0000-0000-0000-000000000001', 'PRIMARY@example.test', 'guardian')$$,
  'PGRST', null, 'duplicate pending fleet invitation is rejected'
);
select throws_ok(
  $$select public.create_fleet_invitation('61000000-0000-0000-0000-000000000001', 'adult@example.test', 'owner')$$,
  'PGRST', null, 'invalid fleet invitation role is rejected'
);

reset role;
select is(
  (select role from public.get_fleet_invitation((select token from fleet_invitation_test_tokens where kind = 'guardian'))),
  'guardian',
  'anonymous preview returns only invitation role'
);
select ok(
  not exists (
    select 1 from public.get_fleet_invitation((select token from fleet_invitation_test_tokens where kind = 'guardian'))
    where fleet_id is null or fleet_name is null
  ),
  'anonymous preview includes public fleet fields'
);

select set_config('request.jwt.claims', '{"sub":"60000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select lives_ok(
  $$select public.accept_fleet_invitation((select token from fleet_invitation_test_tokens where kind = 'guardian'), (select id from public.students where full_name = 'Teste Menor Invite'), '63000000-0000-0000-0000-000000000001', 'morning', array['going']::text[], array[1]::smallint[])$$,
  'guardian accepts fleet invitation after authenticating'
);
reset role;
select set_config('request.jwt.claims', '{"sub":"60000000-0000-0000-0000-000000000005","role":"authenticated"}', true);
set local role authenticated;
select is(
  (select count(*)::integer from public.list_fleet_join_requests('61000000-0000-0000-0000-000000000001', 'approved', 50, 0) where student_full_name = 'Teste Menor Invite'),
  1,
  'acceptance creates an approved request'
);
select is(
  (select status from public.get_fleet_invitation((select token from fleet_invitation_test_tokens where kind = 'guardian'))),
  'accepted',
  'accepted invitation changes state'
);

reset role;
select set_config('request.jwt.claims', '{"sub":"60000000-0000-0000-0000-000000000005","role":"authenticated"}', true);
set local role authenticated;
insert into fleet_invitation_test_tokens(kind, token)
select 'cancelled', public.create_fleet_invitation('61000000-0000-0000-0000-000000000001', 'other@example.test', 'guardian');
reset role;
create temp table fleet_invitation_test_ids(kind text primary key, id uuid) on commit drop;
grant all on fleet_invitation_test_ids to authenticated;
insert into fleet_invitation_test_ids(kind, id)
select 'cancelled', id from public.fleet_invitations where lower(email) = 'other@example.test' and status = 'pending';
select set_config('request.jwt.claims', '{"sub":"60000000-0000-0000-0000-000000000005","role":"authenticated"}', true);
set local role authenticated;
select lives_ok(
  $$select public.cancel_fleet_invitation((select id from fleet_invitation_test_ids where kind = 'cancelled'))$$,
  'owner cancels pending invitation'
);

reset role;
select is(
  (select status from public.get_fleet_invitation((select token from fleet_invitation_test_tokens where kind = 'cancelled'))),
  'cancelled',
  'cancelled invitation remains visible without sensitive fields'
);

select set_config('request.jwt.claims', '{"sub":"60000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select throws_ok(
  $$select public.accept_fleet_invitation((select token from fleet_invitation_test_tokens where kind = 'cancelled'), (select id from public.students where full_name = 'Teste Menor Invite'), '63000000-0000-0000-0000-000000000001', 'morning', array['going']::text[], array[1]::smallint[])$$,
  'PGRST', null, 'cancelled invitation cannot be accepted'
);

select * from finish();

rollback;
