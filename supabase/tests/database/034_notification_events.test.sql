begin;

create extension if not exists pgtap with schema extensions;
\ir ../_notifications.psql

select plan(42);
select has_table('private', 'notification_worker_state',
  'ativação do worker possui corte explícito');
select has_table('private', 'notification_processed_events',
  'eventos processados são retomáveis');
select has_function('private', 'materialize_notifications',
  array['integer', 'timestamp with time zone'],
  'eventos têm processamento retomável');
select has_function('private', 'notification_actionable',
  array['uuid', 'uuid', 'timestamp with time zone'],
  'utilidade é revalidada antes do push');
select has_function('private', 'notification_trip_recipients', array['uuid'],
  'destinatários de viagem são resolvidos no servidor');
select has_function('private', 'notification_student_recipients', array['uuid', 'uuid'],
  'fatos de aluno não vazam para outros passageiros');

select pg_temp.seed_notifications();

select throws_ok(
  $$select private.materialize_notifications(0, clock_timestamp())$$,
  'PGRST', null, 'limite de materialização zero é rejeitado'
);
select throws_ok(
  $$select private.materialize_notifications(101, clock_timestamp())$$,
  'PGRST', null, 'limite de materialização acima de 100 é rejeitado'
);
select throws_ok(
  $$select private.materialize_notifications(10, null)$$,
  'PGRST', null, 'relógio de materialização é obrigatório'
);

insert into private.notification_worker_state (
  id, activation_event_id, enabled, activated_at
) values (true, 0, false, null)
on conflict (id) do update
set activation_event_id = excluded.activation_event_id,
    enabled = excluded.enabled,
    activated_at = excluded.activated_at;
select is(
  private.materialize_notifications(10, '2026-09-07 10:00:00+00'),
  0,
  'worker desativado não materializa eventos'
);
select is(
  (select activation_event_id from private.notification_worker_state where id = true),
  0::bigint,
  'corte de ativação permanece fixo'
);

create temp table notification_event_ids(id bigint primary key) on commit drop;
insert into notification_event_ids(id)
select private.append_trip_event(
  (select id from operation_ids where kind = 'going'),
  '76000000-0000-0000-0000-000000000001',
  'trip_started', '{}'::jsonb, '2026-09-07 10:00:00+00'
);
update private.notification_worker_state
set activation_event_id = (select min(id) from notification_event_ids) - 1,
    enabled = true,
    activated_at = '2026-09-07 10:00:00+00';
select is(
  private.materialize_notifications(10, '2026-09-07 10:00:00+00'),
  1,
  'evento após o corte é materializado uma vez'
);
select is(
  private.materialize_notifications(10, '2026-09-07 10:00:01+00'),
  0,
  'reprocessamento não duplica evento'
);
select is(
  (select count(*)::integer from private.notification_processed_events
   where event_id = (select id from notification_event_ids)),
  1,
  'evento materializado fica marcado na mesma transação'
);
select is(
  (select count(*)::integer from public.notifications
   where event_key = 'trip_event:' || (select id from notification_event_ids)::text),
  1,
  'materialização cria uma caixa durável'
);
select ok(
  not has_function_privilege(
    'authenticated',
    'private.materialize_notifications(integer,timestamptz)',
    'EXECUTE'
  ),
  'materialização fica restrita ao worker'
);

-- A school stop may serve several passengers, while a home stop belongs to
-- one student.  The fixture keeps the two families separate to prove that
-- event materialization does not fall back to every trip recipient.
select pg_temp.create_test_user(
  '40000000-0000-0000-0000-000000000006', 'guardian-b@example.test'
);
insert into public.fleet_memberships (id, fleet_id, user_id)
values (
  '42000000-0000-0000-0000-000000000006',
  '41000000-0000-0000-0000-000000000001',
  '40000000-0000-0000-0000-000000000006'
);
insert into public.fleet_membership_roles (membership_id, role)
values ('42000000-0000-0000-0000-000000000006', 'guardian');
insert into public.schools (
  id, provider, external_id, institution_type, name, postal_code, street,
  street_number, neighborhood, city_name, city_ibge_code, state_code
) values
  (
    '85000000-0000-0000-0000-000000000001', 'inep', 'events-school-a',
    'school', 'Escola Eventos A', '18000000', 'Rua Escola A', '1', 'Centro',
    'Cidade Teste', '3550000', 'SP'
  ),
  (
    '85000000-0000-0000-0000-000000000002', 'inep', 'events-school-b',
    'school', 'Escola Eventos B', '18000000', 'Rua Escola B', '2', 'Centro',
    'Cidade Teste', '3550000', 'SP'
  );
