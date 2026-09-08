begin;

create extension if not exists pgtap with schema extensions;
\ir ../_helpers.psql
\ir ../_planning.psql
\ir ../_operations.psql

select plan(33);
select has_function('private', 'reconcile_enrollment_trips',
  array['uuid', 'text', 'date', 'timestamp with time zone'],
  'mudança cadastral reconcilia execuções futuras');
select has_function('private', 'next_change_date',
  array['uuid', 'timestamp with time zone'],
  'vigência respeita o próximo prazo de confirmação');

select lives_ok($$select pg_temp.seed_cycle_4()$$,
  'fixture cria ida ativa e volta futura');

insert into public.schools (
  id, provider, external_id, institution_type, name, postal_code, street,
  street_number, neighborhood, city_name, city_ibge_code, state_code,
  latitude, longitude
) values (
  '65000000-0000-0000-0000-000000000002', 'inep', 'cycle4-school-2', 'school',
  'Escola Ciclo 4 Nova', '18000001', 'Rua Nova Escola', '2', 'Centro',
  'Cidade Teste', '3550000', 'SP', -23.5620, -46.6560
);
insert into public.fleet_service_schools (fleet_id, school_id, created_by)
values (
  '41000000-0000-0000-0000-000000000001',
  '65000000-0000-0000-0000-000000000002',
  '40000000-0000-0000-0000-000000000001'
);

select set_config('request.jwt.claims',
  '{"sub":"60000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select is(public.respond_trip(
  (select id from operation_ids where kind = 'going'),
  (select id from planning_ids where kind = 'minor'), true,
  '7a000000-0000-0000-0000-000000000001'
), 'confirmed', 'ida é confirmada antes do fechamento');
select is(public.respond_trip(
  (select id from operation_ids where kind = 'return'),
  (select id from planning_ids where kind = 'minor'), true,
  '7a000000-0000-0000-0000-000000000002'
), 'confirmed', 'volta é confirmada antes da alteração cadastral');

select set_config('request.jwt.claims',
  '{"sub":"40000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select is(private.close_confirmations(
  (select confirmation_deadline from public.trips
   where id = (select id from operation_ids where kind = 'going'))
), 1, 'fechamento da ida prepara o início');
select is(public.set_trip_stop(
  (select id from public.trip_stops where trip_id = (select id from operation_ids where kind = 'going')
    and kind = 'school' limit 1), -23.5610, -46.6550, 'Escola Ciclo 3',
  (select revision from public.trips where id = (select id from operation_ids where kind = 'going'))
), ((select revision from public.trips where id = (select id from operation_ids where kind = 'going')) + 1)::bigint,
  'ponto da escola é resolvido para iniciar');
select is(public.set_trip_stop(
  (select id from public.trip_stops where trip_id = (select id from operation_ids where kind = 'going')
    and kind = 'home' limit 1), -23.5508, -46.6336, 'Ponto antigo',
  (select revision from public.trips where id = (select id from operation_ids where kind = 'going'))
), ((select revision from public.trips where id = (select id from operation_ids where kind = 'going')) + 1)::bigint,
  'ponto residencial antigo é resolvido');
select is(public.order_trip_stops(
  (select id from operation_ids where kind = 'going'),
  (select array_agg(id order by position) from public.trip_stops
   where trip_id = (select id from operation_ids where kind = 'going')),
  (select revision from public.trips where id = (select id from operation_ids where kind = 'going')),
  'ordem antes do início'
), ((select revision from public.trips where id = (select id from operation_ids where kind = 'going')) + 1)::bigint,
  'ordem da ida é definida pelo dono');
select is(public.start_trip(
  (select id from operation_ids where kind = 'going'),
  '7a000000-0000-0000-0000-000000000003'
), 'active', 'ida inicia com snapshot antigo');
select is((select status from public.trips where id = (select id from operation_ids where kind = 'going')),
  'active', 'ida fica ativa durante a mudança cadastral');

select is((select confirmation_status from public.trip_passengers
           where trip_id = (select id from operation_ids where kind = 'return')),
  'confirmed', 'confirmação futura começa confirmada');

select set_config('request.jwt.claims',
  '{"sub":"60000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select lives_ok($$select public.update_student(
  (select id from planning_ids where kind = 'minor'),
  'Aluno Ciclo 3', current_date - 10 * 365, '18000000', 'Rua Nova', '99',
  null, 'Centro', 'Cidade Teste', '3550000', 'SP', -23.5510, -46.6340
)$$, 'alteração de endereço chama a reconciliação');
select is((select coalesce(address_snapshot->>'street', address_snapshot->>'label') from public.trip_stops
  where trip_id = (select id from operation_ids where kind = 'going')
             and kind = 'home' limit 1),
  'Ponto antigo', 'viagem ativa preserva endereço antigo');
select is((select address_snapshot->>'street' from public.trip_stops
           where trip_id = (select id from operation_ids where kind = 'return')
             and kind = 'home' limit 1),
  'Rua Nova', 'viagem futura recebe endereço novo');
select is((select confirmation_status from public.trip_passengers
           where trip_id = (select id from operation_ids where kind = 'return')),
  'confirmed', 'mudança de endereço preserva confirmação futura');
