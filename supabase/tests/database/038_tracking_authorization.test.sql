begin;

create extension if not exists pgtap with schema extensions;
\ir ../_helpers.psql
\ir ../_planning.psql
\ir ../_operations.psql
\ir ../_tracking.psql

select plan(24);
select has_function(
  'private', 'can_join_trip_topic', array['text', 'uuid'],
  'entrada Realtime valida época e participante'
);
select has_function(
  'private', 'rotate_trip_topic', array['uuid'],
  'rotação de época tem contrato privado'
);
select has_function(
  'public', 'get_trip_tracking', array['uuid'],
  'projeção de rastreamento tem RPC autorizado'
);
select ok(
  exists (
    select 1 from pg_policy
    where polrelid = 'realtime.messages'::regclass
      and polname = 'trip_broadcast_read'
  ),
  'broadcast usa policy de leitura privada'
);
select ok(
  not has_table_privilege('authenticated', 'public.trip_location_points', 'SELECT')
    and not has_table_privilege('authenticated', 'public.trip_current_locations', 'SELECT'),
  'GPS não fica disponível por SELECT direto'
);

select pg_temp.seed_tracking();
select set_config(
  'request.jwt.claims',
  '{"sub":"40000000-0000-0000-0000-000000000001","role":"authenticated"}',
  true
);
select (public.get_trip_tracking(
  (select id from tracking_ids where kind = 'trip')
)->>'topic') as owner_topic \gset
select (public.get_trip_tracking(
  (select id from tracking_ids where kind = 'trip')
)->>'epoch')::bigint as owner_epoch \gset

set local role authenticated;
select is(
  private.can_join_trip_topic(:'owner_topic', '40000000-0000-0000-0000-000000000001'),
  true,
  'owner entra na época atual'
);
select is(
  private.can_join_trip_topic(
    'trip:' || (select id from tracking_ids where kind = 'trip')::text || ':v' || (:owner_epoch + 1)::text,
    '40000000-0000-0000-0000-000000000001'
  ),
  false,
  'época futura não é aceita'
);
select is(
  private.can_join_trip_topic(
    replace(:'owner_topic', ':v', ':V'),
    '40000000-0000-0000-0000-000000000001'
  ),
  false,
  'tópico com nome malformado é rejeitado'
);
select is(
  private.can_join_trip_topic(
    :'owner_topic', '40000000-0000-0000-0000-000000000005'
  ),
  false,
  'membro de outra frota não entra'
);
reset role;

select set_config(
  'request.jwt.claims',
  '{"sub":"60000000-0000-0000-0000-000000000001","role":"authenticated"}',
  true
);
select (public.get_trip_tracking(
  (select id from tracking_ids where kind = 'trip')
)->>'topic') as guardian_topic \gset
select is(
  private.can_join_trip_topic(:'guardian_topic', '60000000-0000-0000-0000-000000000001'),
  true,
  'responsável confirmado entra na época atual'
);
select ok(
  (public.get_trip_tracking(
    (select id from tracking_ids where kind = 'trip')
  )->'own_stops' @> jsonb_build_array(jsonb_build_object(
    'kind', 'home', 'student_id', (select id from tracking_ids where kind = 'student')
  ))),
  'responsável recebe o ponto do próprio aluno'
);
select ok(
  public.get_trip_tracking((select id from tracking_ids where kind = 'trip'))::text
    not like '%address_snapshot%',
  'projeção não expõe snapshot de endereço'
);
select ok(
  (public.get_trip_tracking((select id from tracking_ids where kind = 'trip'))
    ?& array['trip_id', 'topic', 'epoch', 'last_position', 'stale', 'own_stops', 'schools', 'eta']),
  'projeção limitada expõe o contrato completo'
);