insert into public.fleet_service_schools (fleet_id, school_id, created_by)
values
  ('41000000-0000-0000-0000-000000000001',
   '85000000-0000-0000-0000-000000000001',
   '40000000-0000-0000-0000-000000000001'),
  ('41000000-0000-0000-0000-000000000001',
   '85000000-0000-0000-0000-000000000002',
   '40000000-0000-0000-0000-000000000001');
insert into public.students (
  id, student_type, full_name, birth_date, postal_code, street,
  street_number, neighborhood, city_name, city_ibge_code, state_code, created_by
) values
  (
    '86000000-0000-0000-0000-000000000001', 'minor', 'Aluno Evento A',
    current_date - 10 * 365, '18000000', 'Rua Aluno A', '10', 'Centro',
    'Cidade Teste', '3550000', 'SP',
    '40000000-0000-0000-0000-000000000001'
  ),
  (
    '86000000-0000-0000-0000-000000000002', 'minor', 'Aluno Evento B',
    current_date - 11 * 365, '18000000', 'Rua Aluno B', '11', 'Centro',
    'Cidade Teste', '3550000', 'SP',
    '40000000-0000-0000-0000-000000000001'
  );
insert into public.student_guardians (
  student_id, guardian_user_id, is_primary
) values
  (
    '86000000-0000-0000-0000-000000000001',
    '40000000-0000-0000-0000-000000000006', true
  ),
  (
    '86000000-0000-0000-0000-000000000002',
    '40000000-0000-0000-0000-000000000004', true
  );
insert into public.fleet_join_requests (
  id, fleet_id, requester_user_id, student_id, school_id, origin, shift,
  directions, weekdays, postal_code, street, street_number, neighborhood,
  city_name, city_ibge_code, state_code, status, decided_by, decided_at
) values
  (
    '87000000-0000-0000-0000-000000000001',
    '41000000-0000-0000-0000-000000000001',
    '40000000-0000-0000-0000-000000000006',
    '86000000-0000-0000-0000-000000000001',
    '85000000-0000-0000-0000-000000000001', 'marketplace', 'morning',
    array['going']::text[], array[1]::smallint[], '18000000', 'Rua Aluno A',
    '10', 'Centro', 'Cidade Teste', '3550000', 'SP', 'approved',
    '40000000-0000-0000-0000-000000000001', clock_timestamp()
  ),
  (
    '87000000-0000-0000-0000-000000000002',
    '41000000-0000-0000-0000-000000000001',
    '40000000-0000-0000-0000-000000000004',
    '86000000-0000-0000-0000-000000000002',
    '85000000-0000-0000-0000-000000000002', 'marketplace', 'morning',
    array['going']::text[], array[1]::smallint[], '18000000', 'Rua Aluno B',
    '11', 'Centro', 'Cidade Teste', '3550000', 'SP', 'approved',
    '40000000-0000-0000-0000-000000000001', clock_timestamp()
  );
insert into public.fleet_enrollments (
  id, fleet_id, student_id, source_request_id, school_id, shift
) values
  (
    '88000000-0000-0000-0000-000000000001',
    '41000000-0000-0000-0000-000000000001',
    '86000000-0000-0000-0000-000000000001',
    '87000000-0000-0000-0000-000000000001',
    '85000000-0000-0000-0000-000000000001', 'morning'
  ),
  (
    '88000000-0000-0000-0000-000000000002',
    '41000000-0000-0000-0000-000000000001',
    '86000000-0000-0000-0000-000000000002',
    '87000000-0000-0000-0000-000000000002',
    '85000000-0000-0000-0000-000000000002', 'morning'
  );
