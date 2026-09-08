begin;

create extension if not exists pgtap with schema extensions;
\ir ../_helpers.psql
\ir ../_planning.psql
\ir ../_operations.psql

select plan(34);
select has_function('public', 'set_trip_stop',
  array['uuid', 'numeric', 'numeric', 'text', 'bigint'],
  'dono define ponto manual antes da saída');
select has_function('public', 'order_trip_stops',
  array['uuid', 'uuid[]', 'bigint', 'text'],
  'ordem manual respeita revisão');
select has_function('public', 'start_trip', array['uuid', 'uuid'],
  'início de viagem é idempotente');
select has_function('public', 'record_passenger_event',
  array['uuid', 'uuid', 'text', 'uuid'],
  'presença usa comandos idempotentes');
select has_function('public', 'finish_trip',
  array['uuid', 'boolean', 'text', 'uuid'],
  'encerramento valida a lista de passageiros');
select has_function('public', 'mark_trip_stop_reached', array['uuid', 'uuid'],
  'chegada à parada registra evento');
select has_function('private', 'assert_trip_ready', array['uuid'],
  'início verifica recursos e revisão');

select lives_ok($$select pg_temp.seed_cycle_4()$$,
  'fixture cria execução e snapshots operacionais');

-- Add two more approved reservations only to exercise executable filtering:
-- one expired and one declined must remain in the snapshot but not block start.
do $$
declare
  v_student_id uuid;
  v_request_id uuid;
  v_enrollment_id uuid;
  v_allocations jsonb;