select ok((select count(*) > 0 from public.trip_events
           where trip_id = (select id from operation_ids where kind = 'return')
             and kind = 'trip_reconciled'),
  'reconciliação registra evento sem endereço');

select lives_ok($$select public.update_enrollment_school(
  (select id from operation_ids where kind = 'enrollment'),
  '65000000-0000-0000-0000-000000000002'
)$$, 'alteração de escola chama a reconciliação');
select is((select school_id from public.trip_passengers
           where trip_id = (select id from operation_ids where kind = 'going')),
  (select id from planning_ids where kind = 'school'),
  'viagem ativa preserva escola antiga');
select is((select school_id from public.trip_passengers
           where trip_id = (select id from operation_ids where kind = 'return')),
  '65000000-0000-0000-0000-000000000002'::uuid,
  'viagem futura recebe escola atual');
select ok((select count(*) > 0 from public.trip_stops
           where trip_id = (select id from operation_ids where kind = 'return')
             and kind = 'school'
             and school_id = '65000000-0000-0000-0000-000000000002'),
  'reconciliação acrescenta parada da escola atual');
select is((select confirmation_status from public.trip_passengers
           where trip_id = (select id from operation_ids where kind = 'return')),
  'confirmed', 'mudança de escola preserva confirmação futura');

select set_config('request.jwt.claims',
  '{"sub":"40000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select throws_ok($$select public.end_fleet_enrollment(
  (select id from operation_ids where kind = 'enrollment'), 'mudança durante operação'
)$$, 'PGRST', null, 'encerramento é bloqueado com participação ativa');
select is(public.record_passenger_event(
  (select id from operation_ids where kind = 'going'),
  (select id from planning_ids where kind = 'minor'), 'absent',
  '7a000000-0000-0000-0000-000000000004'
), 'absent', 'passageiro resolve a ida ativa');
select is(public.finish_trip(
  (select id from operation_ids where kind = 'going'), false, null,
  '7a000000-0000-0000-0000-000000000005'
), 'completed', 'ida concluída libera o encerramento do vínculo');
select is(public.end_fleet_enrollment(
  (select id from operation_ids where kind = 'enrollment'), 'família encerrou o transporte'
), 'ended', 'responsável encerra vínculo sem viagem ativa');
select ok((select removed_at is not null from public.trip_passengers
           where trip_id = (select id from operation_ids where kind = 'return')),
  'participação futura é removida sem apagar o snapshot');
select is((select removal_reason from public.trip_passengers
           where trip_id = (select id from operation_ids where kind = 'return')),
  'família encerrou o transporte', 'motivo do encerramento fica na participação');
select ok((select removed_at is null from public.trip_passengers
           where trip_id = (select id from operation_ids where kind = 'going')),
  'histórico da ida concluída permanece intacto');

create temp table reconciliation_new_ids(kind text primary key, id uuid) on commit drop;
do $$
declare
  v_student_id uuid;
  v_request_id uuid;
  v_enrollment_id uuid;
  v_allocations jsonb;
  v_service_date date := (select service_date from public.trips
                          where id = (select id from operation_ids where kind = 'return'));
begin
  perform set_config('request.jwt.claims',
    '{"sub":"60000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
  v_student_id := public.create_minor_student(
    'Aluno Aprovado Após Geração', current_date - 9 * 365, '18000000',
    'Rua Pós Geração', '11', null, 'Centro', 'Cidade Teste', '3550000', 'SP',
    -23.5509, -46.6339
  );
  v_request_id := public.submit_fleet_join_request(
    '41000000-0000-0000-0000-000000000001', v_student_id,
    (select id from planning_ids where kind = 'school'), 'morning',
    array['going', 'return']::text[], array[1, 2, 3, 4, 5]::smallint[]
  );
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
    '{"sub":"40000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
  v_enrollment_id := public.approve_transport_request(
    v_request_id, v_allocations, v_service_date
  );
  insert into reconciliation_new_ids(kind, id) values
    ('student', v_student_id), ('request', v_request_id), ('enrollment', v_enrollment_id);
end;
$$;
select ok((select count(*)::integer from public.trip_passengers p
           where p.trip_id = (select id from operation_ids where kind = 'return')
             and p.enrollment_id = (select id from reconciliation_new_ids where kind = 'enrollment')) = 1,
  'aprovação inicial após geração adiciona passageiro à execução futura');
select ok((select count(*)::integer from public.trip_stops s
           where s.trip_id = (select id from operation_ids where kind = 'return')
             and s.kind = 'home'
             and s.student_id = (select id from reconciliation_new_ids where kind = 'student')) = 1,
  'aprovação inicial após geração adiciona residência à execução futura');
select is((select confirmation_status from public.trip_passengers
           where trip_id = (select id from operation_ids where kind = 'return')
             and enrollment_id = (select id from reconciliation_new_ids where kind = 'enrollment')),
  'pending', 'novo passageiro respeita a janela de confirmação');
select is((select count(*)::integer from public.trip_passengers p
           where p.trip_id = (select id from operation_ids where kind = 'going')
             and p.enrollment_id = (select id from reconciliation_new_ids where kind = 'enrollment')),
  0, 'aprovação não reabre execução já concluída');

select * from finish();

rollback;
