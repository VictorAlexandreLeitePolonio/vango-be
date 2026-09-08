begin;

create extension if not exists pgtap with schema extensions;
\ir ../_helpers.psql
\ir ../_planning.psql
\ir ../_operations.psql
\ir ../_tracking.psql

select plan(41);
select has_column('public', 'trip_passengers', 'eta_at', 'ETA guarda o horário por passageiro');
select has_column('public', 'trip_passengers', 'eta_calculated_at', 'ETA guarda a fonte temporal');
select has_column('public', 'trip_passengers', 'eta_valid_until', 'ETA tem prazo de validade');
select has_column('public', 'trip_passengers', 'eta_revision', 'ETA está vinculado à revisão');
select has_function(
  'private', 'expire_trip_locations', array['timestamp with time zone'],
  'retenção é invocável com relógio explícito'
);
select has_function(
  'private', 'evaluate_trip_proximity', array['uuid', 'timestamp with time zone'],
  'proximidade é invocável por viagem e relógio'
);
select has_table(
  'private', 'trip_location_summaries',
  'retenção preserva resumo verificável da trilha expirada'
);
select ok(
  not has_table_privilege('authenticated', 'private.trip_location_summaries', 'SELECT')
    and not has_table_privilege('authenticated', 'private.trip_location_summaries', 'INSERT'),
  'resumos permanecem restritos ao worker'
);
select ok(
  (select count(*) = 1 and coalesce(bool_and(not active), false)
   from cron.job
   where jobname = 'vango-location-retention'),
  'job diário de retenção existe uma vez e começa inativo'
);
select ok(
  not has_table_privilege('authenticated', 'public.trip_location_points', 'SELECT')
    and not has_table_privilege('authenticated', 'public.trip_location_receipts', 'SELECT'),
  'retenção não abre GPS bruto ao cliente'
);
select ok(
  not has_function_privilege(
    'authenticated',
    'private.expire_trip_locations(timestamp with time zone)',
    'EXECUTE'
  ),
  'retenção fica restrita ao worker'
);
select ok(
  not has_function_privilege(
    'authenticated',
    'private.evaluate_trip_proximity(uuid,timestamp with time zone)',
    'EXECUTE'
  ),
  'avaliação de proximidade fica restrita ao worker'
);

select pg_temp.seed_tracking();
select is(
  private.evaluate_trip_proximity(
    (select id from tracking_ids where kind = 'trip'),
    clock_timestamp()
  ),
  0,
  'sem ETA válido não cria proximidade'
);

select clock_timestamp() as retention_now \gset
insert into public.trip_location_points (
  fleet_id, trip_id, assignment_id, sequence, captured_at, received_at,
  latitude, longitude, accuracy, speed, heading, payload_hash
)
select
  t.fleet_id, t.id, a.id, point.sequence,
  :'retention_now'::timestamptz - point.age,
  :'retention_now'::timestamptz,
  -23.55, -46.63, 5, 0, 0,
  extensions.digest(point.sequence::text, 'sha256')
from public.trips t
join public.trip_assignments a on a.trip_id = t.id and a.valid_until is null
cross join (values
  (901, interval '29 days'),
  (902, interval '30 days'),
  (903, interval '31 days')
) as point(sequence, age)
where t.id = (select id from tracking_ids where kind = 'trip');
insert into public.trip_location_receipts (
  fleet_id, trip_id, assignment_id, sequence, captured_at, received_at,
  payload_hash, persisted
)
select
  t.fleet_id, t.id, a.id, 903,
  :'retention_now'::timestamptz - interval '31 days',
  :'retention_now'::timestamptz,
  extensions.digest('903', 'sha256'), true
from public.trips t
join public.trip_assignments a on a.trip_id = t.id and a.valid_until is null
where t.id = (select id from tracking_ids where kind = 'trip');
insert into public.trip_current_locations (
  trip_id, fleet_id, assignment_id, sequence, captured_at, received_at,
  latitude, longitude, accuracy, speed, heading, payload_hash
)
select
  t.id, t.fleet_id, a.id, 903,
  :'retention_now'::timestamptz - interval '31 days',
  :'retention_now'::timestamptz,
  -23.55, -46.63, 5, 0, 0,
  extensions.digest('current-903', 'sha256')
