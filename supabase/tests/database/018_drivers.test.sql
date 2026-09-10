begin;

create extension if not exists pgtap with schema extensions;
\ir ../_helpers.psql

select plan(12);
select has_function('public', 'accept_driver_invitation', array['text'],
  'aceite de equipe não exige aluno');
select throws_ok(
  $$select public.accept_driver_invitation('token-inexistente')$$,
  'PGRST', null,
  'token inválido não concede papel'
);

select pg_temp.seed_foundation();
select pg_temp.seed_cycle_2_users();
create temp table driver_test_tokens(kind text primary key, token text) on commit drop;
create temp table driver_test_ids(kind text primary key, id uuid) on commit drop;
grant all on driver_test_tokens to authenticated;
grant all on driver_test_ids to authenticated;

select set_config('request.jwt.claims', '{"sub":"40000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
set local role authenticated;
insert into driver_test_tokens(kind, token)
select 'valid', public.create_fleet_invitation(
  '41000000-0000-0000-0000-000000000001', 'owner-cycle2@example.test', 'driver'
);
insert into driver_test_tokens(kind, token)
select 'unconfirmed', public.create_fleet_invitation(
  '41000000-0000-0000-0000-000000000001', 'unconfirmed@example.test', 'driver'
);
insert into driver_test_tokens(kind, token)
select 'guardian', public.create_fleet_invitation(
  '41000000-0000-0000-0000-000000000001', 'secondary@example.test', 'guardian'
);
reset role;

select set_config('request.jwt.claims', '{"sub":"60000000-0000-0000-0000-000000000005","role":"authenticated"}', true);
set local role authenticated;
insert into driver_test_ids(kind, id)
select 'membership', public.accept_driver_invitation(
  (select token from driver_test_tokens where kind = 'valid')
);
select throws_ok(
  $$select public.accept_driver_invitation((select token from driver_test_tokens where kind = 'valid'))$$,
  'PGRST', null,
  'aceite repetido é rejeitado'
);
reset role;
select is(
  (select count(*)::integer from public.fleet_membership_roles fmr
   join public.fleet_memberships fm on fm.id = fmr.membership_id
   where fm.id = (select id from driver_test_ids where kind = 'membership')
     and fmr.role = 'driver'),
  1,
  'aceite concede apenas o papel driver'
);
select is(
  (select count(*)::integer from public.students),
  0,
  'aceite de driver não cria aluno'
);
select is(
  (select count(*)::integer from public.fleet_join_requests),
  0,
  'aceite de driver não cria pedido'
);
select is(
  (select count(*)::integer from public.fleet_enrollments),
  0,
  'aceite de driver não cria vínculo de transporte'
);

select set_config('request.jwt.claims', '{"sub":"40000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select throws_ok(
  $$select public.accept_driver_invitation((select token from driver_test_tokens where kind = 'valid'))$$,
  'PGRST', null,
  'o convite já aceito não pode ser reutilizado'
);
select throws_ok(
  $$select public.accept_driver_invitation((select token from driver_test_tokens where kind = 'guardian'))$$,
  'PGRST', null,
  'convite guardian não usa o aceite de driver'
);
reset role;

select set_config('request.jwt.claims', '{"sub":"60000000-0000-0000-0000-000000000004","role":"authenticated"}', true);
set local role authenticated;
select throws_ok(
  $$select public.accept_driver_invitation((select token from driver_test_tokens where kind = 'unconfirmed'))$$,
  'PGRST', null,
  'e-mail não confirmado não aceita convite'
);
reset role;

select set_config('request.jwt.claims', '{"sub":"60000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select throws_ok(
  $$select public.accept_driver_invitation((select token from driver_test_tokens where kind = 'valid'))$$,
  'PGRST', null,
  'e-mail diferente não aceita convite'
);
reset role;

select set_config('request.jwt.claims', '{"sub":"40000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_fleet_membership_status((select id from driver_test_ids where kind = 'membership'), 'suspended');
insert into driver_test_tokens(kind, token)
select 'suspended', public.create_fleet_invitation(
  '41000000-0000-0000-0000-000000000001', 'owner-cycle2@example.test', 'driver'
);
reset role;
select set_config('request.jwt.claims', '{"sub":"60000000-0000-0000-0000-000000000005","role":"authenticated"}', true);
set local role authenticated;
select throws_ok(
  $$select public.accept_driver_invitation((select token from driver_test_tokens where kind = 'suspended'))$$,
  'PGRST', null,
  'aceite não reativa associação suspensa'
);

select * from finish();

rollback;