insert into public.trip_passengers (
  id, fleet_id, trip_id, enrollment_id, student_id, school_id
) values
  (
    '89000000-0000-0000-0000-000000000001',
    '41000000-0000-0000-0000-000000000001',
    (select id from operation_ids where kind = 'going'),
    '88000000-0000-0000-0000-000000000001',
    '86000000-0000-0000-0000-000000000001',
    '85000000-0000-0000-0000-000000000001'
  ),
  (
    '89000000-0000-0000-0000-000000000002',
    '41000000-0000-0000-0000-000000000001',
    (select id from operation_ids where kind = 'going'),
    '88000000-0000-0000-0000-000000000002',
    '86000000-0000-0000-0000-000000000002',
    '85000000-0000-0000-0000-000000000002'
  );
insert into public.trip_stops (
  id, fleet_id, trip_id, kind, school_id, position, address_snapshot
) values
  (
    '8a000000-0000-0000-0000-000000000001',
    '41000000-0000-0000-0000-000000000001',
    (select id from operation_ids where kind = 'going'),
    'school', '85000000-0000-0000-0000-000000000001', 100001,
    '{"label":"Escola Eventos A"}'::jsonb
  );
insert into public.trip_stops (
  id, fleet_id, trip_id, kind, student_id, position, address_snapshot
) values
  (
    '8a000000-0000-0000-0000-000000000002',
    '41000000-0000-0000-0000-000000000001',
    (select id from operation_ids where kind = 'going'),
    'home', '86000000-0000-0000-0000-000000000001', 1001,
    '{"label":"Casa do aluno"}'::jsonb
  );

select is(
  private.materialize_notifications(
    10,
    (select confirmation_deadline - interval '5 minutes'
     from public.trips where id = (select id from operation_ids where kind = 'going'))
  ),
  2,
  'um lembrete é criado por aluno pendente'
);
select is(
  private.materialize_notifications(
    10,
    (select confirmation_deadline - interval '5 minutes'
     from public.trips where id = (select id from operation_ids where kind = 'going'))
  ),
  0,
  'lembretes existentes não são repetidos no mesmo tick'
);
select ok(
  exists (
    select 1 from public.notifications n
    where n.event_key = 'confirmation_reminder:' ||
      (select id from operation_ids where kind = 'going')::text ||
      ':86000000-0000-0000-0000-000000000001'
      and n.category = 'confirmation_reminder'
      and n.body->>'student_id' = '86000000-0000-0000-0000-000000000001'
  ),
  'lembrete identifica a viagem e o aluno sem texto privado'
);
select ok(
  exists (
    select 1 from public.notification_recipients nr
    join public.notifications n on n.id = nr.notification_id
    where n.category = 'confirmation_reminder'
      and nr.user_id = '40000000-0000-0000-0000-000000000006'
  ),
  'lembrete alcança o responsável relacionado'
);
update public.trip_passengers
set confirmation_status = 'confirmed',
    confirmation_by = '40000000-0000-0000-0000-000000000006',
    confirmation_at = clock_timestamp()
where id = '89000000-0000-0000-0000-000000000001';
select ok(
  not private.notification_actionable(
    (select n.id from public.notifications n
     where n.category = 'confirmation_reminder' limit 1),
    '40000000-0000-0000-0000-000000000006',
    clock_timestamp()
  ),
  'lembrete enfileirado é suprimido após confirmação'
);

