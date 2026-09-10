begin;

create extension if not exists pgtap with schema extensions;
\ir ../_helpers.psql
\ir ../_planning.psql
\ir ../_operations.psql

select plan(21);
select has_function('public', 'respond_trip', array['uuid', 'uuid', 'boolean', 'uuid'],
  'participante autorizado pode responder');
select has_function('public', 'override_trip_participation',
  array['uuid', 'uuid', 'boolean', 'text', 'uuid'],
  'dono pode autorizar exceção antes da saída');
select has_function('private', 'close_confirmations', array['timestamp with time zone'],
  'fechamento usa relógio controlável');

select lives_ok($$select pg_temp.seed_cycle_4()$$,
  'fixture cria viagens futuras com confirmações pendentes');
select is((select count(*)::integer from public.trip_passengers
           where confirmation_status = 'pending'), 2,
  'passageiros começam pendentes');
select set_config('request.jwt.claims',
  '{"sub":"40000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select throws_ok($$select public.override_trip_participation(
  (select id from operation_ids where kind = 'going'),
  (select id from planning_ids where kind = 'minor'), true,
  'exceção antes do prazo', '76000000-0000-0000-0000-000000000007'
)$$, 'PGRST', null, 'override antes do prazo é rejeitado');
select set_config('request.jwt.claims',
  '{"sub":"60000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select is(public.respond_trip(
  (select id from operation_ids where kind = 'going'),
  (select id from planning_ids where kind = 'minor'), true,
  '76000000-0000-0000-0000-000000000001'
), 'confirmed', 'responsável próprio confirma antes do prazo');
select is(public.respond_trip(
  (select id from operation_ids where kind = 'going'),
  (select id from planning_ids where kind = 'minor'), true,
  '76000000-0000-0000-0000-000000000001'
), 'confirmed', 'replay da confirmação retorna o mesmo resultado');
select is((select count(*)::integer from public.trip_events
           where trip_id = (select id from operation_ids where kind = 'going')),
  2, 'replay não cria evento duplicado');
select is(public.respond_trip(
  (select id from operation_ids where kind = 'going'),
  (select id from planning_ids where kind = 'minor'), false,
  '76000000-0000-0000-0000-000000000002'
), 'declined', 'última resposta autorizada prevalece');
select is((select confirmation_status from public.trip_passengers
           where id = (select id from operation_ids where kind = 'passenger')),
  'declined', 'estado guarda a última resposta do servidor');
select is(private.close_confirmations(
  (select confirmation_deadline from public.trips
   where id = (select id from operation_ids where kind = 'going'))
), 1, 'prazo exato fecha a ida');
select is((select status from public.trips
           where id = (select id from operation_ids where kind = 'going')),
  'confirmation_closed', 'ida muda para confirmação fechada');
select throws_ok($$select public.respond_trip(
  (select id from operation_ids where kind = 'going'),
  (select id from planning_ids where kind = 'minor'), true,
  '76000000-0000-0000-0000-000000000003'
)$$, 'PGRST', null, 'resposta no prazo fechado é rejeitada');
select is(private.close_confirmations(
  (select confirmation_deadline from public.trips
   where id = (select id from operation_ids where kind = 'return'))
), 1, 'fechamento posterior fecha somente a volta restante');
select is((select confirmation_status from public.trip_passengers
           where trip_id = (select id from operation_ids where kind = 'return')),
  'expired', 'pendente sem resposta expira');
select is(private.close_confirmations(
  (select confirmation_deadline from public.trips
   where id = (select id from operation_ids where kind = 'return'))
), 0, 'fechamento repetido é idempotente');
select set_config('request.jwt.claims',
  '{"sub":"40000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select is(public.override_trip_participation(
  (select id from operation_ids where kind = 'going'),
  (select id from planning_ids where kind = 'minor'), true,
  'exceção autorizada pelo dono', '76000000-0000-0000-0000-000000000004'
), 'confirmed', 'dono altera participação após fechamento com motivo');
select is(public.override_trip_participation(
  (select id from operation_ids where kind = 'going'),
  (select id from planning_ids where kind = 'minor'), true,
  'exceção autorizada pelo dono', '76000000-0000-0000-0000-000000000004'
), 'confirmed', 'replay do override retorna o mesmo resultado');
select set_config('request.jwt.claims',
  '{"sub":"40000000-0000-0000-0000-000000000003","role":"authenticated"}', true);
select throws_ok($$select public.override_trip_participation(
  (select id from operation_ids where kind = 'return'),
  (select id from planning_ids where kind = 'minor'), true,
  'motorista não autoriza', '76000000-0000-0000-0000-000000000005'
)$$, 'PGRST', null, 'motorista não pode fazer override');
select throws_ok($$select public.override_trip_participation(
  (select id from operation_ids where kind = 'going'),
  (select id from planning_ids where kind = 'minor'), true,
  '', '76000000-0000-0000-0000-000000000006'
)$$, 'PGRST', null, 'override exige motivo');

select * from finish();

rollback;
