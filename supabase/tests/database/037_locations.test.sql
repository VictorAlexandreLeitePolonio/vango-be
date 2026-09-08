begin;

create extension if not exists pgtap with schema extensions;
\ir ../_helpers.psql
\ir ../_planning.psql
\ir ../_operations.psql
\ir ../_tracking.psql

select plan(31);
select has_table('public', 'trip_location_points', 'GPS bruto tem histórico próprio');
select has_table('public', 'trip_current_locations', 'GPS atual é separado do histórico');
select has_function(
  'public',
  'ingest_trip_locations',
  array['uuid', 'uuid', 'jsonb', 'boolean'],
  'GPS entra por comando validado'
);
select has_function(
  'private',
  'can_track_trip',
  array['uuid', 'uuid'],
  'autorização de rastreamento é privada'
);
select throws_ok(
  $$select public.ingest_trip_locations(
    '76000000-0000-0000-0000-000000000001',
    '76000000-0000-0000-0000-000000000002',
    '[]'::jsonb,
    true
  )$$,
  'PGRST',
  null,
  'viagem inexistente não aceita GPS'
);

select pg_temp.seed_tracking();
select is(
  private.can_track_trip(
    (select id from tracking_ids where kind = 'trip'),
    '40000000-0000-0000-0000-000000000001'
  ),
  true,
  'owner acompanha viagem ativa'
);
select is(
  private.can_track_trip(
    (select id from tracking_ids where kind = 'trip'),
    '60000000-0000-0000-0000-000000000001'
  ),
  true,
  'responsável confirmado acompanha antes do desembarque'
);