from public.trips t
join public.trip_assignments a on a.trip_id = t.id and a.valid_until is null
where t.id = (select id from tracking_ids where kind = 'trip');
select count(*) as events_before from public.trip_events
where trip_id = (select id from tracking_ids where kind = 'trip') \gset

select is(
  private.expire_trip_locations(:'retention_now'::timestamptz),
  3,
  'expiração remove ponto, recibo e projeção com mais de 30 dias'
);
select is(
  (select count(*)::integer from public.trip_location_points
   where assignment_id = (select id from tracking_ids where kind = 'assignment')),
  2,
  'amostras de 29 e exatamente 30 dias permanecem'
);
select is(
  (select count(*)::integer from public.trip_location_receipts
   where assignment_id = (select id from tracking_ids where kind = 'assignment')),
  0,
  'recibo antigo não sobrevive à retenção'
);
select is(
  (select count(*)::integer from public.trip_current_locations
   where trip_id = (select id from tracking_ids where kind = 'trip')),
  0,
  'posição corrente antiga não retém GPS indefinidamente'
);
select is(
  (select count(*)::integer from public.trip_events
   where trip_id = (select id from tracking_ids where kind = 'trip')),
  :events_before::integer,
  'retenção preserva eventos operacionais'
);
select ok(
  (select point_count = 1
      and first_captured_at = :'retention_now'::timestamptz - interval '31 days'
      and last_captured_at = :'retention_now'::timestamptz - interval '31 days'
   from private.trip_location_summaries
   where trip_id = (select id from tracking_ids where kind = 'trip')
     and assignment_id = (select id from tracking_ids where kind = 'assignment')),
  'resumo guarda contagem e primeira/última captura verificáveis'
);

insert into public.trip_location_points (
  fleet_id, trip_id, assignment_id, sequence, captured_at, received_at,
  latitude, longitude, accuracy, payload_hash
)
select
  t.fleet_id, t.id, a.id, 904,
  :'retention_now'::timestamptz - interval '31 days',
  :'retention_now'::timestamptz,
  -23.55, -46.63, 5, extensions.digest('late-904', 'sha256')
from public.trips t
join public.trip_assignments a on a.trip_id = t.id and a.valid_until is null
where t.id = (select id from tracking_ids where kind = 'trip');
select is(
  private.expire_trip_locations(:'retention_now'::timestamptz),
  1,
  'captura recebida tarde ainda expira pelo horário capturado'
);

select clock_timestamp() as eta_now \gset
select route_revision as eta_route_revision
from public.trips
where id = (select id from tracking_ids where kind = 'trip') \gset
insert into public.trip_route_calculations (
  trip_id, fleet_id, revision, status, input, input_hash, result, applied_at
)
select
  t.id, t.fleet_id, t.route_revision, 'calculated',
  private.build_trip_route_input(t.id),
  extensions.digest(private.build_trip_route_input(t.id)::text, 'sha256'),
  '{}'::jsonb, :'eta_now'::timestamptz
from public.trips t
where t.id = (select id from tracking_ids where kind = 'trip');
update public.trip_passengers
set eta_at = :'eta_now'::timestamptz + interval '5 minutes',
    eta_calculated_at = :'eta_now'::timestamptz,
    eta_valid_until = :'eta_now'::timestamptz + interval '15 minutes',
    eta_revision = :'eta_route_revision'::bigint
where id = (select id from tracking_ids where kind = 'passenger');
select is(
  private.evaluate_trip_proximity(
    (select id from tracking_ids where kind = 'trip'),
    :'eta_now'::timestamptz
  ),
  1,
  'ETA atual e dentro do limiar cria um alerta'
);
select is(
  (select count(*)::integer from public.notifications
   where event_key = 'trip:' || (select id from tracking_ids where kind = 'trip')::text
     || ':' || (select id from tracking_ids where kind = 'student')::text
     || ':approaching'),
  1,
  'alerta de proximidade usa chave única por viagem e aluno'
);
select ok(
  (select body ?& array['trip_id', 'student_id', 'eta_at', 'eta_revision']
   from public.notifications
   where event_key = 'trip:' || (select id from tracking_ids where kind = 'trip')::text
     || ':' || (select id from tracking_ids where kind = 'student')::text
     || ':approaching'),
  'corpo do alerta contém somente IDs e ETA'
);
select ok(
  (select body::text not like '%address%'
   from public.notifications
   where event_key = 'trip:' || (select id from tracking_ids where kind = 'trip')::text
     || ':' || (select id from tracking_ids where kind = 'student')::text
     || ':approaching'),
  'alerta não contém endereço residencial'
);
select id as proximity_notification_id
from public.notifications
where event_key = 'trip:' || (select id from tracking_ids where kind = 'trip')::text
  || ':' || (select id from tracking_ids where kind = 'student')::text
  || ':approaching' \gset
