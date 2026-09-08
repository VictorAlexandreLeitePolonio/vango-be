begin;

create extension if not exists pgtap with schema extensions;
\ir ../_helpers.psql

select plan(16);
select has_table('public', 'device_tokens', 'dispositivos são privados');
select has_function('public', 'register_device', array['uuid', 'text', 'text'],
  'registro de instalação própria');
select has_function('public', 'revoke_device', array['uuid'],
  'revogação idempotente da instalação própria');
select throws_ok(
  $$select public.register_device(
    '75000000-0000-0000-0000-000000000001', 'web', 'fake-token')$$,
  'PGRST', null, 'plataforma fora do MVP rejeitada'
);

select pg_temp.seed_foundation();
create temp table device_test_ids(kind text primary key, id uuid) on commit drop;
grant all on device_test_ids to authenticated;

select set_config('request.jwt.claims',
  '{"sub":"40000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
set local role authenticated;
insert into device_test_ids(kind, id)
select 'first', public.register_device(
  '75000000-0000-0000-0000-000000000001', 'android', ' token-a ');
select throws_ok(
  $$select public.register_device(
    '75000000-0000-0000-0000-000000000002', 'android', '   ')$$,
  'PGRST', null, 'token vazio rejeitado'
);
select throws_ok(
  $$select public.register_device(
    '75000000-0000-0000-0000-000000000002', 'ios', repeat('x', 4097))$$,
  'PGRST', null, 'token acima do limite rejeitado'
);

select is(
  public.register_device(
    '75000000-0000-0000-0000-000000000001', 'android', 'token-a'),
  (select id from device_test_ids where kind = 'first'),
  'registro repetido da mesma instalação é idempotente'
);
reset role;
insert into device_test_ids(kind, id)
select 'rotated', public.register_device(
  '75000000-0000-0000-0000-000000000001', 'ios', 'token-b');
select ok(
  (select count(*) = 1 from public.device_tokens
   where user_id = '40000000-0000-0000-0000-000000000001'
     and installation_id = '75000000-0000-0000-0000-000000000001'
     and active),
  'rotação mantém uma instalação ativa'
);
select ok(
  not exists (
    select 1 from public.device_tokens
    where user_id = '40000000-0000-0000-0000-000000000001'
      and installation_id = '75000000-0000-0000-0000-000000000001'
      and token = 'token-a' and active
  ),
  'token anterior deixa de estar ativo na rotação'
);
select is(
  (select platform from public.device_tokens
   where id = (select id from device_test_ids where kind = 'rotated')),
  'ios',
  'rotação grava a nova plataforma'
);

select set_config('request.jwt.claims',
  '{"sub":"40000000-0000-0000-0000-000000000002","role":"authenticated"}', true);
set local role authenticated;
select throws_ok(
  $$select public.register_device(
    '75000000-0000-0000-0000-000000000003', 'android', 'token-b')$$,
  'PGRST', null, 'token ativo de outra conta gera conflito opaco'
);

reset role;
select set_config('request.jwt.claims',
  '{"sub":"40000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.revoke_device('75000000-0000-0000-0000-000000000001');
select public.revoke_device('75000000-0000-0000-0000-000000000001');
reset role;
select ok(
  (select not active and revoked_at is not null
   from public.device_tokens
   where id = (select id from device_test_ids where kind = 'rotated')),
  'logout repetido permanece idempotente'
);

select set_config('request.jwt.claims',
  '{"sub":"40000000-0000-0000-0000-000000000002","role":"authenticated"}', true);
set local role authenticated;
select lives_ok(
  $$select public.register_device(
    '75000000-0000-0000-0000-000000000003', 'android', 'token-b')$$,
  'token pode ser registrado após revogação explícita'
);

reset role;
select ok(
  not exists (
    select 1 from information_schema.role_table_grants
    where table_schema = 'public' and table_name = 'device_tokens'
      and grantee in ('anon', 'authenticated')
      and privilege_type in ('INSERT', 'UPDATE', 'DELETE', 'SELECT')
  ),
  'tokens não têm DML direto'
);
select ok(
  not has_function_privilege('anon', 'public.register_device(uuid,text,text)', 'EXECUTE'),
  'anon não registra token'
);
select ok(
  not has_function_privilege('anon', 'public.revoke_device(uuid)', 'EXECUTE'),
  'anon não revoga token'
);

select * from finish();

rollback;