begin
  select jsonb_agg(jsonb_build_object(
    'schedule_id', case directions.direction
      when 'going' then (select id from planning_ids where kind = 'going-schedule')
      else (select id from planning_ids where kind = 'return-schedule')
    end,
    'weekday', weekdays.weekday::smallint,
    'direction', directions.direction
  ) order by directions.direction, weekdays.weekday)
  into v_allocations
  from (values ('going'::text), ('return'::text)) directions(direction)
  cross join lateral generate_series(1, 5) as weekdays(weekday);

  perform set_config('request.jwt.claims',
    '{"sub":"60000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
  v_student_id := public.create_minor_student(
    'Aluno Expirado', current_date - 9 * 365, '18000000', 'Rua Expirada', '20',
    null, 'Centro', 'Cidade Teste', '3550000', 'SP', -23.5506, -46.6334
  );
  v_request_id := public.submit_fleet_join_request(
    '41000000-0000-0000-0000-000000000001', v_student_id,
    (select id from planning_ids where kind = 'school'), 'morning',
    array['going', 'return']::text[], array[1, 2, 3, 4, 5]::smallint[]
  );
  perform set_config('request.jwt.claims',
    '{"sub":"40000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
  v_enrollment_id := public.approve_transport_request(
    v_request_id, v_allocations,
    (select service_date from public.trips order by id limit 1)
  );
  update public.trip_passengers
  set confirmation_status = 'expired',
      confirmation_by = '60000000-0000-0000-0000-000000000001',
      confirmation_at = clock_timestamp()
  where trip_id = (select id from operation_ids where kind = 'going')
    and enrollment_id = v_enrollment_id;

  perform set_config('request.jwt.claims',
    '{"sub":"60000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
  v_student_id := public.create_minor_student(
    'Aluno Recusado', current_date - 8 * 365, '18000000', 'Rua Recusada', '30',
    null, 'Centro', 'Cidade Teste', '3550000', 'SP', -23.5507, -46.6335
  );
  v_request_id := public.submit_fleet_join_request(
    '41000000-0000-0000-0000-000000000001', v_student_id,
    (select id from planning_ids where kind = 'school'), 'morning',
    array['going', 'return']::text[], array[1, 2, 3, 4, 5]::smallint[]
  );
  perform set_config('request.jwt.claims',
    '{"sub":"40000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
  v_enrollment_id := public.approve_transport_request(
    v_request_id, v_allocations,
    (select service_date from public.trips order by id limit 1)
  );
  update public.trip_passengers
  set confirmation_status = 'declined',
      confirmation_by = '60000000-0000-0000-0000-000000000001',
      confirmation_at = clock_timestamp()
  where trip_id = (select id from operation_ids where kind = 'going')
    and enrollment_id = v_enrollment_id;
end;
$$;

select set_config('request.jwt.claims',
  '{"sub":"60000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select is(public.respond_trip(
  (select id from operation_ids where kind = 'going'),
  (select id from planning_ids where kind = 'minor'), true,
  '77000000-0000-0000-0000-000000000001'
), 'confirmed', 'passageiro executável é confirmado');
select is(private.close_confirmations(
  (select confirmation_deadline from public.trips
   where id = (select id from operation_ids where kind = 'going'))
), 1, 'fechamento da ida ocorre antes do início');
select is((select count(*)::integer from public.trip_passengers
           where trip_id = (select id from operation_ids where kind = 'going')
             and confirmation_status in ('expired', 'declined')), 2,
  'estados não executáveis permanecem no snapshot');

select set_config('request.jwt.claims',
  '{"sub":"40000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select is(public.set_trip_stop(
  (select id from operation_ids where kind = 'school-stop'), -23.5610, -46.6550,
  'Escola Ciclo 3',
  (select revision from public.trips where id = (select id from operation_ids where kind = 'going'))
), ((select revision from public.trips where id = (select id from operation_ids where kind = 'going')) + 1)::bigint,
  'dono resolve ponto da escola antes da saída');
select is(public.set_trip_stop(
  (select id from operation_ids where kind = 'home-stop'), -23.5508, -46.6336,
  'Ponto manual',
  (select revision from public.trips where id = (select id from operation_ids where kind = 'going'))
), ((select revision from public.trips where id = (select id from operation_ids where kind = 'going')) + 1)::bigint,
  'dono atualiza ponto antes da saída');
select is(public.order_trip_stops(
  (select id from operation_ids where kind = 'going'),
  (select array_agg(id order by position) from public.trip_stops
   where trip_id = (select id from operation_ids where kind = 'going')),
  (select revision from public.trips where id = (select id from operation_ids where kind = 'going')),
  'ordem operacional validada'
), ((select revision from public.trips where id = (select id from operation_ids where kind = 'going')) + 1)::bigint,
  'dono confirma ordem com revisão');
select is((select payload->>'reason' from public.trip_events
           where trip_id = (select id from operation_ids where kind = 'going')
             and kind = 'stops_reordered' limit 1),
  'ordem operacional validada', 'motivo da ordem fica no evento restrito');
select throws_ok($$select public.start_trip(
  (select id from operation_ids where kind = 'return'),
  '77000000-0000-0000-0000-000000000002'
)$$, 'PGRST', null, 'viagem ainda dentro da janela não inicia');
select is(public.start_trip(
  (select id from operation_ids where kind = 'going'),
  '77000000-0000-0000-0000-000000000003'
), 'active', 'dono inicia viagem pronta');
select is(public.start_trip(
  (select id from operation_ids where kind = 'going'),
  '77000000-0000-0000-0000-000000000003'
), 'active', 'início repetido retorna o mesmo resultado');
select is((select status from public.trips
           where id = (select id from operation_ids where kind = 'going')),
  'active', 'viagem fica ativa uma única vez');
select is(public.record_passenger_event(
  (select id from operation_ids where kind = 'going'),
  (select id from planning_ids where kind = 'minor'), 'boarded',
  '77000000-0000-0000-0000-000000000004'
), 'boarded', 'passageiro confirmado embarca');
select is(public.record_passenger_event(
  (select id from operation_ids where kind = 'going'),
  (select id from planning_ids where kind = 'minor'), 'boarded',
  '77000000-0000-0000-0000-000000000004'
), 'boarded', 'embarque repetido é idempotente');
select is((select count(*)::integer from public.trip_events
           where trip_id = (select id from operation_ids where kind = 'going')
             and kind = 'student_boarded'), 1,
  'replay de presença não duplica evento');
select throws_ok($$select public.record_passenger_event(
  (select id from operation_ids where kind = 'going'),
  (select student_id from public.trip_passengers
   where trip_id = (select id from operation_ids where kind = 'going')
     and confirmation_status = 'expired' limit 1), 'boarded',
  '77000000-0000-0000-0000-000000000005'
)$$, 'PGRST', null, 'passageiro expirado não embarca');
select lives_ok($$select public.mark_trip_stop_reached(
  (select id from public.trip_stops
   where trip_id = (select id from operation_ids where kind = 'going') and kind = 'origin'),
  '77000000-0000-0000-0000-000000000014'
)$$, 'origem alcançada preserva o prefixo');
select lives_ok($$select public.mark_trip_stop_reached(
  (select id from operation_ids where kind = 'home-stop'),
  '77000000-0000-0000-0000-000000000015'
)$$, 'residência alcançada preserva o prefixo');
select lives_ok($$select public.mark_trip_stop_reached(
  (select id from operation_ids where kind = 'school-stop'),
  '77000000-0000-0000-0000-000000000006'
)$$, 'chegada à escola é registrada');
select ok((select reached_at is not null from public.trip_stops
           where id = (select id from operation_ids where kind = 'school-stop')),
  'parada fica marcada como alcançada');
select is(public.order_trip_stops(
  (select id from operation_ids where kind = 'going'),
  (select array_agg(id order by position) from public.trip_stops
   where trip_id = (select id from operation_ids where kind = 'going')),
  (select revision from public.trips where id = (select id from operation_ids where kind = 'going')),
  'ordem pós parada'
), ((select revision from public.trips where id = (select id from operation_ids where kind = 'going')) + 1)::bigint,
  'ordem mantém paradas já alcançadas');
select throws_ok($$select public.finish_trip(
  (select id from operation_ids where kind = 'going'), false, null,
  '77000000-0000-0000-0000-000000000007'
)$$, 'PGRST', null, 'não conclui com passageiro a bordo');
select is(public.record_passenger_event(
  (select id from operation_ids where kind = 'going'),
  (select id from planning_ids where kind = 'minor'), 'dropped_off',
  '77000000-0000-0000-0000-000000000008'
), 'dropped_off', 'passageiro embarcado desembarca');
select is(public.finish_trip(
  (select id from operation_ids where kind = 'going'), false, null,
  '77000000-0000-0000-0000-000000000009'
), 'completed', 'lista executável resolvida permite concluir');
select is(public.finish_trip(
  (select id from operation_ids where kind = 'going'), false, null,
  '77000000-0000-0000-0000-000000000009'
), 'completed', 'conclusão repetida retorna o mesmo resultado');

do $$
declare
  v_trip_id uuid := (select id from operation_ids where kind = 'return');
  v_revision bigint;
begin
  perform set_config('request.jwt.claims',
    '{"sub":"60000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
  perform public.respond_trip(
    v_trip_id, (select id from planning_ids where kind = 'minor'), true,
    '77000000-0000-0000-0000-000000000010'
  );
  perform private.close_confirmations(
    (select confirmation_deadline from public.trips where id = v_trip_id)
  );
  perform set_config('request.jwt.claims',
    '{"sub":"40000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
  select revision into v_revision from public.trips where id = v_trip_id;
  v_revision := public.set_trip_stop(
    (select id from public.trip_stops where trip_id = v_trip_id and kind = 'school' limit 1),
    -23.5610, -46.6550, 'Escola Ciclo 3', v_revision
  );
  v_revision := public.order_trip_stops(
    v_trip_id,
    (select array_agg(id order by position) from public.trip_stops where trip_id = v_trip_id),
    v_revision, 'ordem de retorno validada'
  );
  perform public.start_trip(v_trip_id, '77000000-0000-0000-0000-000000000012');
end;
$$;

select throws_ok($$select public.finish_trip(
  (select id from operation_ids where kind = 'return'), true, 'interrupção',
  '77000000-0000-0000-0000-000000000013'
)$$, 'PGRST', null, 'cancelamento ativo exige ocorrência');
select throws_ok($$select public.record_passenger_event(
  (select id from operation_ids where kind = 'return'),
  (select id from planning_ids where kind = 'minor'), null,
  '77000000-0000-0000-0000-000000000011'
)$$, 'PGRST', null, 'tipo de presença nulo é rejeitado');

select * from finish();

rollback;
