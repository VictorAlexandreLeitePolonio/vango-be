begin;

create extension if not exists pgtap with schema extensions;
\ir ../_helpers.psql

select plan(9);
select has_table('public', 'vans', 'vans existe');
select pg_temp.seed_foundation();
create temp table van_test_ids(kind text primary key, id uuid) on commit drop;
grant all on van_test_ids to authenticated;

select set_config('request.jwt.claims', '{"sub":"40000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
set local role authenticated;
insert into van_test_ids(kind, id)
select 'primary', public.save_van(
  '41000000-0000-0000-0000-000000000001', null, ' abc-1234 ',
  ' Sprinter ', ' Van Principal ', 30
);
select is(
  (select plate from public.vans where id = (select id from van_test_ids where kind = 'primary')),
  'ABC1234',
  'placa é normalizada'
);
select is(
  (select capacity from public.vans where id = (select id from van_test_ids where kind = 'primary')),
  30,
  'capacidade é persistida'
);
select lives_ok(
  $$select public.save_van('41000000-0000-0000-0000-000000000001', (select id from van_test_ids where kind = 'primary'), 'ABC1D23', 'Sprinter 2', 'Van Principal 2', 31)$$,
  'owner pode editar a van'
);
select throws_ok(
  $$select public.save_van('41000000-0000-0000-0000-000000000001', null, 'ABC1D23', 'Outra', 'Outra', 10)$$,
  'PGRST', null,
  'placa ativa duplicada é rejeitada'
);
select throws_ok(
  $$select public.save_van('41000000-0000-0000-0000-000000000001', null, 'ABC1235', 'Outra', 'Outra', 0)$$,
  'PGRST', null,
  'capacidade zero é rejeitada'
);
select throws_ok(
  $$select public.save_van('41000000-0000-0000-0000-000000000001', null, 'INVALID', 'Outra', 'Outra', 10)$$,
  'PGRST', null,
  'placa inválida é rejeitada'
);

reset role;
select set_config('request.jwt.claims', '{"sub":"40000000-0000-0000-0000-000000000005","role":"authenticated"}', true);
set local role authenticated;
select throws_ok(
  $$select public.save_van('41000000-0000-0000-0000-000000000001', (select id from van_test_ids where kind = 'primary'), 'ABC1D23', 'Outra', 'Outra', 10)$$,
  'PGRST', null,
  'owner de outro tenant não edita a van'
);

reset role;
select set_config('request.jwt.claims', '', true);
set local role anon;
select throws_ok(
  $$select public.save_van('41000000-0000-0000-0000-000000000001', null, 'ABC1236', 'Outra', 'Outra', 10)$$,
  '42501', null,
  'anônimo não chama o comando de van'
);

select * from finish();

rollback;