create temp table scoped_event_ids(kind text primary key, id bigint) on commit drop;
insert into scoped_event_ids(kind, id)
select 'school', private.append_trip_event(
  (select id from operation_ids where kind = 'going'),
  '8b000000-0000-0000-0000-000000000001',
  'school_reached',
  jsonb_build_object('stop_id', '8a000000-0000-0000-0000-000000000001'),
  clock_timestamp()
);
select is(
  private.materialize_notifications(10, clock_timestamp()),
  1,
  'chegada à escola é materializada'
);
select ok(
  exists (
    select 1 from public.notification_recipients nr
    join public.notifications n on n.id = nr.notification_id
    where n.event_key = 'trip_event:' || (select id from scoped_event_ids where kind = 'school')::text
      and nr.user_id = '40000000-0000-0000-0000-000000000006'
  ),
  'chegada à escola alcança somente família do aluno relacionado'
);
select ok(
  not exists (
    select 1 from public.notification_recipients nr
    join public.notifications n on n.id = nr.notification_id
    where n.event_key = 'trip_event:' || (select id from scoped_event_ids where kind = 'school')::text
      and nr.user_id = '40000000-0000-0000-0000-000000000004'
  ),
  'chegada à escola não alcança a família de outra escola'
);

insert into scoped_event_ids(kind, id)
select 'home', private.append_trip_event(
  (select id from operation_ids where kind = 'going'),
  '8b000000-0000-0000-0000-000000000002',
  'trip_stop_reached',
  jsonb_build_object('stop_id', '8a000000-0000-0000-0000-000000000002'),
  clock_timestamp()
);
select is(
  private.materialize_notifications(10, clock_timestamp()),
  1,
  'chegada à casa é materializada'
);
select is(
  (select count(*)::integer
   from public.notification_recipients nr
   join public.notifications n on n.id = nr.notification_id
   where n.event_key = 'trip_event:' || (select id from scoped_event_ids where kind = 'home')),
  1,
  'chegada à casa fica restrita ao aluno próprio'
);

create temp table context_notification_ids(id uuid) on commit drop;
insert into context_notification_ids(id)
select private.create_notification(
  '41000000-0000-0000-0000-000000000001',
  'context:trip-general', 'trip_started', 'trip',
  (select id from operation_ids where kind = 'going'),
  '{"message":"Atualização da viagem"}'::jsonb,
  clock_timestamp(), clock_timestamp() + interval '24 hours',
  array['40000000-0000-0000-0000-000000000006'::uuid]
);
select ok(
  private.can_read_notification(
    (select id from context_notification_ids),
    '40000000-0000-0000-0000-000000000006'
  ),
  'responsável lê aviso geral da viagem por vínculo de passageiro'
);

insert into scoped_event_ids(kind, id)
select 'override', private.append_trip_event(
  (select id from operation_ids where kind = 'going'),
  '8b000000-0000-0000-0000-000000000003',
  'participation_overridden',
  jsonb_build_object('student_id', '86000000-0000-0000-0000-000000000001'),
  (select confirmation_deadline + interval '1 hour'
   from public.trips where id = (select id from operation_ids where kind = 'going'))
);
select is(
  private.materialize_notifications(10, clock_timestamp()),
  1,
  'alteração posterior ao prazo é materializada'
);
select ok(
  exists (
    select 1 from public.notifications n
    where n.event_key = 'trip_event:' || (select id from scoped_event_ids where kind = 'override')::text
      and n.expires_at = n.occurred_at + interval '24 hours'
  ),
  'fato posterior ao prazo mantém janela factual de vinte e quatro horas'
);

insert into scoped_event_ids(kind, id)
select 'incident', private.append_trip_event(
  (select id from operation_ids where kind = 'going'),
  '8b000000-0000-0000-0000-000000000004',
  'incident_reported',
  jsonb_build_object(
    'incident_id', '8c000000-0000-0000-0000-000000000001',
    'description', 'DETALHE PRIVADO DA OCORRÊNCIA',
    'note_hash', 'hash-privado'
  ),
  clock_timestamp()
);
select is(
  private.materialize_notifications(10, clock_timestamp()),
  1,
  'ocorrência operacional é materializada'
);
select ok(
  exists (
    select 1 from public.notifications n
    where n.event_key = 'trip_event:' ||
        (select id from scoped_event_ids where kind = 'incident')::text
      and n.category = 'incident'
      and n.body->>'message' = 'Uma ocorrência foi registrada na viagem.'
      and not n.body ? 'description'
      and not n.body ? 'note_hash'
  ),
  'aviso de ocorrência contém somente texto público'
);
select ok(
  exists (
    select 1 from public.notifications n
    where n.event_key = 'trip_event:' ||
        (select id from scoped_event_ids where kind = 'incident')::text
      and n.expires_at = n.occurred_at + interval '24 hours'
  ),
  'ocorrência mantém janela factual de vinte e quatro horas'
);
select ok(
  exists (
    select 1
    from public.notification_recipients nr
    join public.notifications n on n.id = nr.notification_id
    where n.event_key = 'trip_event:' ||
        (select id from scoped_event_ids where kind = 'incident')::text
  ),
  'ocorrência alcança o público operacional da viagem'
);
select is(
  private.materialize_notifications(10, clock_timestamp()),
  0,
  'ocorrência processada não duplica a caixa'
);

