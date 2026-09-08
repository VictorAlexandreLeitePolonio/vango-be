begin;
create extension if not exists pgtap with schema extensions;
\ir ../_helpers.psql
\ir ../_planning.psql

select plan(24);
select has_table('public', 'route_student_schedules', 'programações do aluno existem');
select has_table('public', 'transport_reservations', 'reservas recorrentes existem');
select has_table('public', 'join_request_van_preferences', 'preferências de van existem');
select has_function('public', 'approve_transport_request', array['uuid', 'jsonb', 'date'], 'aprovação exige alocações');
select has_function('public', 'set_transport_request_status', array['uuid', 'text', 'text'], 'espera e recusa têm comando próprio');
select pg_temp.seed_cycle_3();
select is(
  (select status from public.fleet_join_requests where id = (select id from planning_ids where kind = 'request')),
  'pending',
  'pedido começa pendente'
);

select throws_ok(
  $$select public.approve_transport_request(
    (select id from planning_ids where kind = 'request'),
    jsonb_build_array(jsonb_build_object('schedule_id',(select id from planning_ids where kind = 'going-schedule'),'weekday',1)),
    current_date + 1
  )$$,
  'PGRST', null, 'aprovação parcial é rejeitada'
);
select is(
  (select count(*)::integer from public.fleet_enrollments where student_id = (select id from planning_ids where kind = 'minor')),
  0,
  'falha de integralidade não cria matrícula'
);
select is(
  (select count(*)::integer from public.transport_reservations where student_id = (select id from planning_ids where kind = 'minor')),
  0,
  'falha de integralidade não cria reservas'
);

select jsonb_agg(jsonb_build_object('schedule_id', x.schedule_id, 'weekday', x.weekday) order by x.direction, x.weekday) as allocation
from (
  select id as schedule_id, weekday, 'going' as direction
  from planning_ids, generate_series(1,5) weekday where kind='going-schedule'
  union all
  select id as schedule_id, weekday, 'return' as direction
  from planning_ids, generate_series(1,5) weekday where kind='return-schedule'
) x \gset
select set_config('request.jwt.claims', '{"sub":"40000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.approve_transport_request(
  (select id from planning_ids where kind = 'request'), :'allocation'::jsonb, current_date + 1
) as approved_enrollment \gset
select ok(:'approved_enrollment' is not null, 'aprovação integral é atômica');
reset role;
select is(
  (select status from public.fleet_join_requests where id = (select id from planning_ids where kind = 'request')),
  'approved',
  'pedido aprovado após alocação completa'
);
select is(
  (select school_id from public.fleet_enrollments where student_id = (select id from planning_ids where kind = 'minor') and status = 'active'),
  (select id from planning_ids where kind = 'school'),
  'matrícula guarda escola vigente'
);
select is(
  (select count(*)::integer from public.route_student_schedules where enrollment_id = (select enrollment_id from public.fleet_join_requests where id = (select id from planning_ids where kind = 'request'))),
  10,
  'cada combinação solicitada vira programação'
);
select is(
  (select count(*)::integer from public.transport_reservations where enrollment_id = (select enrollment_id from public.fleet_join_requests where id = (select id from planning_ids where kind = 'request')) and status = 'active'),
  10,
  'cada combinação solicitada vira reserva'
);

select set_config('request.jwt.claims', '{"sub":"40000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select throws_ok(
  $$select public.save_route(
    '41000000-0000-0000-0000-000000000001',
    (select id from planning_ids where kind = 'going-route'),
    jsonb_build_object(
      'name','Ciclo 3 ida alterada','direction','going','shift','afternoon',
      'paired_route_id',(select id from planning_ids where kind = 'return-route'),
      'van_id',(select id from planning_ids where kind = 'van'),
      'driver_user_id','40000000-0000-0000-0000-000000000003',
      'origin',jsonb_build_object('latitude',-23.5505,'longitude',-46.6333,'label','Residência'),
      'destination',jsonb_build_object('latitude',-23.5610,'longitude',-46.6550,'label','Escola'),
      'schools',jsonb_build_array(jsonb_build_object('school_id',(select id from planning_ids where kind='school'),'position',1))
    )
  )$$,
  'PGRST', null,
  'rota com reservas vigentes não pode mudar'
);
select throws_ok(
  $$select public.save_route_schedule(
    (select id from planning_ids where kind = 'going-route'),
    (select id from planning_ids where kind = 'going-schedule'),
    jsonb_build_object(
      'weekdays',jsonb_build_array(1,2,3,4,5),'starts_at','08:00','ends_at','09:01',
      'ends_next_day',false,'timezone','America/Sao_Paulo',
      'valid_from',current_date + 1,'valid_until',current_date + 90,
      'confirmation_minutes',30
    )
  )$$,
  'PGRST', null,
  'agenda com reservas vigentes não pode mudar'
);
reset role;
select is(
  (select name from public.routes where id = (select id from planning_ids where kind = 'going-route')),
  'Ciclo 3 ida'::text,
  'rota permanece intacta após bloqueio'
);
select is(
  (select ends_at from public.route_schedules where id = (select id from planning_ids where kind = 'going-schedule')),
  '09:00:00'::time,
  'agenda permanece intacta após bloqueio'
);

select set_config('request.jwt.claims', '{"sub":"40000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select throws_ok(
  $$select public.decide_fleet_join_request((select id from planning_ids where kind = 'request'),'approved')$$,
  'PGRST', null, 'caminho legado não aprova sem alocação'
);
select set_config('request.jwt.claims', '{"sub":"60000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select public.create_minor_student(
  'Aluno Ciclo 3 Espera', current_date - 9 * 365, '18000000', 'Rua da Espera', '11',
  null, 'Centro', 'Cidade Teste', '3550000', 'SP', -23.5505, -46.6333
) as second_student \gset
select public.submit_fleet_join_request(
  '41000000-0000-0000-0000-000000000001', :'second_student',
  (select id from planning_ids where kind = 'school'), 'morning', array['going']::text[], array[1]::smallint[]
) as second_request \gset
select set_config('request.jwt.claims', '{"sub":"40000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select throws_ok(
  $$select public.set_transport_request_status(
    (select id from planning_ids where kind = 'request'), null, null
  )$$,
  'PGRST', null, 'status nulo é rejeitado explicitamente'
);
select public.set_transport_request_status(:'second_request', 'waitlisted', 'sem vaga') as second_waitlisted \gset
select is(:'second_waitlisted'::text, 'waitlisted'::text, 'dono move pedido para espera');
select set_config('request.jwt.claims', '{"sub":"60000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select is(
  (select decided_at from public.fleet_join_requests where id = :'second_request'),
  null::timestamptz,
  'espera permanece aberta e conserva antiguidade'
);
select set_config('request.jwt.claims', '{"sub":"40000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select public.set_transport_request_status(:'second_request', 'rejected', 'sem atendimento') as second_rejected \gset
select is(:'second_rejected'::text, 'rejected'::text, 'dono pode recusar pedido em espera');
select set_config('request.jwt.claims', '{"sub":"60000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select is(
  (select status from public.fleet_join_requests where id = :'second_request'),
  'rejected',
  'recusa remove pedido da fila'
);

select * from finish();
rollback;
