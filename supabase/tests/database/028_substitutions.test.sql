begin;

create extension if not exists pgtap with schema extensions;
\ir ../_helpers.psql
\ir ../_planning.psql
\ir ../_operations.psql

select plan(31);
select has_function('public', 'substitute_trip_resources',
  array['uuid', 'uuid', 'uuid', 'text', 'uuid'],
  'troca emergencial preserva a viagem');
select has_table('public', 'trip_assignments', 'atribuições mantêm histórico');
select has_table('public', 'trip_events', 'trocas também deixam evento');

select lives_ok($$select pg_temp.seed_cycle_4()$$,
  'fixture cria viagens e reservas reais');
create temp table substitution_ids(kind text primary key, id uuid) on commit drop;
grant all on substitution_ids to authenticated;

select set_config('request.jwt.claims',
  '{"sub":"40000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
insert into substitution_ids(kind, id)
select 'replacement-van', public.save_van(
  '41000000-0000-0000-0000-000000000001', null,
  'SUB1234', 'Micro', 'Van Substituta', 30
);
select public.set_fleet_member_roles(
  '42000000-0000-0000-0000-000000000002', array['owner', 'driver']::text[]
);
insert into substitution_ids(kind, id)
select 'replacement-assignment', public.substitute_trip_resources(
  (select id from operation_ids where kind = 'going'),
  (select id from substitution_ids where kind = 'replacement-van'),
  '40000000-0000-0000-0000-000000000002',
  'motorista indisponível',
  '78000000-0000-0000-0000-000000000001'
);
select ok((select id from substitution_ids where kind = 'replacement-assignment') is not null,
  'troca retorna nova atribuição');
select is((select van_id from public.trips
           where id = (select id from operation_ids where kind = 'going')),
  (select id from substitution_ids where kind = 'replacement-van'),
  'viagem aponta para a van substituta');
select is((select driver_user_id from public.trips
           where id = (select id from operation_ids where kind = 'going')),
  '40000000-0000-0000-0000-000000000002'::uuid,
  'viagem aponta para o motorista substituto');
select is((select count(*)::integer from public.trip_assignments
           where trip_id = (select id from operation_ids where kind = 'going')
             and valid_until is null), 1,
  'há somente uma atribuição corrente');
select ok((select count(*) from public.trip_assignments
           where trip_id = (select id from operation_ids where kind = 'going')
             and valid_until is not null) = 1,
  'atribuição anterior fica encerrada no histórico');
select is((select count(*)::integer from public.trip_passengers
           where trip_id = (select id from operation_ids where kind = 'going')), 1,
  'troca não altera passageiros nem presença');
select is((select payload->>'reason' from public.trip_events
           where trip_id = (select id from operation_ids where kind = 'going')
             and kind = 'resources_substituted'),
  'motorista indisponível', 'motivo da troca fica no evento');
select is(public.substitute_trip_resources(
  (select id from operation_ids where kind = 'going'),
  (select id from substitution_ids where kind = 'replacement-van'),
  '40000000-0000-0000-0000-000000000002',
  'motorista indisponível',
  '78000000-0000-0000-0000-000000000001'
), (select id from substitution_ids where kind = 'replacement-assignment'),
  'replay devolve a mesma atribuição');
select is((select count(*)::integer from public.trip_events
           where trip_id = (select id from operation_ids where kind = 'going')
             and kind = 'resources_substituted'), 1,
  'replay não duplica evento de troca');

select throws_ok($$select public.substitute_trip_resources(
  (select id from operation_ids where kind = 'going'),
  (select id from substitution_ids where kind = 'replacement-van'),
  '40000000-0000-0000-0000-000000000001', 'troca',
  '78000000-0000-0000-0000-000000000002')$$,
  'PGRST', null, 'motorista sem papel driver é rejeitado');
select throws_ok($$select public.substitute_trip_resources(
  (select id from operation_ids where kind = 'going'),
  (select id from substitution_ids where kind = 'replacement-van'),
  '40000000-0000-0000-0000-000000000002', null,
  '78000000-0000-0000-0000-000000000003')$$,
  'PGRST', null, 'motivo vazio é rejeitado');

select set_config('request.jwt.claims',
  '{"sub":"40000000-0000-0000-0000-000000000005","role":"authenticated"}', true);
insert into substitution_ids(kind, id)
select 'other-fleet-van', public.save_van(
  '41000000-0000-0000-0000-000000000002', null,
  'OTR1234', 'Micro', 'Van Outra Frota', 30
);
select set_config('request.jwt.claims',
  '{"sub":"40000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select throws_ok($$select public.substitute_trip_resources(
  (select id from operation_ids where kind = 'going'),
  (select id from substitution_ids where kind = 'other-fleet-van'),
  '40000000-0000-0000-0000-000000000002', 'troca',
  '78000000-0000-0000-0000-000000000004')$$,
  'PGRST', null, 'van de outra frota é rejeitada');
select throws_ok($$select private.assert_van_releasable(
  (select id from substitution_ids where kind = 'replacement-van'))$$,
  'PGRST', null, 'van atribuída a viagem futura não é liberada');