select set_config(
  'request.jwt.claims',
  '{"sub":"40000000-0000-0000-0000-000000000006","role":"authenticated"}',
  true
);
select throws_ok(
  $$select public.get_trip_tracking((select id from tracking_ids where kind = 'trip'))$$,
  'PGRST', null,
  'usuário desconhecido não consulta rastreamento'
);

select set_config(
  'request.jwt.claims',
  '{"sub":"40000000-0000-0000-0000-000000000001","role":"authenticated"}',
  true
);
select private.rotate_trip_topic((select id from tracking_ids where kind = 'trip'))
as manually_rotated_epoch \gset
select is(
  private.can_join_trip_topic(:'owner_topic', '40000000-0000-0000-0000-000000000001'),
  false,
  'época anterior perde a entrada após rotação'
);
select is(
  (public.get_trip_tracking((select id from tracking_ids where kind = 'trip'))
    ->>'epoch')::bigint,
  :manually_rotated_epoch::bigint,
  'RPC devolve a nova época'
);

update public.trip_passengers
set operation_status = 'absent'
where id = (select id from tracking_ids where kind = 'passenger');
select is(
  private.can_join_trip_topic(
    :'guardian_topic', '60000000-0000-0000-0000-000000000001'
  ),
  false,
  'ausência revoga responsável na época antiga'
);
select set_config(
  'request.jwt.claims',
  '{"sub":"60000000-0000-0000-0000-000000000001","role":"authenticated"}',
  true
);
select throws_ok(
  $$select public.get_trip_tracking((select id from tracking_ids where kind = 'trip'))$$,
  'PGRST', null,
  'responsável ausente não consulta rastreamento'
);

update public.trip_passengers
set operation_status = 'waiting'
where id = (select id from tracking_ids where kind = 'passenger');
select (public.get_trip_tracking(
  (select id from tracking_ids where kind = 'trip')
)->>'topic') as restored_topic \gset
select is(
  private.can_join_trip_topic(:'restored_topic', '60000000-0000-0000-0000-000000000001'),
  true,
  'relação elegível entra na época restaurada'
);

update public.fleet_memberships
set status = 'suspended', suspended_at = clock_timestamp()
where fleet_id = (select id from tracking_ids where kind = 'fleet')
  and user_id = '60000000-0000-0000-0000-000000000001';
select is(
  private.can_join_trip_topic(:'restored_topic', '60000000-0000-0000-0000-000000000001'),
  false,
  'suspensão revoga época já aberta'
);
select ok(
  (select broadcast_epoch from public.trips
   where id = (select id from tracking_ids where kind = 'trip'))
    > :manually_rotated_epoch::bigint,
  'suspensão avança a época da viagem'
);

update public.trip_assignments
set valid_until = clock_timestamp()
where id = (select id from tracking_ids where kind = 'assignment');
select ok(
  (select broadcast_epoch from public.trips
   where id = (select id from tracking_ids where kind = 'trip'))
    > :manually_rotated_epoch::bigint,
  'fim da atribuição também gira a época'
);

update public.trips
set status = 'completed',
    started_at = coalesce(started_at, clock_timestamp() - interval '1 second'),
    ended_at = clock_timestamp()
where id = (select id from tracking_ids where kind = 'trip');
select is(
  private.can_join_trip_topic(
    (select 'trip:' || id::text || ':v' || broadcast_epoch::text from public.trips
     where id = (select id from tracking_ids where kind = 'trip')),
    '40000000-0000-0000-0000-000000000001'
  ),
  false,
  'viagem encerrada não aceita novo canal'
);
select ok(
  (select count(*) from pg_trigger
   where tgrelid = 'public.trip_passengers'::regclass
     and tgname = 'trip_passengers_broadcast_epoch_revocation') = 1
    and (select count(*) from pg_trigger
   where tgrelid = 'public.student_guardians'::regclass
     and tgname = 'student_guardians_broadcast_epoch_revocation') = 1,
  'presença e vínculo de responsável têm gatilhos de revogação'
);

select * from finish();

rollback;
