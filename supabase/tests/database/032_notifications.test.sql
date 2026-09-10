begin;

create extension if not exists pgtap with schema extensions;
\ir ../_helpers.psql

select plan(21);
select has_table('public', 'notifications', 'avisos são duráveis por frota');
select has_table('public', 'notification_recipients', 'leitura pertence ao destinatário');
select has_function('public', 'list_notifications', array['integer', 'integer'],
  'lista paginada de avisos próprios');
select has_function('public', 'read_notification', array['uuid'],
  'leitura idempotente');
select has_function('private', 'create_notification',
  array['uuid', 'text', 'text', 'text', 'uuid', 'jsonb', 'timestamp with time zone',
    'timestamp with time zone', 'uuid[]'],
  'criação privada resolve destinatários no servidor');

select pg_temp.seed_foundation();
create temp table notification_test_ids(kind text primary key, id uuid) on commit drop;
grant all on notification_test_ids to authenticated;

insert into notification_test_ids(kind, id)
select 'first', private.create_notification(
  '41000000-0000-0000-0000-000000000001',
  'trip:00000000-0000-0000-0000-000000000001:started',
  'trip_started', 'trip', '50000000-0000-0000-0000-000000000001',
  '{"message":"Sua viagem foi iniciada","student_id":null}'::jsonb,
  '2026-09-07 10:00:00+00', '2026-09-08 10:00:00+00',
  array[
    '40000000-0000-0000-0000-000000000001'::uuid,
    '40000000-0000-0000-0000-000000000002'::uuid,
    '40000000-0000-0000-0000-000000000002'::uuid
  ]
);

insert into notification_test_ids(kind, id)
select 'second', private.create_notification(
  '41000000-0000-0000-0000-000000000001',
  'trip:00000000-0000-0000-0000-000000000002:started',
  'notice', 'trip', '50000000-0000-0000-0000-000000000002',
  '{"message":"Segundo aviso"}'::jsonb,
  '2026-09-07 09:00:00+00', '2026-09-08 09:00:00+00',
  array['40000000-0000-0000-0000-000000000001'::uuid]
);

select is(
  (select count(*)::integer from public.notification_recipients
   where notification_id = (select id from notification_test_ids where kind = 'first')),
  2,
  'destinatários repetidos são deduplicados'
);

select set_config('request.jwt.claims',
  '{"sub":"40000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
set local role authenticated;

select is((public.list_notifications(50, 0)->>'limit')::integer, 50,
  'limite solicitado é preservado');
select is((public.list_notifications(50, 0)->>'offset')::integer, 0,
  'offset solicitado é preservado');
select is(jsonb_array_length(public.list_notifications(50, 0)->'items'), 2,
  'usuário recebe somente seus avisos');
select is(
  public.list_notifications(50, 0)->'items'->0->>'category',
  'trip_started',
  'lista ordena pelo ocorrido mais recente'
);
select ok(
  (public.list_notifications(50, 0)->'items'->0) ?&
    array['id', 'category', 'body', 'occurred_at', 'read_at', 'entity_type', 'entity_id'],
  'projeção lista somente campos contratados'
);

select is(
  public.read_notification((select id from notification_test_ids where kind = 'first'))::text,
  public.read_notification((select id from notification_test_ids where kind = 'first'))::text,
  'leitura repetida mantém o mesmo timestamp'
);
reset role;
select ok(
  (select read_at is not null from public.notification_recipients
   where notification_id = (select id from notification_test_ids where kind = 'first')
     and user_id = '40000000-0000-0000-0000-000000000001'),
  'leitura marca somente o destinatário atual'
);

select set_config('request.jwt.claims',
  '{"sub":"40000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select throws_ok(
  $$select public.list_notifications(0, 0)$$, 'PGRST', null,
  'limite zero é rejeitado'
);
select throws_ok(
  $$select public.list_notifications(51, 0)$$, 'PGRST', null,
  'limite acima de 50 é rejeitado'
);
select throws_ok(
  $$select public.list_notifications(10, -1)$$, 'PGRST', null,
  'offset negativo é rejeitado'
);

reset role;
select set_config('request.jwt.claims',
  '{"sub":"40000000-0000-0000-0000-000000000005","role":"authenticated"}', true);
set local role authenticated;
select is(jsonb_array_length(public.list_notifications(50, 0)->'items'), 0,
  'outro tenant não recebe avisos');
select throws_ok(
  $$select public.read_notification((select id from notification_test_ids where kind = 'first'))$$,
  'PGRST', null,
  'outro tenant não lê aviso alheio'
);

reset role;
update public.fleet_memberships
set status = 'left', left_at = clock_timestamp()
where fleet_id = '41000000-0000-0000-0000-000000000001'
  and user_id = '40000000-0000-0000-0000-000000000001';
select set_config('request.jwt.claims',
  '{"sub":"40000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select is(jsonb_array_length(public.list_notifications(50, 0)->'items'), 0,
  'membro removido perde acesso ao histórico privado'
);

reset role;
select ok(
  not exists (
    select 1 from information_schema.role_table_grants
    where table_schema = 'public'
      and table_name in ('notifications', 'notification_recipients')
      and grantee in ('anon', 'authenticated')
      and privilege_type in ('INSERT', 'UPDATE', 'DELETE', 'SELECT')
  ),
  'tabelas de aviso não expõem DML direto'
);
select ok(
  not has_function_privilege('authenticated',
    'private.create_notification(uuid,text,text,text,uuid,jsonb,timestamptz,timestamptz,uuid[])',
    'EXECUTE'),
  'criação de aviso fica privada'
);

select * from finish();

rollback;