-- An active trip keeps its physical resources unavailable even when another
-- execution has a planned window at a different time of day.
select set_config('request.jwt.claims',
  '{"sub":"60000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select is(public.respond_trip(
  (select id from operation_ids where kind = 'return'),
  (select id from planning_ids where kind = 'minor'), true,
  '78000000-0000-0000-0000-000000000005'
), 'confirmed', 'passageiro da volta é confirmado');
select set_config('request.jwt.claims',
  '{"sub":"40000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select is(private.close_confirmations(
  (select confirmation_deadline from public.trips
   where id = (select id from operation_ids where kind = 'return'))
), 2, 'fechamento prepara as duas execuções');
select is(public.set_trip_stop(
  (select id from public.trip_stops where trip_id = (select id from operation_ids where kind = 'return')
    and kind = 'school' limit 1), -23.5610, -46.6550, 'Escola Ciclo 3',
  (select revision from public.trips where id = (select id from operation_ids where kind = 'return'))
), ((select revision from public.trips where id = (select id from operation_ids where kind = 'return')) + 1)::bigint,
  'ponto de retorno é resolvido');
select is(public.order_trip_stops(
  (select id from operation_ids where kind = 'return'),
  (select array_agg(id order by position) from public.trip_stops
   where trip_id = (select id from operation_ids where kind = 'return')),
  (select revision from public.trips where id = (select id from operation_ids where kind = 'return')),
  'ordem da volta antes do início'
), ((select revision from public.trips where id = (select id from operation_ids where kind = 'return')) + 1)::bigint,
  'ordem da volta é definida');
select is(public.start_trip(
  (select id from operation_ids where kind = 'return'),
  '78000000-0000-0000-0000-000000000006'
), 'active', 'volta fica ativa');
select is(public.record_passenger_event(
  (select id from operation_ids where kind = 'return'),
  (select id from planning_ids where kind = 'minor'), 'boarded',
  '78000000-0000-0000-0000-000000000007'
), 'boarded', 'passageiro embarcado é preservado');
select throws_ok($$select public.substitute_trip_resources(
  (select id from operation_ids where kind = 'going'),
  (select id from planning_ids where kind = 'van'),
  '40000000-0000-0000-0000-000000000003', 'troca durante operação',
  '78000000-0000-0000-0000-000000000008')$$,
  'PGRST', null, 'recurso de viagem ativa não é cedido mesmo sem sobreposição planejada');
select is((select operation_status from public.trip_passengers
           where trip_id = (select id from operation_ids where kind = 'return')),
  'boarded', 'presença embarcada permanece intacta');

select is(public.record_passenger_event(
  (select id from operation_ids where kind = 'return'),
  (select id from planning_ids where kind = 'minor'), 'dropped_off',
  '78000000-0000-0000-0000-000000000009'
), 'dropped_off', 'passageiro da volta desembarca');
select is(public.finish_trip(
  (select id from operation_ids where kind = 'return'), false, null,
  '78000000-0000-0000-0000-000000000010'
), 'completed', 'execução ativa termina antes do teste de agenda');

-- A schedule from the previous service date crosses midnight into this trip.
-- The target resources are otherwise free, so only the adjacent window should
-- reject the substitution.
select set_fleet_member_roles(
  '42000000-0000-0000-0000-000000000004', array['driver']::text[]
);
insert into substitution_ids(kind, id)
select 'cross-midnight-van', public.save_van(
  '41000000-0000-0000-0000-000000000001', null,
  'CRZ1234', 'Micro', 'Van Janela Cruzada', 30
);
select ok((select id from substitution_ids where kind = 'cross-midnight-van') is not null,
  'van para agenda que atravessa meia-noite é criada');
insert into substitution_ids(kind, id)
select 'cross-midnight-route', public.save_route(
  '41000000-0000-0000-0000-000000000001', null,
  jsonb_build_object(
    'name', 'Rota Janela Cruzada', 'direction', 'going', 'shift', 'morning',
    'van_id', (select id from substitution_ids where kind = 'cross-midnight-van'),
    'driver_user_id', '40000000-0000-0000-0000-000000000004',
    'origin', jsonb_build_object('latitude', -23.5505, 'longitude', -46.6333, 'label', 'Origem'),
    'destination', jsonb_build_object('latitude', -23.5610, 'longitude', -46.6550, 'label', 'Destino'),
    'schools', jsonb_build_array(jsonb_build_object(
      'school_id', (select id from planning_ids where kind = 'school'), 'position', 1
    ))
  )
);
select ok((select id from substitution_ids where kind = 'cross-midnight-route') is not null,
  'rota da agenda que atravessa meia-noite é criada');
insert into substitution_ids(kind, id)
select 'cross-midnight-schedule', public.save_route_schedule(
  (select id from substitution_ids where kind = 'cross-midnight-route'), null,
  jsonb_build_object(
    'weekdays', jsonb_build_array(extract(isodow from (
      (select service_date from public.trips where id = (select id from operation_ids where kind = 'going')) - 1
    ))::smallint),
    'starts_at', '23:00', 'ends_at', '09:00', 'ends_next_day', true,
    'timezone', 'America/Sao_Paulo',
    'valid_from', ((select service_date from public.trips where id = (select id from operation_ids where kind = 'going')) - 1)::text,
    'valid_until', ((select service_date from public.trips where id = (select id from operation_ids where kind = 'going')) + 30)::text,
    'confirmation_minutes', 30
  )
);
select ok((select id from substitution_ids where kind = 'cross-midnight-schedule') is not null,
  'agenda com janela adjacente é criada');
select throws_ok($$select public.substitute_trip_resources(
  (select id from operation_ids where kind = 'going'),
  (select id from substitution_ids where kind = 'cross-midnight-van'),
  '40000000-0000-0000-0000-000000000004', 'janela cruza a meia-noite',
  '78000000-0000-0000-0000-000000000011')$$,
  'PGRST', null, 'janela da véspera que cruza meia-noite bloqueia a troca');

select * from finish();

rollback;
