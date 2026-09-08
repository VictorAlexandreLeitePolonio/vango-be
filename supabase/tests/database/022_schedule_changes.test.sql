begin;
create extension if not exists pgtap with schema extensions;
\ir ../_helpers.psql
\ir ../_planning.psql

select plan(31);
select has_function(
  'public', 'request_schedule_change', array['uuid', 'text[]', 'smallint[]'],
  'mudança de programação existe'
);
select has_function(
  'public', 'update_enrollment_school', array['uuid', 'uuid'],
  'escola vigente pode ser atualizada'
);
select has_function(
  'private', 'next_change_date', array['uuid', 'timestamp with time zone'],
  'data efetiva calcula janela futura'
);

select pg_temp.seed_cycle_3();
select jsonb_agg(
  jsonb_build_object('schedule_id', item.schedule_id, 'weekday', item.weekday)
  order by item.direction, item.weekday
) as allocation
from (
  select id as schedule_id, weekday, 'going' as direction
  from planning_ids, generate_series(1, 5) weekday where kind = 'going-schedule'
  union all
  select id as schedule_id, weekday, 'return' as direction
  from planning_ids, generate_series(1, 5) weekday where kind = 'return-schedule'
) item \gset
select set_config(
  'request.jwt.claims',
  '{"sub":"40000000-0000-0000-0000-000000000001","role":"authenticated"}',
  true
);
select public.approve_transport_request(
  (select id from planning_ids where kind = 'request'), :'allocation'::jsonb, current_date + 1
) as enrollment_id \gset
insert into planning_ids(kind, id) values ('enrollment', :'enrollment_id');
select ok(:'enrollment_id' is not null, 'fixture possui matrícula aprovada');
select is(
  (select status from public.fleet_join_requests where id = (select id from planning_ids where kind = 'request')),
  'approved'::text,
  'pedido original permanece aprovado'
);
select is(
  (select count(*)::integer from public.route_student_schedules
   where enrollment_id = :'enrollment_id'),
  10,
  'programação original possui dez combinações'
);
select is(
  (select count(*)::integer from public.transport_reservations
   where enrollment_id = :'enrollment_id' and status = 'active'),
  10,
  'reservas originais estão ativas'
);

select set_config(
  'request.jwt.claims',
  '{"sub":"60000000-0000-0000-0000-000000000001","role":"authenticated"}',
  true
);
select public.request_schedule_change(
  :'enrollment_id', array['going']::text[], array[1]::smallint[]
) as change_request \gset
select is(
  (select request_kind from public.fleet_join_requests where id = :'change_request'),
  'change'::text,
  'mudança cria pedido próprio'
);
select is(
  (select status from public.fleet_join_requests where id = :'change_request'),
  'pending'::text,
  'mudança começa pendente'
);
select is(
  (select enrollment_id from public.fleet_join_requests where id = :'change_request'),
  :'enrollment_id'::uuid,
  'mudança referencia a matrícula atual'
);
select is(
  (select count(*)::integer from public.route_student_schedules
   where enrollment_id = :'enrollment_id'),
  10,
  'solicitação não altera programação imediatamente'
);
select is(
  (select count(*)::integer from public.transport_reservations
   where enrollment_id = :'enrollment_id' and status = 'active'),
  10,
  'solicitação não cancela reservas imediatamente'
);
select ok(
  private.next_change_date(:'change_request'::uuid, current_date::timestamptz) is not null,
  'data da troca encontra próxima janela de confirmação'
);
select jsonb_build_array(
  jsonb_build_object(
    'schedule_id', (select id from planning_ids where kind = 'going-schedule'),
    'weekday', 1
  )
) as change_allocation \gset
select set_config(
  'request.jwt.claims',
  '{"sub":"40000000-0000-0000-0000-000000000001","role":"authenticated"}',
  true
);
savepoint change_approval_contract;
select throws_ok(
  $$select public.approve_transport_request(
    (select id from public.fleet_join_requests
     where request_kind = 'change'
       and enrollment_id = (select id from planning_ids where kind = 'enrollment')),
    jsonb_build_array(jsonb_build_object(
      'schedule_id', (select id from planning_ids where kind = 'going-schedule'),
      'weekday', 1
    )), current_date + 3
  )$$,
  'PGRST', null,
  'aprovação de mudança não aceita data arbitrária'
);
select private.next_change_date(:'change_request'::uuid, clock_timestamp()) as change_effective_on \gset
select public.approve_transport_request(
  :'change_request'::uuid, :'change_allocation'::jsonb, :'change_effective_on'::date
) as approved_change \gset
select is(
  (select status from public.fleet_join_requests where id = :'change_request'::uuid),
  'approved'::text,
  'aprovação de mudança usa a próxima data calculada'
);
rollback to change_approval_contract;
select set_config(
  'request.jwt.claims',
  '{"sub":"60000000-0000-0000-0000-000000000001","role":"authenticated"}',
  true
);
select throws_ok(
  $$select public.request_schedule_change(
    (select id from planning_ids where kind = 'request')::uuid,
    array['return']::text[], array[2]::smallint[]
  )$$,
  'PGRST', null,
  'segunda mudança aberta é rejeitada'
);