select set_config(
  'request.jwt.claims',
  '{"sub":"40000000-0000-0000-0000-000000000006","role":"authenticated"}',
  true
);
set local role authenticated;
select is(
  public.update_student(
    '86000000-0000-0000-0000-000000000001', 'Aluno Evento A',
    current_date - 10 * 365, '18000000', 'Rua Aluno A Atualizada', '10',
    null, 'Centro', 'Cidade Teste', '3550000', 'SP', null, null
  ),
  '86000000-0000-0000-0000-000000000001'::uuid,
  'alteração do endereço mantém o comando de domínio'
);
reset role;
select ok(
  exists (
    select 1 from public.notifications n
    where n.category = 'address_updated'
      and n.body->'changed_fields' ? 'street'
      and not n.body ? 'street'
  ),
  'alteração de endereço cria aviso sem copiar endereço'
);
select ok(
  not exists (
    select 1 from public.notification_recipients nr
    join public.notifications n on n.id = nr.notification_id
    where n.category = 'address_updated'
      and nr.user_id = '40000000-0000-0000-0000-000000000006'
  ),
  'alteração de endereço não envia detalhe ao responsável'
);

select set_config(
  'request.jwt.claims',
  '{"sub":"40000000-0000-0000-0000-000000000001","role":"authenticated"}',
  true
);
set local role authenticated;
select is(
  public.update_enrollment_school(
    '88000000-0000-0000-0000-000000000001',
    '85000000-0000-0000-0000-000000000002'
  ),
  '88000000-0000-0000-0000-000000000001'::uuid,
  'alteração de escola mantém o comando de domínio'
);
reset role;
select ok(
  exists (
    select 1 from public.notifications n
    where n.category = 'school_updated'
      and n.body->>'student_id' = '86000000-0000-0000-0000-000000000001'
  ),
  'alteração de escola cria aviso para a próxima execução'
);
select ok(
  exists (
    select 1 from public.notification_recipients nr
    join public.notifications n on n.id = nr.notification_id
    where n.category = 'school_updated'
      and nr.user_id in (
        '40000000-0000-0000-0000-000000000001',
        '40000000-0000-0000-0000-000000000003'
      )
  ),
  'alteração de escola alcança operação da próxima viagem'
);

-- Keeping another dependent in the fleet must not preserve access to a
-- notification for the relationship that was removed.
insert into public.student_guardians (student_id, guardian_user_id, is_primary)
values (
  '86000000-0000-0000-0000-000000000002',
  '40000000-0000-0000-0000-000000000006', false
);
update public.student_guardians
set status = 'removed', removed_at = clock_timestamp()
where student_id = '86000000-0000-0000-0000-000000000001'
  and guardian_user_id = '40000000-0000-0000-0000-000000000006';
select ok(
  not private.can_read_notification(
    (select n.id from public.notifications n
     where n.event_key = 'trip_event:' ||
       (select id from scoped_event_ids where kind = 'school')::text),
    '40000000-0000-0000-0000-000000000006'
  ),
  'remoção do dependente revoga o aviso contextual mesmo com outro vínculo'
);
select ok(
  private.can_view_student(
    '86000000-0000-0000-0000-000000000002',
    '40000000-0000-0000-0000-000000000006'
  ),
  'outro vínculo do responsável continua independente'
);

select * from finish();

rollback;
