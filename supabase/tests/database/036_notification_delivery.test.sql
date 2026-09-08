begin;

create extension if not exists pgtap with schema extensions;
\ir ../_notifications.psql

select plan(32);
select has_table('public', 'notification_deliveries', 'entrega é durável');
select has_function('public', 'claim_notification_deliveries',
  array['integer', 'uuid'], 'worker reivindica lote limitado');
select has_function('public', 'finish_notification_delivery',
  array['uuid', 'uuid', 'text', 'text', 'text', 'integer'],
  'worker conclui por concessão');
select has_function('public', 'notification_delivery_ready',
  array['uuid', 'uuid'], 'worker revalida utilidade');
select has_function('private', 'notification_retry_delay', array['integer', 'integer'],
  'backoff é calculado no banco');
select ok(
  not has_function_privilege('authenticated',
    'public.claim_notification_deliveries(integer,uuid)', 'EXECUTE'),
  'cliente não reivindica tokens'
);
select ok(
  not has_function_privilege('authenticated',
    'public.finish_notification_delivery(uuid,uuid,text,text,text,integer)', 'EXECUTE'),
  'cliente não conclui entrega'
);
select ok(
  not exists (
    select 1 from information_schema.role_table_grants
    where table_schema = 'public' and table_name = 'notification_deliveries'
      and grantee in ('anon', 'authenticated')
      and privilege_type in ('SELECT', 'INSERT', 'UPDATE', 'DELETE')
  ),
  'fila não expõe DML direto'
);

select pg_temp.seed_notifications();
create temp table delivery_test_ids(kind text primary key, value jsonb) on commit drop;
grant all on delivery_test_ids to authenticated;

select set_config('request.jwt.claims',
  '{"sub":"40000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.register_device(
  '78000000-0000-0000-0000-000000000001', 'android', 'delivery-token-a'
);
reset role;

insert into delivery_test_ids(kind, value)
select 'notification', to_jsonb(private.create_notification(
  '41000000-0000-0000-0000-000000000001',
  'delivery-test:one', 'notice', 'trip',
  (select id from operation_ids where kind = 'going'),
  '{"message":"Fila de teste"}'::jsonb,
  clock_timestamp(), clock_timestamp() + interval '24 hours',
  array['40000000-0000-0000-0000-000000000001'::uuid]
));

insert into delivery_test_ids(kind, value)
select 'claim-one', public.claim_notification_deliveries(
  10, '79000000-0000-0000-0000-000000000001'
);
select is(
  jsonb_array_length((select value from delivery_test_ids where kind = 'claim-one')),
  1,
  'claim retorna somente entrega elegível'
);
select ok(
  not ((select value->0 from delivery_test_ids where kind = 'claim-one') ? 'body'),
  'claim não retorna corpo privado'
);
select is(
  ((select value->0 from delivery_test_ids where kind = 'claim-one')->>'attempt')::integer,
  1,
  'primeira claim registra tentativa um'
);
select is(
  jsonb_array_length(public.claim_notification_deliveries(
    10, '79000000-0000-0000-0000-000000000002')),
  0,
  'segunda claim concorrente não duplica entrega'
);
select is(
  public.notification_delivery_ready(
    (((select value->0 from delivery_test_ids where kind = 'claim-one')->>'id')::uuid),
    '79000000-0000-0000-0000-000000000001'
  ),
  true,
  'concessão vigente permanece pronta'
);
select is(
  public.finish_notification_delivery(
    (((select value->0 from delivery_test_ids where kind = 'claim-one')->>'id')::uuid),
    '79000000-0000-0000-0000-000000000001',
    'retry', null, 'provider_unavailable', 10
  ),
  'retry',
  'falha temporária agenda retry'
);
select is(
  (select state from public.notification_deliveries
   where id = (((select value->0 from delivery_test_ids where kind = 'claim-one')->>'id')::uuid)),
  'pending',
  'retry libera a concessão'
);

