begin;

create extension if not exists pgtap with schema extensions;
\ir ../_notifications.psql

select plan(18);
select has_table('private', 'notification_manual_commands',
  'comandos manuais têm auditoria idempotente');
select has_function('public', 'send_manual_notification',
  array['uuid', 'text', 'uuid', 'text', 'text', 'uuid'],
  'dono envia mensagem para público permitido');
select throws_ok(
  $$select public.send_manual_notification(
    '41000000-0000-0000-0000-000000000001', 'fleet',
    '41000000-0000-0000-0000-000000000001', 'notice', 'Teste',
    '75000000-0000-0000-0000-000000000002')$$,
  'PGRST', null, 'sem autenticação a mensagem é rejeitada'
);

select pg_temp.seed_notification_trip();
create temp table manual_test_ids(kind text primary key, id uuid) on commit drop;
grant all on manual_test_ids to authenticated;

select set_config('request.jwt.claims',
  '{"sub":"40000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
set local role authenticated;
insert into manual_test_ids(kind, id)
select 'first', public.send_manual_notification(
  '41000000-0000-0000-0000-000000000001', 'fleet',
  '41000000-0000-0000-0000-000000000001', 'notice', 'Mensagem de teste',
  '75000000-0000-0000-0000-000000000001');
select is(
  public.send_manual_notification(
    '41000000-0000-0000-0000-000000000001', 'fleet',
    '41000000-0000-0000-0000-000000000001', 'notice', 'Mensagem de teste',
    '75000000-0000-0000-0000-000000000001'),
  (select id from manual_test_ids where kind = 'first'),
  'comando manual repetido é idempotente'
);
select throws_ok(
  $$select public.send_manual_notification(
    '41000000-0000-0000-0000-000000000001', 'fleet',
    '41000000-0000-0000-0000-000000000001', 'notice', 'Mensagem diferente',
    '75000000-0000-0000-0000-000000000001')$$,
  'PGRST', null, 'replay com payload diferente é conflito'
);
select throws_ok(
  $$select public.send_manual_notification(
    '41000000-0000-0000-0000-000000000001', 'web',
    '41000000-0000-0000-0000-000000000001', 'notice', 'Teste',
    '75000000-0000-0000-0000-000000000003')$$,
  'PGRST', null, 'escopo inválido é rejeitado'
);
select throws_ok(
  $$select public.send_manual_notification(
    '41000000-0000-0000-0000-000000000001', 'fleet',
    '41000000-0000-0000-0000-000000000002', 'notice', 'Teste',
    '75000000-0000-0000-0000-000000000004')$$,
  'PGRST', null, 'frota alvo diferente é rejeitada'
);
select throws_ok(
  $$select public.send_manual_notification(
    '41000000-0000-0000-0000-000000000001', 'fleet',
    '41000000-0000-0000-0000-000000000001', 'notice', repeat('x', 2001),
    '75000000-0000-0000-0000-000000000005')$$,
  'PGRST', null, 'mensagem acima de 2000 caracteres é rejeitada'
);

reset role;
select is(
  (select count(*)::integer from public.notifications
   where id = (select id from manual_test_ids where kind = 'first')),
  1,
  'mensagem cria uma notificação durável'
);
select is(
  (select count(*)::integer from public.notification_recipients
   where notification_id = (select id from manual_test_ids where kind = 'first')),
  4,
  'público de frota inclui membros ativos sem duplicar'
);
select is(
  (select category from public.notifications
   where id = (select id from manual_test_ids where kind = 'first')),
  'notice',
  'categoria manual é preservada'
);
select ok(
  not exists (
    select 1 from information_schema.role_table_grants
    where table_schema = 'private' and table_name = 'notification_manual_commands'
      and grantee in ('anon', 'authenticated')
      and privilege_type in ('SELECT', 'INSERT', 'UPDATE', 'DELETE')
  ),
  'auditoria manual não tem DML direto'
);

-- A notification created before a driver swap must not remain readable by
-- the old driver. The replacement can read a new notification only after
-- it becomes the current assignment.
select pg_temp.create_test_user(
  '40000000-0000-0000-0000-000000000007', 'driver-b@example.test'
);
insert into public.fleet_memberships (id, fleet_id, user_id)
values (
  '42000000-0000-0000-0000-000000000007',
  '41000000-0000-0000-0000-000000000001',
  '40000000-0000-0000-0000-000000000007'
);
insert into public.fleet_membership_roles (membership_id, role)
values ('42000000-0000-0000-0000-000000000007', 'driver');

select set_config('request.jwt.claims',
  '{"sub":"40000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
set local role authenticated;
insert into manual_test_ids(kind, id)
select 'before-swap', public.send_manual_notification(
  '41000000-0000-0000-0000-000000000001', 'trip',
  (select id from operation_ids where kind = 'going'), 'notice',
  'Antes da troca', '75000000-0000-0000-0000-000000000007'
);
reset role;
select ok(
  private.can_read_notification(
    (select id from manual_test_ids where kind = 'before-swap'),
    '40000000-0000-0000-0000-000000000003'
  ),
  'motorista atual lê mensagem da própria viagem'
);
insert into public.trip_assignments (
  fleet_id, trip_id, van_id, driver_user_id, valid_from, actor_user_id, reason
) values (
  '41000000-0000-0000-0000-000000000001',
  (select id from operation_ids where kind = 'going'),
  '73000000-0000-0000-0000-000000000001',
  '40000000-0000-0000-0000-000000000007',
  clock_timestamp(), '40000000-0000-0000-0000-000000000001', 'substituição'
);
select ok(
  not private.can_read_notification(
    (select id from manual_test_ids where kind = 'before-swap'),
    '40000000-0000-0000-0000-000000000003'
  ),
  'motorista substituído perde acesso ao aviso já criado'
);

select set_config('request.jwt.claims',
  '{"sub":"40000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
set local role authenticated;
insert into manual_test_ids(kind, id)
select 'after-swap', public.send_manual_notification(
  '41000000-0000-0000-0000-000000000001', 'trip',
  (select id from operation_ids where kind = 'going'), 'notice',
  'Depois da troca', '75000000-0000-0000-0000-000000000008'
);
reset role;
select ok(
  private.can_read_notification(
    (select id from manual_test_ids where kind = 'after-swap'),
    '40000000-0000-0000-0000-000000000007'
  ),
  'motorista substituto lê avisos após a atribuição'
);

select set_config('request.jwt.claims',
  '{"sub":"40000000-0000-0000-0000-000000000003","role":"authenticated"}', true);
set local role authenticated;
select throws_ok(
  $$select public.send_manual_notification(
    '41000000-0000-0000-0000-000000000001', 'fleet',
    '41000000-0000-0000-0000-000000000001', 'notice', 'Motorista não envia',
    '75000000-0000-0000-0000-000000000006')$$,
  'PGRST', null, 'motorista não envia para frota'
);
select throws_ok(
  $$select public.send_manual_notification(
    '41000000-0000-0000-0000-000000000001', 'trip',
    (select id from operation_ids where kind = 'going'), 'delay',
    'Motorista substituído', '75000000-0000-0000-0000-000000000009')$$,
  'PGRST', null, 'motorista substituído não envia para a viagem antiga'
);

reset role;
select ok(
  not has_function_privilege('anon',
    'public.send_manual_notification(uuid,text,uuid,text,text,uuid)', 'EXECUTE'),
  'anon não envia mensagem manual'
);

select * from finish();

rollback;
