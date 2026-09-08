begin;
create extension if not exists pgtap with schema extensions;
\ir ../_helpers.psql
\ir ../_planning.psql

select plan(17);
select has_function(
  'public', 'list_transport_queue', array['uuid', 'integer', 'integer'],
  'fila de transporte existe'
);
select has_function(
  'public', 'set_request_van_preferences', array['uuid', 'uuid[]'],
  'preferências de van existem'
);

select pg_temp.seed_cycle_3();
insert into planning_ids(kind, id)
select 'first', id from planning_ids where kind = 'request';

insert into public.schools (
  id, provider, external_id, institution_type, name, postal_code, street,
  street_number, neighborhood, city_name, city_ibge_code, state_code
) values (
  '65000000-0000-0000-0000-000000000002', 'inep', 'cycle3-queue-school', 'school',
  'Escola sem rota', '18000000', 'Rua da Fila', '2', 'Centro', 'Cidade Teste',
  '3550000', 'SP'
);
insert into public.fleet_service_schools (fleet_id, school_id, created_by)
values (
  '41000000-0000-0000-0000-000000000001',
  '65000000-0000-0000-0000-000000000002',
  '40000000-0000-0000-0000-000000000001'
);
update public.fleet_join_requests
set school_id = '65000000-0000-0000-0000-000000000002',
    directions = array['going']::text[],
    weekdays = array[1]::smallint[],
    created_at = clock_timestamp() - interval '2 hours'
where id = (select id from planning_ids where kind = 'first');

select set_config(
  'request.jwt.claims',
  '{"sub":"60000000-0000-0000-0000-000000000001","role":"authenticated"}',
  true
);
select public.create_minor_student(
  'Aluno Ciclo 3 Segundo', current_date - 9 * 365, '18000000', 'Rua do Segundo', '12',
  null, 'Centro', 'Cidade Teste', '3550000', 'SP', -23.5505, -46.6333
) as second_student \gset
select public.submit_fleet_join_request(
  '41000000-0000-0000-0000-000000000001', :'second_student',
  (select id from planning_ids where kind = 'school'), 'morning',
  array['going']::text[], array[1]::smallint[]
) as second_request \gset
insert into planning_ids(kind, id) values ('second', :'second_request');
update public.fleet_join_requests
set created_at = clock_timestamp() - interval '1 hour'
where id = :'second_request';

select set_config(
  'request.jwt.claims',
  '{"sub":"40000000-0000-0000-0000-000000000001","role":"authenticated"}',
  true
);
select public.set_transport_request_status(:'second_request', 'waitlisted', 'aguardando vaga')
as second_waitlisted \gset
select is(:'second_waitlisted'::text, 'waitlisted'::text, 'pedido mais novo pode esperar');

select results_eq(
  $$select request_id from public.list_transport_queue(
    '41000000-0000-0000-0000-000000000001', 50, 0
  )$$,
  $$select id from planning_ids where kind in ('first', 'second') order by kind$$,
  'fila inclui pending e waitlisted em created_at/id'
);
select is(
  (select fully_serviceable from public.list_transport_queue(
    '41000000-0000-0000-0000-000000000001', 50, 0
  ) where request_id = (select id from planning_ids where kind = 'first')),
  false,
  'pedido sem rota compatível não bloqueia os seguintes'
);
select is(
  (select fully_serviceable from public.list_transport_queue(
    '41000000-0000-0000-0000-000000000001', 50, 0
  ) where request_id = (select id from planning_ids where kind = 'second')),
  true,
  'pedido atendível é marcado na fila'
);