insert into public.schools (
  id, provider, external_id, institution_type, name, postal_code, street,
  street_number, neighborhood, city_name, city_ibge_code, state_code
) values (
  '65000000-0000-0000-0000-000000000003', 'inep', 'cycle3-change-school', 'school',
  'Escola vigente nova', '18000000', 'Rua da Revisão', '3', 'Centro', 'Cidade Teste',
  '3550000', 'SP'
);
insert into public.fleet_service_schools (fleet_id, school_id, created_by)
values (
  '41000000-0000-0000-0000-000000000001',
  '65000000-0000-0000-0000-000000000003',
  '40000000-0000-0000-0000-000000000001'
);
select public.update_enrollment_school(
  :'enrollment_id'::uuid, '65000000-0000-0000-0000-000000000003'::uuid
) as updated_enrollment \gset
select ok(:'updated_enrollment' is not null, 'adulto principal atualiza escola vigente');
select is(
  (select school_id from public.fleet_enrollments where id = :'enrollment_id'),
  '65000000-0000-0000-0000-000000000003'::uuid,
  'matrícula guarda nova escola vigente'
);
select is(
  (select routing_revision from public.fleet_enrollments where id = :'enrollment_id'),
  2::bigint,
  'troca de escola incrementa revisão de rota'
);
select is(
  (select school_id from public.fleet_join_requests where id = (select id from planning_ids where kind = 'request')),
  (select id from planning_ids where kind = 'school'),
  'pedido histórico conserva escola original'
);

select public.update_student(
  (select id from planning_ids where kind = 'minor'), 'Aluno Ciclo 3',
  current_date - 10 * 365, '18000000', 'Rua Nova do Aluno', '10', null,
  'Centro', 'Cidade Teste', '3550000', 'SP', -23.5510, -46.6340
) as updated_student \gset
select ok(:'updated_student' is not null, 'adulto principal atualiza endereço do aluno');
select is(
  (select street from public.students where id = (select id from planning_ids where kind = 'minor')),
  'Rua Nova do Aluno'::text,
  'novo endereço é persistido'
);
select is(
  (select routing_revision from public.fleet_enrollments where id = :'enrollment_id'),
  3::bigint,
  'endereço incrementa revisão de rota'
);
select is(
  (select street from public.fleet_join_requests where id = (select id from planning_ids where kind = 'request')),
  'Rua do Aluno'::text,
  'snapshot do pedido histórico não muda'
);

insert into public.student_guardians (student_id, guardian_user_id, is_primary, status)
values (
  (select id from planning_ids where kind = 'minor'),
  '60000000-0000-0000-0000-000000000002', false, 'active'
);
select set_config(
  'request.jwt.claims',
  '{"sub":"60000000-0000-0000-0000-000000000002","role":"authenticated"}',
  true
);
select throws_ok(
  $$select public.end_fleet_enrollment(
    (select id from planning_ids where kind = 'enrollment'), 'secundário'
  )$$,
  'PGRST', null,
  'responsável secundário não encerra matrícula'
);
select set_config(
  'request.jwt.claims',
  '{"sub":"60000000-0000-0000-0000-000000000001","role":"authenticated"}',
  true
);
-- One recurring slot starts today; ending must also release a later
-- execution on this service day, not keep the seat until midnight.
update public.transport_reservations set valid_from=current_date
where enrollment_id=:'enrollment_id'
  and id=(select min(id::text)::uuid from public.transport_reservations where enrollment_id=:'enrollment_id');
update public.route_student_schedules set valid_from=current_date
where id=(select route_student_schedule_id from public.transport_reservations
  where enrollment_id=:'enrollment_id' and valid_from=current_date limit 1);
select public.end_fleet_enrollment(:'enrollment_id'::uuid, 'encerramento solicitado') as ended_status \gset
select is(:'ended_status'::text, 'ended'::text, 'principal encerra matrícula');
select is(
  (select status from public.fleet_enrollments where id = :'enrollment_id'),
  'ended'::text,
  'matrícula fica encerrada'
);
select is(
  (select count(*)::integer from public.transport_reservations
   where enrollment_id = :'enrollment_id' and status = 'cancelled'),
  10,
  'reservas futuras são canceladas preservando histórico'
);
select is(
  (select count(*)::integer from public.route_student_schedules
   where enrollment_id = :'enrollment_id'),
  10,
  'programações históricas permanecem'
);
select is(
  (select count(*)::integer from public.route_student_schedules
   where enrollment_id = :'enrollment_id' and status = 'cancelled'),
  10,
  'programações futuras são canceladas com motivo'
);
select is(
  (select status from public.fleet_join_requests where id = :'change_request'),
  'cancelled'::text,
  'encerramento cancela mudança aberta'
);

select * from finish();
rollback;
