begin;

create extension if not exists pgtap with schema extensions;
\ir ../_helpers.psql
\ir ../_planning.psql
\ir ../_operations.psql

select plan(19);
select has_table('public', 'trip_passengers', 'passageiros são snapshots por viagem');
select has_table('public', 'trip_stops', 'paradas são snapshots por viagem');
select has_table('public', 'trip_assignments', 'atribuições têm histórico');
select has_table('public', 'trip_events', 'eventos operacionais são imutáveis');
select has_function('private', 'generate_trips', array['date', 'timestamp with time zone'],
  'geração invocável por data e relógio');

select lives_ok($$select pg_temp.seed_cycle_4()$$,
  'fixture aprova reservas e materializa ida e volta');
select is((select count(*)::integer from public.trips), 2,
  'uma execução por agenda direcional');
select is((select count(*)::integer from public.trip_passengers), 2,
  'cada reserva vigente vira snapshot da viagem');
select is((select count(*)::integer from public.trip_stops), 8,
  'cada execução recebe origem, escola, casa e destino');
select is((select count(*)::integer from public.trip_assignments where valid_until is null), 2,
  'cada execução recebe uma atribuição atual');
select is((select count(*)::integer from public.trip_events), 2,
  'geração registra um evento por execução');
select is((select count(*)::integer from public.transport_reservations), 10,
  'geração não altera reservas recorrentes');
select is(private.generate_trips(
  (select service_date from public.trips order by id limit 1),
  (((select service_date from public.trips order by id limit 1) - 1)::date + time '12:00') at time zone 'UTC'
), 0, 'repetição não cria outra execução');
select is((select count(*)::integer from public.trips), 2,
  'repetição preserva a unicidade por agenda/data');

select public.save_route_schedule(
  (select id from operation_ids where kind = 'going-route'), null,
  jsonb_build_object(
    'weekdays', jsonb_build_array(1, 2, 3, 4, 5),
    'starts_at', '10:00', 'ends_at', '11:00', 'ends_next_day', false,
    'timezone', 'America/Sao_Paulo',
    'valid_from', current_date + 1, 'valid_until', current_date + 90,
    'confirmation_minutes', 30
  )
);
select is(private.generate_trips(
  (select service_date from public.trips order by id limit 1),
  (((select service_date from public.trips order by id limit 1) - 1)::date + time '12:00') at time zone 'UTC'
), 1, 'duas agendas na mesma rota podem gerar execuções distintas');
select is((select count(*)::integer from public.trips
           where route_id = (select id from operation_ids where kind = 'going-route')), 2,
  'duas agendas da mesma rota não colidem');
select is(private.generate_trips(
  (select service_date from public.trips order by id limit 1),
  (((select service_date from public.trips order by id limit 1) - 1)::date + time '12:01') at time zone 'UTC'
), 0, 'segunda geração também é idempotente para a segunda agenda');
select is((select count(*)::integer from public.trip_events), 3,
  'repetição não duplica ledger de eventos');

-- A completed execution is historical; reconciliation must leave its snapshot
-- untouched when the current student address changes.
update public.trips
set status = 'completed', started_at = planned_start_at,
    ended_at = planned_start_at + interval '1 hour'
where id = (select id from operation_ids where kind = 'going');
update public.students
set street = 'Rua Nova depois da geração'
where id = (select id from planning_ids where kind = 'minor');
select is((select address_snapshot->>'street' from public.trip_stops
           where id = (select id from operation_ids where kind = 'home-stop')),
  'Rua do Aluno', 'snapshot residencial não acompanha cadastro posterior');

select * from finish();

rollback;
