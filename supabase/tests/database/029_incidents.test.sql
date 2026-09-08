begin;

create extension if not exists pgtap with schema extensions;
\ir ../_helpers.psql
\ir ../_planning.psql
\ir ../_operations.psql

select plan(36);
select has_table('public', 'trip_incidents', 'ocorrências preservam o relato');
select has_table('public', 'trip_incident_updates', 'complementos são append-only');
select has_function('public', 'report_trip_incident',
  array['uuid', 'text', 'text', 'uuid'],
  'motorista atribuído pode relatar ocorrência');
select has_function('public', 'update_trip_incident',
  array['uuid', 'text', 'boolean', 'uuid'],
  'resolução acrescenta complemento');
select has_function('public', 'get_trip', array['uuid'],
  'consulta de viagem respeita papel');
select has_function('public', 'list_service_day', array['uuid', 'date'],
  'feed do dia respeita frota');

select lives_ok($$select pg_temp.seed_cycle_4()$$,
  'fixture cria uma viagem operacional real');

select ok(
  not has_table_privilege('authenticated', 'public.trip_incidents', 'SELECT'),
  'ocorrências não têm leitura direta'
);
select ok(
  not has_table_privilege('authenticated', 'public.trip_incident_updates', 'INSERT'),
  'complementos não têm escrita direta'
);
select ok(
  not has_table_privilege('authenticated', 'public.trip_events', 'DELETE'),
  'eventos não podem ser apagados pelo cliente'
);

select set_config('request.jwt.claims',
  '{"sub":"40000000-0000-0000-0000-000000000003","role":"authenticated"}', true);
select lives_ok($$select public.report_trip_incident(
  (select id from operation_ids where kind = 'going'),
  'mechanical', 'Pneu furado no pátio',
  '79000000-0000-0000-0000-000000000001'
)$$, 'motorista atribuído relata ocorrência');
select is((select count(*)::integer from public.trip_incidents
           where trip_id = (select id from operation_ids where kind = 'going')), 1,
  'relato é persistido uma vez');
select is((select category from public.trip_incidents
           where trip_id = (select id from operation_ids where kind = 'going')),
  'mechanical', 'categoria do relato fica registrada');
select is((select description from public.trip_incidents
           where trip_id = (select id from operation_ids where kind = 'going')),
  'Pneu furado no pátio', 'descrição original é preservada');
select is((select payload->>'description' from public.trip_events
           where trip_id = (select id from operation_ids where kind = 'going')
             and kind = 'incident_reported'), null,
  'evento não duplica a descrição operacional');
select is((select payload->>'description_hash' from public.trip_events
           where trip_id = (select id from operation_ids where kind = 'going')
             and kind = 'incident_reported'),
  encode(extensions.digest('Pneu furado no pátio', 'sha256'), 'hex'),
  'evento guarda somente o hash da descrição');

select is(public.report_trip_incident(
  (select id from operation_ids where kind = 'going'),
  'mechanical', 'Pneu furado no pátio',
  '79000000-0000-0000-0000-000000000001'
), (select id from public.trip_incidents
    where trip_id = (select id from operation_ids where kind = 'going')),
  'replay do relato devolve a mesma ocorrência');
select throws_ok($$select public.report_trip_incident(
  (select id from operation_ids where kind = 'going'),
  'mechanical', 'Outro relato',
  '79000000-0000-0000-0000-000000000001'
)$$, 'PGRST', null, 'replay com payload diferente é conflito');
select is((select count(*)::integer from public.trip_events
           where trip_id = (select id from operation_ids where kind = 'going')
             and kind = 'incident_reported'), 1,
  'replay não duplica ocorrência nem evento');

select lives_ok($$select public.update_trip_incident(
  (select id from public.trip_incidents
   where trip_id = (select id from operation_ids where kind = 'going')),
  'Veículo substituído; rota retomada', true,
  '79000000-0000-0000-0000-000000000002'
)$$, 'motorista complementa e resolve ocorrência');
select is((select count(*)::integer from public.trip_incident_updates
           where incident_id = (select id from public.trip_incidents
             where trip_id = (select id from operation_ids where kind = 'going'))), 1,
  'complemento é append-only');
select ok((select resolved_at is not null from public.trip_incidents
           where trip_id = (select id from operation_ids where kind = 'going')),
  'resolução atualiza somente o estado da ocorrência');
select is(public.update_trip_incident(
  (select id from public.trip_incidents
   where trip_id = (select id from operation_ids where kind = 'going')),
  'Veículo substituído; rota retomada', true,
  '79000000-0000-0000-0000-000000000002'
), (select id from public.trip_incidents
    where trip_id = (select id from operation_ids where kind = 'going')),
  'replay do complemento devolve a mesma ocorrência');
select throws_ok($$select public.update_trip_incident(
  (select id from public.trip_incidents
   where trip_id = (select id from operation_ids where kind = 'going')),
  'Texto conflitante', false,
  '79000000-0000-0000-0000-000000000002'
)$$, 'PGRST', null, 'replay de complemento conflitante é rejeitado');