select set_config(
  'request.jwt.claims',
  '{"sub":"40000000-0000-0000-0000-000000000003","role":"authenticated"}',
  true
);
select is(
  (public.ingest_trip_locations(
    (select id from tracking_ids where kind = 'trip'),
    (select id from tracking_ids where kind = 'assignment'),
    jsonb_build_array(jsonb_build_object(
      'sequence', 1,
      'captured_at', clock_timestamp(),
      'latitude', -23.55,
      'longitude', -46.63,
      'accuracy', 5,
      'speed', 2,
      'heading', 0
    )),
    true
  )->>'current_updated'),
  '1',
  'GPS atualiza a posição corrente'
);
select is(
  (select count(*)::text from public.trip_location_points
   where assignment_id = (select id from tracking_ids where kind = 'assignment')),
  '1',
  'GPS ao vivo só persiste a amostra inicial'
);
select is(
  (select persisted::text from public.trip_location_receipts
   where assignment_id = (select id from tracking_ids where kind = 'assignment')
     and sequence = 1),
  'true',
  'recibo da amostra inicial marca persistência'
);
select pg_sleep(1.1);
select is(
  (public.ingest_trip_locations(
    (select id from tracking_ids where kind = 'trip'),
    (select id from tracking_ids where kind = 'assignment'),
    jsonb_build_array(jsonb_build_object(
      'sequence', 2,
      'captured_at', (select captured_at from public.trip_location_receipts where assignment_id=(select id from tracking_ids where kind='assignment') and sequence=1),
      'latitude', -23.54,
      'longitude', -46.62,
      'accuracy', 5,
      'speed', 2,
      'heading', 0
    )),
    true
  )->>'accepted'),
  '1',
  'GPS ao vivo atualiza antes da próxima amostra persistida'
);
select is(
  (select count(*)::text from public.trip_location_points
   where assignment_id = (select id from tracking_ids where kind = 'assignment')),
  '1',
  'amostra ao vivo curta não infla o histórico'
);
select is(
  (select persisted::text from public.trip_location_receipts
   where assignment_id = (select id from tracking_ids where kind = 'assignment')
     and sequence = 2),
  'false',
  'recibo separa amostra ainda não persistida'
);
select is(
  (public.ingest_trip_locations(
    (select id from tracking_ids where kind = 'trip'),
    (select id from tracking_ids where kind = 'assignment'),
    jsonb_build_array(jsonb_build_object(
      'sequence', 2,
      'captured_at', (select captured_at from public.trip_location_receipts
        where assignment_id = (select id from tracking_ids where kind = 'assignment')
          and sequence = 2),
      'latitude', -23.54,
      'longitude', -46.62,
      'accuracy', 5,
      'speed', 2,
      'heading', 0
    )),
    true
  )->>'duplicates'),
  '1',
  'recibo não persistido também deduplica repetição ao vivo'
);
select is(
  (public.ingest_trip_locations(
    (select id from tracking_ids where kind = 'trip'),
    (select id from tracking_ids where kind = 'assignment'),
    jsonb_build_array(jsonb_build_object(
      'sequence', 2,
      'captured_at', (select captured_at from public.trip_location_receipts
        where assignment_id = (select id from tracking_ids where kind = 'assignment')
          and sequence = 2),
      'latitude', -23.54,
      'longitude', -46.62,
      'accuracy', 5,
      'speed', 2,
      'heading', 0
    )),
    false
  )->>'duplicates'),
  '1',
  'replay histórico do recibo continua idempotente'
);
select is(
  (select count(*)::text from public.trip_location_points
   where assignment_id = (select id from tracking_ids where kind = 'assignment')),
  '1',
  'replay não ignora a amostragem de 30 segundos'
);
select is(
  (public.ingest_trip_locations(
    (select id from tracking_ids where kind = 'trip'),
    (select id from tracking_ids where kind = 'assignment'),
    jsonb_build_array(jsonb_build_object(
      'sequence', 1,
      'captured_at', (select captured_at from public.trip_location_points limit 1),
      'latitude', -23.55,
      'longitude', -46.63,
      'accuracy', 5,
      'speed', 2,
      'heading', 0
    )),
    true
  )->>'duplicates'),
  '1',
  'repetição idêntica é idempotente'
);
select throws_ok(
  $$select public.ingest_trip_locations(
    (select id from tracking_ids where kind = 'trip'),
    (select id from tracking_ids where kind = 'assignment'),
    jsonb_build_array(jsonb_build_object(
      'sequence', 1, 'captured_at', clock_timestamp(),
      'latitude', -22.0, 'longitude', -46.63, 'accuracy', 5,
      'speed', 2, 'heading', 0
    )), true)$$,
  'PGRST', null,
  'repetição com payload diferente é conflito'
);
select throws_ok(
  $$select public.ingest_trip_locations(
    (select id from tracking_ids where kind = 'trip'),
    (select id from tracking_ids where kind = 'assignment'),
    jsonb_build_array(jsonb_build_object(
      'sequence', 3, 'captured_at', clock_timestamp(),
      'latitude', 91, 'longitude', -46.63, 'accuracy', 5,
      'speed', 2, 'heading', 0
    )), true)$$,
  'PGRST', null,
  'coordenada impossível é rejeitada'
);
select throws_ok(
  $$select public.ingest_trip_locations(
    (select id from tracking_ids where kind = 'trip'),
    (select id from tracking_ids where kind = 'assignment'),
    jsonb_build_array(jsonb_build_object(
      'sequence', 2, 'captured_at', clock_timestamp(),
      'latitude', -23.55, 'longitude', -46.63, 'accuracy', 5,
      'speed', 2, 'heading', 360
    )), true)$$,
  'PGRST', null,
  'heading 360 é rejeitado'
);
select throws_ok(
  $$select public.ingest_trip_locations(
    (select id from tracking_ids where kind = 'trip'),
    (select id from tracking_ids where kind = 'assignment'),
    jsonb_build_array(jsonb_build_object(
      'sequence', 2, 'captured_at', clock_timestamp(),
      'latitude', -23.55, 'longitude', -46.63, 'accuracy', 5,
      'speed', -1, 'heading', 0
    )), true)$$,
  'PGRST', null,
  'velocidade negativa é rejeitada'
);
select throws_ok(
  $$select public.ingest_trip_locations(
    (select id from tracking_ids where kind = 'trip'),
    (select id from tracking_ids where kind = 'assignment'),
    (select jsonb_agg(jsonb_build_object(
      'sequence', value, 'captured_at', clock_timestamp(),
      'latitude', -23.55, 'longitude', -46.63, 'accuracy', 5,
      'speed', 2, 'heading', 0
    )) from generate_series(1, 201) values(value)), true)$$,
  'PGRST', null,
  'lote acima de 200 pontos é rejeitado'
);
select throws_ok(
  $$select public.ingest_trip_locations(
    (select id from tracking_ids where kind = 'trip'),
    (select id from tracking_ids where kind = 'assignment'),
    jsonb_build_array(jsonb_build_object(
      'sequence', 2, 'captured_at', clock_timestamp() + interval '3 minutes',
      'latitude', -23.55, 'longitude', -46.63, 'accuracy', 5,
      'speed', 2, 'heading', 0
    )), true)$$,
  'PGRST', null,
  'captura futura além da tolerância é rejeitada'
);
select is(
  (public.ingest_trip_locations(
    (select id from tracking_ids where kind = 'trip'),
    (select id from tracking_ids where kind = 'assignment'),
    jsonb_build_array(jsonb_build_object(
      'sequence', 3,
      'captured_at', clock_timestamp() - interval '1 minute',
      'latitude', -23.54,
      'longitude', -46.62,
      'accuracy', 6,
      'speed', null,
      'heading', null
    )),
    false
  )->>'ignored'),
  '1',
  'lote histórico não substitui posição corrente'
);
select is(
  private.can_track_trip(
    (select id from tracking_ids where kind = 'trip'),
    '60000000-0000-0000-0000-000000000001'
  ),
  true,
  'histórico GPS não revoga responsável elegível'
);