select is(
  private.notification_actionable(
    :'proximity_notification_id'::uuid,
    '60000000-0000-0000-0000-000000000001',
    :'eta_now'::timestamptz
  ),
  true,
  'alerta ainda é útil para o responsável antes do desembarque'
);
select is(
  private.evaluate_trip_proximity(
    (select id from tracking_ids where kind = 'trip'),
    :'eta_now'::timestamptz
  ),
  0,
  'reavaliação não duplica o mesmo alerta'
);

select set_config(
  'request.jwt.claims',
  '{"sub":"60000000-0000-0000-0000-000000000001","role":"authenticated"}',
  true
);
select ok(
  (public.get_trip_tracking((select id from tracking_ids where kind = 'trip'))->'eta') is not null,
  'projeção autorizada expõe ETA válido'
);
select ok(
  (public.get_trip_tracking((select id from tracking_ids where kind = 'trip'))->'eta') @>
    jsonb_build_array(jsonb_build_object(
      'student_id', (select id from tracking_ids where kind = 'student'),
      'eta_at', :'eta_now'::timestamptz + interval '5 minutes',
      'calculated_at', :'eta_now'::timestamptz,
      'valid_until', :'eta_now'::timestamptz + interval '15 minutes',
      'revision', :'eta_route_revision'::bigint
    )),
  'ETA retorna somente o dependente autorizado'
);

update public.trip_passengers
set eta_revision = :'eta_route_revision'::bigint + 1
where id = (select id from tracking_ids where kind = 'passenger');
select is(
  private.notification_actionable(
    :'proximity_notification_id'::uuid,
    '60000000-0000-0000-0000-000000000001',
    :'eta_now'::timestamptz
  ),
  false,
  'revisão de rota diferente invalida alerta já enfileirado'
);
select is(
  private.evaluate_trip_proximity(
    (select id from tracking_ids where kind = 'trip'),
    :'eta_now'::timestamptz
  ),
  0,
  'ETA de revisão obsoleta não gera alerta'
);
update public.trip_passengers
set eta_revision = :'eta_route_revision'::bigint
where id = (select id from tracking_ids where kind = 'passenger');

update public.trip_passengers
set operation_status = 'absent'
where id = (select id from tracking_ids where kind = 'passenger');
select is(
  private.notification_actionable(
    :'proximity_notification_id'::uuid,
    '60000000-0000-0000-0000-000000000001',
    clock_timestamp()
  ),
  false,
  'desembarque ou ausência invalida alerta antes do envio'
);
select is(
  private.evaluate_trip_proximity(
    (select id from tracking_ids where kind = 'trip'),
    clock_timestamp()
  ),
  0,
  'passageiro ausente não recebe alerta tardio'
);
update public.trip_passengers
set operation_status = 'waiting',
    eta_at = null,
    eta_calculated_at = null,
    eta_valid_until = null,
    eta_revision = null
where id = (select id from tracking_ids where kind = 'passenger');
delete from public.notifications where id = :'proximity_notification_id'::uuid;
select is(
  private.evaluate_trip_proximity(
    (select id from tracking_ids where kind = 'trip'),
    clock_timestamp()
  ),
  0,
  'modo manual e ausência de ETA não fabricam alerta'
);

select clock_timestamp() as threshold_now \gset
update public.trip_passengers
set eta_at = :'threshold_now'::timestamptz + interval '20 minutes',
    eta_calculated_at = :'threshold_now'::timestamptz,
    eta_valid_until = :'threshold_now'::timestamptz + interval '30 minutes',
    eta_revision = :'eta_route_revision'::bigint