select set_config('request.jwt.claims',
  '{"sub":"40000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select ok((public.get_trip((select id from operation_ids where kind = 'going')) ?&
  array['trip', 'passengers', 'stops', 'assignments', 'incidents', 'events']),
  'dono recebe os blocos operacionais');
select ok((public.get_trip((select id from operation_ids where kind = 'going'))->'incidents'->0)
  ? 'description', 'dono pode consultar a descrição da ocorrência');
select is(jsonb_array_length(public.list_service_day(
  '41000000-0000-0000-0000-000000000001',
  (select service_date from public.trips where id = (select id from operation_ids where kind = 'going'))
)->'trips'), 2, 'dono recebe as duas agendas do dia');

do $$
declare
  v_student_id uuid;
  v_request_id uuid;
  v_service_date date;
  v_allocation jsonb;
  v_trip_id uuid := (select id from operation_ids where kind = 'going');
begin
  v_service_date := (select service_date from public.trips where id = v_trip_id);
  insert into public.schools (
    id, provider, external_id, institution_type, name, postal_code, street,
    street_number, neighborhood, city_name, city_ibge_code, state_code,
    latitude, longitude
  ) values (
    '65000000-0000-0000-0000-000000000002', 'inep', 'incident-school-2', 'school',
    'Escola de Outra Família', '18000002', 'Rua da Outra Escola', '2', 'Centro',
    'Cidade Teste', '3550000', 'SP', -23.5620, -46.6560
  );
  insert into public.fleet_service_schools(fleet_id, school_id, created_by)
  values ('41000000-0000-0000-0000-000000000001',
    '65000000-0000-0000-0000-000000000002',
    '40000000-0000-0000-0000-000000000001');
  insert into public.route_schools(route_id, fleet_id, school_id, position)
  values
    ((select id from planning_ids where kind = 'going-route'),
     '41000000-0000-0000-0000-000000000001',
     '65000000-0000-0000-0000-000000000002', 2),
    ((select id from planning_ids where kind = 'return-route'),
     '41000000-0000-0000-0000-000000000001',
     '65000000-0000-0000-0000-000000000002', 2);
  perform set_config('request.jwt.claims',
    '{"sub":"60000000-0000-0000-0000-000000000002","role":"authenticated"}', true);
  v_student_id := public.create_minor_student(
    'Aluno de Outra Família', current_date - 11 * 365, '18000002',
    'Rua da Outra Família', '200', null, 'Centro', 'Cidade Teste',
    '3550000', 'SP', -23.5520, -46.6350
  );
  v_request_id := public.submit_fleet_join_request(
    '41000000-0000-0000-0000-000000000001', v_student_id,
    '65000000-0000-0000-0000-000000000002', 'morning', array['going']::text[],
    array[extract(isodow from v_service_date)::smallint]
  );
  v_allocation := jsonb_build_array(jsonb_build_object(
    'schedule_id', (select id from planning_ids where kind = 'going-schedule'),
    'weekday', extract(isodow from v_service_date)::smallint,
    'direction', 'going'
  ));
  perform set_config('request.jwt.claims',
    '{"sub":"40000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
  perform public.approve_transport_request(v_request_id, v_allocation, v_service_date);
end;
$$;

select set_config('request.jwt.claims',
  '{"sub":"60000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select ok((public.get_trip((select id from operation_ids where kind = 'going'))->'passengers'->0)
  ? 'student_id', 'responsável recebe seu passageiro');
select ok(not ((public.get_trip((select id from operation_ids where kind = 'going'))->'stops'->0)
  ? 'address_snapshot'), 'responsável não recebe endereço no objeto operacional');
select ok(not ((public.get_trip((select id from operation_ids where kind = 'going'))->'incidents'->0)
  ? 'description'), 'responsável não recebe a descrição restrita da ocorrência');
select is(jsonb_array_length(public.get_trip((select id from operation_ids where kind = 'going'))->'passengers'),
  1, 'responsável não recebe passageiro de outra família');
select ok(not exists (
  select 1 from jsonb_array_elements(public.get_trip((select id from operation_ids where kind = 'going'))->'stops') stop
  where stop->>'school_id' = '65000000-0000-0000-0000-000000000002'
), 'responsável não recebe escola de outro passageiro');
select ok(not exists (
  select 1 from jsonb_array_elements(public.get_trip((select id from operation_ids where kind = 'going'))->'stops') stop
  where stop->>'kind' = 'home' and stop->>'student_id' <> (select id::text from planning_ids where kind = 'minor')
), 'responsável não recebe residência de outro passageiro');
select is(jsonb_array_length(public.get_trip((select id from operation_ids where kind = 'going'))->'events'),
  0, 'responsável não recebe stream de eventos da operação');
select is(jsonb_array_length(public.list_service_day(
  '41000000-0000-0000-0000-000000000001',
  (select service_date from public.trips where id = (select id from operation_ids where kind = 'going'))
)->'trips'), 0, 'responsável não recebe feed operacional da frota');

select set_config('request.jwt.claims',
  '{"sub":"40000000-0000-0000-0000-000000000005","role":"authenticated"}', true);
select throws_ok($$select public.get_trip((select id from operation_ids where kind = 'going'))$$,
  'PGRST', null, 'membro sem papel operacional não consulta viagem');

select * from finish();

rollback;