-- An offline batch can arrive newest first.  All four points below share a
-- capture bucket but use distinct receipt sequences; only one history sample
-- may be retained while every receipt remains idempotency evidence.
update public.trips
set started_at = clock_timestamp() - interval '10 minutes'
where id = (select id from tracking_ids where kind = 'trip');
update public.trip_assignments
set valid_from = clock_timestamp() - interval '10 minutes'
where id = (select id from tracking_ids where kind = 'assignment');
select date_bin('30 seconds', clock_timestamp(), 'epoch'::timestamptz)
  - interval '8 minutes' as descending_bucket \gset
select is(
  (public.ingest_trip_locations(
    (select id from tracking_ids where kind = 'trip'),
    (select id from tracking_ids where kind = 'assignment'),
    jsonb_build_array(
      jsonb_build_object(
        'sequence', 2104,
        'captured_at', :'descending_bucket'::timestamptz + interval '13 seconds',
        'latitude', -23.50, 'longitude', -46.60, 'accuracy', 5
      ),
      jsonb_build_object(
        'sequence', 2103,
        'captured_at', :'descending_bucket'::timestamptz + interval '9 seconds',
        'latitude', -23.51, 'longitude', -46.61, 'accuracy', 5
      ),
      jsonb_build_object(
        'sequence', 2102,
        'captured_at', :'descending_bucket'::timestamptz + interval '5 seconds',
        'latitude', -23.52, 'longitude', -46.62, 'accuracy', 5
      ),
      jsonb_build_object(
        'sequence', 2101,
        'captured_at', :'descending_bucket'::timestamptz + interval '1 second',
        'latitude', -23.53, 'longitude', -46.63, 'accuracy', 5
      )
    ),
    false
  )->>'accepted'),
  '4',
  'lote offline fora de ordem aceita todos os recibos'
);
select is(
  (select count(*)::text from public.trip_location_points
   where assignment_id = (select id from tracking_ids where kind = 'assignment')
     and sequence between 2101 and 2104),
  '1',
  'lote offline invertido respeita uma amostra por janela de 30 segundos'
);
select is(
  (select count(*)::text from public.trip_location_receipts
   where assignment_id = (select id from tracking_ids where kind = 'assignment')
     and sequence between 2101 and 2104),
  '4',
  'lote offline invertido preserva todos os recibos para deduplicação'
);

-- Event persistence is additional to regular sampling; offline facts must not
-- be annotated using the current vehicle position.
delete from public.trip_location_points where (assignment_id,sequence) in
  (select assignment_id,sequence from public.trip_current_locations where trip_id=(select id from tracking_ids where kind='trip'));
update public.trip_location_receipts set persisted=false where (assignment_id,sequence) in
  (select assignment_id,sequence from public.trip_current_locations where trip_id=(select id from tracking_ids where kind='trip'));
select private.append_trip_event((select id from tracking_ids where kind='trip'),'78000000-0000-0000-0000-000000000001','student_boarded',
  jsonb_build_object('student_id',(select id from tracking_ids where kind='student'),'offline',true),clock_timestamp()-interval '10 seconds');
select is((select count(*) from public.trip_location_points where (assignment_id,sequence) in
  (select assignment_id,sequence from public.trip_current_locations where trip_id=(select id from tracking_ids where kind='trip'))),0::bigint,'offline event does not attach current GPS to an old fact');
select public.record_passenger_event((select id from tracking_ids where kind='trip'),(select id from tracking_ids where kind='student'),'boarded','78000000-0000-0000-0000-000000000002');
select is((select count(*) from public.trip_location_points where (assignment_id,sequence) in
  (select assignment_id,sequence from public.trip_current_locations where trip_id=(select id from tracking_ids where kind='trip'))),1::bigint,'online operational event preserves the latest recent sample');
select ok((select persisted from public.trip_location_receipts where (assignment_id,sequence) in
  (select assignment_id,sequence from public.trip_current_locations where trip_id=(select id from tracking_ids where kind='trip'))),'event persistence updates its existing receipt');

select * from finish();

rollback;