select pg_temp.create_test_user(
  '40000000-0000-0000-0000-000000000008', 'delivery-owner@example.test'
);
insert into public.fleet_memberships (id, fleet_id, user_id)
values (
  '42000000-0000-0000-0000-000000000008',
  '41000000-0000-0000-0000-000000000001',
  '40000000-0000-0000-0000-000000000008'
);
insert into public.fleet_membership_roles (membership_id, role)
values ('42000000-0000-0000-0000-000000000008', 'driver');
select set_config('request.jwt.claims',
  '{"sub":"40000000-0000-0000-0000-000000000008","role":"authenticated"}', true);
set local role authenticated;
select public.register_device(
  '78000000-0000-0000-0000-000000000003', 'android', 'delivery-token-c'
);
reset role;
insert into delivery_test_ids(kind, value)
select 'notification-five', to_jsonb(private.create_notification(
  '41000000-0000-0000-0000-000000000001',
  'delivery-test:fifth', 'notice', 'manual',
  '40000000-0000-0000-0000-000000000008',
  '{"message":"Quinta tentativa","scope":"user","target_id":"40000000-0000-0000-0000-000000000008"}'::jsonb,
  clock_timestamp(), clock_timestamp() + interval '24 hours',
  array['40000000-0000-0000-0000-000000000008'::uuid]
));
insert into public.notification_deliveries (
  notification_id, device_id, state, attempt, next_attempt_at
)
select
  ((select value #>> '{}' from delivery_test_ids where kind = 'notification-five')::uuid),
  d.id, 'pending', 4, clock_timestamp()
from public.device_tokens d
where d.token = 'delivery-token-c';
insert into delivery_test_ids(kind, value)
select 'claim-five', public.claim_notification_deliveries(
  1, '79000000-0000-0000-0000-000000000006'
);
select is(
  jsonb_array_length((select value from delivery_test_ids where kind = 'claim-five')),
  1,
  'quinta tentativa ainda pode ser reivindicada'
);
select is(
  jsonb_array_length(public.claim_notification_deliveries(
    10, '79000000-0000-0000-0000-000000000007'
  )),
  0,
  'concorrente não rouba quinta tentativa enquanto lease está vigente'
);
select is(
  public.finish_notification_delivery(
    (((select value->0 from delivery_test_ids where kind = 'claim-five')->>'id')::uuid),
    '79000000-0000-0000-0000-000000000006',
    'sent', 'fcm-message-5', null, null
  ),
  'sent',
  'worker da quinta tentativa conclui antes da expiração'
);
update public.notification_deliveries
set next_attempt_at = clock_timestamp()
where id = (((select value->0 from delivery_test_ids where kind = 'claim-one')->>'id')::uuid);
insert into delivery_test_ids(kind, value)
select 'claim-two', public.claim_notification_deliveries(
  10, '79000000-0000-0000-0000-000000000003'
);
select is(
  jsonb_array_length((select value from delivery_test_ids where kind = 'claim-two')),
  1,
  'entrega reagendada pode ser retomada'
);
select is(
  public.finish_notification_delivery(
    (((select value->0 from delivery_test_ids where kind = 'claim-one')->>'id')::uuid),
    '79000000-0000-0000-0000-000000000001',
    'sent', 'old-worker', null, null
  ),
  'lease_lost',
  'worker antigo não conclui concessão substituída'
);
select throws_ok(
  $$select public.finish_notification_delivery(
    (((select value->0 from delivery_test_ids where kind = 'claim-two')->>'id')::uuid),
    '79000000-0000-0000-0000-000000000003',
    null, null, null, null)$$,
  'PGRST', null, 'resultado nulo é rejeitado explicitamente'
);
select is(
  public.notification_delivery_ready(
    (((select value->0 from delivery_test_ids where kind = 'claim-one')->>'id')::uuid),
    '79000000-0000-0000-0000-000000000001'
  ),
  false,
  'lease antigo deixa de estar pronto'
);
select is(
  public.finish_notification_delivery(
    (((select value->0 from delivery_test_ids where kind = 'claim-two')->>'id')::uuid),
    '79000000-0000-0000-0000-000000000003',
    'sent', 'fcm-message-1', null, null
  ),
  'sent',
  'aceite do FCM marca envio durável'
);
select is(
  (select state from public.notification_deliveries
   where id = (((select value->0 from delivery_test_ids where kind = 'claim-two')->>'id')::uuid)),
  'sent',
  'estado enviado fica terminal'
);

insert into delivery_test_ids(kind, value)
select 'notification-rotate', to_jsonb(private.create_notification(
  '41000000-0000-0000-0000-000000000001',
  'delivery-test:rotate', 'notice', 'trip',
  (select id from operation_ids where kind = 'going'),
  '{"message":"Token rotacionado"}'::jsonb,
  clock_timestamp(), clock_timestamp() + interval '24 hours',
  array['40000000-0000-0000-0000-000000000001'::uuid]
));
insert into delivery_test_ids(kind, value)
select 'claim-rotate', public.claim_notification_deliveries(
  10, '79000000-0000-0000-0000-000000000008'
);
select set_config('request.jwt.claims',
  '{"sub":"40000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.register_device(
  '78000000-0000-0000-0000-000000000001', 'android', 'delivery-token-a-rotated'
);
reset role;
select is(
  public.notification_delivery_ready(
    (((select value->0 from delivery_test_ids where kind = 'claim-rotate')->>'id')::uuid),
    '79000000-0000-0000-0000-000000000008'
  ),
  false,
  'rotação do token invalida a concessão antes do envio'
);
select is(
  public.finish_notification_delivery(
    (((select value->0 from delivery_test_ids where kind = 'claim-rotate')->>'id')::uuid),
    '79000000-0000-0000-0000-000000000008',
    'invalid_token', null, 'UNREGISTERED', null
  ),
  'suppressed',
  'token antigo não desativa a instalação rotacionada'
);
select ok(
  (select active and token = 'delivery-token-a-rotated'
   from public.device_tokens
   where user_id = '40000000-0000-0000-0000-000000000001'
     and installation_id = '78000000-0000-0000-0000-000000000001'),
  'token novo permanece ativo após invalid_token atrasado'
);

select set_config('request.jwt.claims',
  '{"sub":"40000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.register_device(
  '78000000-0000-0000-0000-000000000002', 'ios', 'delivery-token-b'
);
reset role;
insert into delivery_test_ids(kind, value)
select 'notification-invalid', to_jsonb(private.create_notification(
  '41000000-0000-0000-0000-000000000001',
  'delivery-test:invalid', 'notice', 'trip',
  (select id from operation_ids where kind = 'going'),
  '{"message":"Token inválido"}'::jsonb,
  clock_timestamp(), clock_timestamp() + interval '24 hours',
  array['40000000-0000-0000-0000-000000000001'::uuid]
));
insert into delivery_test_ids(kind, value)
select 'claim-invalid', public.claim_notification_deliveries(
  10, '79000000-0000-0000-0000-000000000004'
);
select is(
  public.finish_notification_delivery(
    (select d.id
     from public.notification_deliveries d
     join public.device_tokens device on device.id = d.device_id
     where d.notification_id =
       ((select value #>> '{}' from delivery_test_ids where kind = 'notification-invalid')::uuid)
       and device.token = 'delivery-token-b'),
    '79000000-0000-0000-0000-000000000004',
    'invalid_token', null, 'UNREGISTERED', null
  ),
  'failed',
  'token inválido conclui como falha'
);
select ok(
  (select not active from public.device_tokens where token = 'delivery-token-b'),
  'token inválido é desativado'
);

select throws_ok(
  $$select public.claim_notification_deliveries(0,
    '79000000-0000-0000-0000-000000000005')$$,
  'PGRST', null, 'limite zero é rejeitado'
);
select throws_ok(
  $$select public.claim_notification_deliveries(10, null)$$,
  'PGRST', null, 'lease ausente é rejeitado'
);
select ok(
  (select extract(epoch from private.notification_retry_delay(1, null)) >= 30
    and extract(epoch from private.notification_retry_delay(1, null)) <= 60),
  'backoff inicial usa jitter limitado no banco'
);

select * from finish();

rollback;