select set_config(
  'request.jwt.claims',
  '{"sub":"60000000-0000-0000-0000-000000000001","role":"authenticated"}',
  true
);
select public.set_request_van_preferences(
  (select id from planning_ids where kind = 'second'),
  array[(select id from planning_ids where kind = 'van')]
);
select is(
  (select count(*)::integer from public.join_request_van_preferences
   where request_id = (select id from planning_ids where kind = 'second')),
  1,
  'preferência de van é persistida'
);
select is(
  (select van_id from public.join_request_van_preferences
   where request_id = (select id from planning_ids where kind = 'second')),
  (select id from planning_ids where kind = 'van'),
  'preferência conserva a van escolhida'
);
select throws_ok(
  $$select public.set_request_van_preferences(
    (select id from planning_ids where kind = 'second'),
    array[
      (select id from planning_ids where kind = 'van'),
      (select id from planning_ids where kind = 'van'),
      (select id from planning_ids where kind = 'van'),
      (select id from planning_ids where kind = 'van')
    ]
  )$$,
  'PGRST', null,
  'mais de três preferências são rejeitadas'
);
select throws_ok(
  $$select public.set_request_van_preferences(
    (select id from planning_ids where kind = 'second'),
    array['51000000-0000-0000-0000-000000000001'::uuid]
  )$$,
  'PGRST', null,
  'van de outra frota não é revelada'
);

select set_config(
  'request.jwt.claims',
  '{"sub":"40000000-0000-0000-0000-000000000001","role":"authenticated"}',
  true
);
select throws_ok(
  $$select public.set_request_van_preferences(
    (select id from planning_ids where kind = 'second'),
    array[(select id from planning_ids where kind = 'van')]
  )$$,
  'PGRST', null,
  'somente solicitante altera preferências'
);
update public.fleet_join_requests
set school_id=(select id from planning_ids where kind='school'), directions=array['going','return']
where id=(select id from planning_ids where kind='first');
update public.route_schedules set valid_from=current_date+10
where id=(select id from planning_ids where kind='return-schedule');
update public.route_schedules set valid_until=current_date+120
where id=(select id from planning_ids where kind='going-schedule');
select is((select fully_serviceable from public.list_transport_queue(
  '41000000-0000-0000-0000-000000000001',50,0)
  where request_id=(select id from planning_ids where kind='first')),true,
  'fila encontra interseção futura de agendas com inícios diferentes');
select throws_ok(
  $$select public.approve_transport_request(
    (select id from planning_ids where kind='second'),
    jsonb_build_array(jsonb_build_object('schedule_id',
      (select id from planning_ids where kind='going-schedule'),'weekday',1)),current_date+100)$$,
  'PGRST', null, 'data escolhida pelo dono não contorna pedido anterior atendível');
update public.fleet_join_requests
set school_id='65000000-0000-0000-0000-000000000002',directions=array['going']
where id=(select id from planning_ids where kind='first');
update public.route_schedules set valid_from=current_date+1
where id=(select id from planning_ids where kind='return-schedule');
update public.route_schedules set valid_until=current_date+90
where id=(select id from planning_ids where kind='going-schedule');

select public.approve_transport_request(
  (select id from planning_ids where kind = 'second'),
  jsonb_build_array(jsonb_build_object(
    'schedule_id', (select id from planning_ids where kind = 'going-schedule'),
    'weekday', 1
  )),
  current_date + 1
) as second_enrollment \gset
select ok(:'second_enrollment' is not null, 'pedido compatível é aprovado');
select set_config(
  'request.jwt.claims',
  '{"sub":"60000000-0000-0000-0000-000000000001","role":"authenticated"}',
  true
);
select is(
  (select status from public.fleet_join_requests where id = (select id from planning_ids where kind = 'second')),
  'approved'::text,
  'aprovação remove pedido da fila'
);
select set_config(
  'request.jwt.claims',
  '{"sub":"40000000-0000-0000-0000-000000000001","role":"authenticated"}',
  true
);
select is(
  (select count(*)::integer from public.list_transport_queue(
    '41000000-0000-0000-0000-000000000001', 50, 0
  )),
  1,
  'fila exclui pedidos aprovados'
);
select set_config(
  'request.jwt.claims',
  '{"sub":"60000000-0000-0000-0000-000000000001","role":"authenticated"}',
  true
);
select throws_ok(
  $$select public.set_request_van_preferences(
    (select id from planning_ids where kind = 'second'),
    array[(select id from planning_ids where kind = 'van')]
  )$$,
  'PGRST', null,
  'pedido aprovado não aceita novas preferências'
);

select * from finish();
rollback;