where id = (select id from tracking_ids where kind = 'passenger');
select is(
  private.evaluate_trip_proximity(
    (select id from tracking_ids where kind = 'trip'),
    :'threshold_now'::timestamptz
  ),
  0,
  'ETA além do limiar padrão de dez minutos não alerta'
);
update public.routes
set proximity_minutes = 30
where id = (select route_id from public.trips
            where id = (select id from tracking_ids where kind = 'trip'));
select is(
  private.evaluate_trip_proximity(
    (select id from tracking_ids where kind = 'trip'),
    :'threshold_now'::timestamptz
  ),
  1,
  'limiar configurado pela rota é respeitado'
);
delete from public.notifications
where event_key = 'trip:' || (select id from tracking_ids where kind = 'trip')::text
  || ':' || (select id from tracking_ids where kind = 'student')::text
  || ':approaching';
update public.trip_passengers
set eta_at = :'threshold_now'::timestamptz + interval '5 minutes',
    eta_calculated_at = :'threshold_now'::timestamptz - interval '2 hours',
    eta_valid_until = :'threshold_now'::timestamptz - interval '1 hour',
    eta_revision = :'eta_route_revision'::bigint
where id = (select id from tracking_ids where kind = 'passenger');
select is(
  private.evaluate_trip_proximity(
    (select id from tracking_ids where kind = 'trip'),
    :'threshold_now'::timestamptz
  ),
  0,
  'ETA vencido não cria alerta retrospectivo'
);

update public.trip_passengers
set eta_at = :'threshold_now'::timestamptz + interval '5 minutes',
    eta_calculated_at = :'threshold_now'::timestamptz + interval '1 minute',
    eta_valid_until = :'threshold_now'::timestamptz + interval '30 minutes',
    eta_revision = :'eta_route_revision'::bigint
where id = (select id from tracking_ids where kind = 'passenger');
select is(
  private.evaluate_trip_proximity(
    (select id from tracking_ids where kind = 'trip'),
    :'threshold_now'::timestamptz
  ),
  0,
  'ETA calculado no futuro não alerta'
);
update public.trip_route_calculations
set status = 'pending', result = null, applied_at = null
where trip_id = (select id from tracking_ids where kind = 'trip')
  and revision = :'eta_route_revision'::bigint;
update public.trip_passengers
set eta_calculated_at = :'threshold_now'::timestamptz,
    eta_valid_until = :'threshold_now'::timestamptz + interval '30 minutes'
where id = (select id from tracking_ids where kind = 'passenger');
select is(
  private.evaluate_trip_proximity(
    (select id from tracking_ids where kind = 'trip'),
    :'threshold_now'::timestamptz
  ),
  0,
  'ETA sem cálculo calculado não alerta'
);
update public.trip_route_calculations
set status = 'calculated', result = '{}'::jsonb, applied_at = :'eta_now'::timestamptz
where trip_id = (select id from tracking_ids where kind = 'trip')
  and revision = :'eta_route_revision'::bigint;

update public.trip_passengers
set eta_at = null,
    eta_calculated_at = null,
    eta_valid_until = null,
    eta_revision = null
where id = (select id from tracking_ids where kind = 'passenger');
select ok(
  (select eta_at is null and eta_calculated_at is null
      and eta_valid_until is null and eta_revision is null
   from public.trip_passengers
   where id = (select id from tracking_ids where kind = 'passenger')),
  'modo manual mantém todos os campos de ETA nulos'
);
insert into public.trip_current_locations (
  trip_id, fleet_id, assignment_id, sequence, captured_at, received_at,
  latitude, longitude, accuracy, payload_hash
)
select
  t.id, t.fleet_id, a.id, 905, clock_timestamp(), clock_timestamp(),
  -23.55, -46.63, 5, extensions.digest('current-905', 'sha256')
from public.trips t
join public.trip_assignments a on a.trip_id = t.id and a.valid_until is null
where t.id = (select id from tracking_ids where kind = 'trip');
update public.trips
set status = 'completed', ended_at = clock_timestamp()
where id = (select id from tracking_ids where kind = 'trip');
select is(
  private.evaluate_trip_proximity(
    (select id from tracking_ids where kind = 'trip'),
    clock_timestamp()
  ),
  0,
  'viagem concluída não cria alerta'
);
select is(
  private.expire_trip_locations(:'retention_now'::timestamptz),
  1,
  'retenção remove posição corrente de viagem inativa'
);

select * from finish();
rollback;
