begin;
create extension if not exists pgtap with schema extensions;
\ir ../_helpers.psql
\ir ../_planning.psql

select plan(27);
select has_function(
  'public', 'get_fleet_planning', array['uuid'],
  'projeção operacional da frota existe'
);
select has_function(
  'public', 'get_my_transport', array[]::text[],
  'projeção do próprio transporte existe'
);
select has_function(
  'public', 'list_marketplace_vans', array['uuid'],
  'consulta pública sanitizada de vans existe'
);
select ok(
  not has_table_privilege('anon', 'public.route_student_schedules', 'SELECT'),
  'reservas recorrentes não são públicas por tabela'
);
select ok(
  not has_table_privilege('authenticated', 'public.transport_reservations', 'SELECT'),
  'reservas não têm DML/SELECT direto para authenticated'
);

select ok(
  not has_function_privilege('anon','private.allocation_set_conflicts(jsonb,uuid,smallint,date)','execute')
  and not has_function_privilege('authenticated','private.allocation_set_conflicts(jsonb,uuid,smallint,date)','execute'),
  'comparação interna de alocações não é executável por clientes');
select ok(
  not has_function_privilege('anon','private.find_request_allocation_step(uuid,date,jsonb,jsonb,uuid)','execute')
  and not has_function_privilege('authenticated','private.find_request_allocation_step(uuid,date,jsonb,jsonb,uuid)','execute'),
  'busca interna de alocações não é executável por clientes');
select ok(
  not has_function_privilege('anon','private.assert_route_school_change(uuid,jsonb)','execute')
  and not has_function_privilege('authenticated','private.assert_route_school_change(uuid,jsonb)','execute'),
  'guarda interna de escolas de rota não é executável por clientes');

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
select ok(:'enrollment_id' is not null, 'fixture aprovada para projeções');

set local role authenticated;
select ok(
  jsonb_typeof(public.get_fleet_planning('41000000-0000-0000-0000-000000000001')) = 'object',
  'owner recebe um objeto de planejamento'
);
select ok(
  (public.get_fleet_planning('41000000-0000-0000-0000-000000000001') ?&
    array['vans', 'routes', 'schedules', 'reservations', 'revisions']),
  'projeção do owner tem os blocos contratados'
);
select is(
  jsonb_array_length(public.get_fleet_planning('41000000-0000-0000-0000-000000000001')->'reservations'),
  10,
  'owner vê reservas da própria frota'
);
select ok(
  (public.get_fleet_planning('41000000-0000-0000-0000-000000000001')->'vans'->0) ? 'plate',
  'owner pode consultar placa operacional'
);
select throws_ok(
  $$select public.get_fleet_planning('41000000-0000-0000-0000-000000000002')$$,
  'PGRST', null,
  'owner A não lê planejamento da frota B'
);
reset role;

select set_config(
  'request.jwt.claims',
  '{"sub":"40000000-0000-0000-0000-000000000003","role":"authenticated"}',
  true
);
set local role authenticated;
select is(
  jsonb_array_length(public.get_fleet_planning('41000000-0000-0000-0000-000000000001')->'routes'),
  2,
  'driver vê somente as duas rotas atribuídas'
);
select ok(
  not ((public.get_fleet_planning('41000000-0000-0000-0000-000000000001')->'vans'->0) ? 'plate'),
  'driver não recebe placa na projeção sanitizada'
);
select is(
  jsonb_array_length(public.get_fleet_planning('41000000-0000-0000-0000-000000000001')->'reservations'),
  10,
  'driver recebe reservas das rotas atribuídas'
);
reset role;

select set_config(
  'request.jwt.claims',
  '{"sub":"60000000-0000-0000-0000-000000000001","role":"authenticated"}',
  true
);
set local role authenticated;
select is(
  jsonb_array_length(public.get_my_transport()->'enrollments'),
  1,
  'principal vê a própria matrícula'
);
select is(
  jsonb_array_length(public.get_my_transport()->'reservations'),
  10,
  'principal vê as próprias reservas'
);
select ok(
  not (public.get_my_transport()->'students'->0) ? 'postal_code',
  'projeção do aluno não expõe endereço completo'
);
reset role;

select id as primary_membership
from public.fleet_memberships
where fleet_id = '41000000-0000-0000-0000-000000000001'
  and user_id = '60000000-0000-0000-0000-000000000001' \gset
select set_config(
  'request.jwt.claims',
  '{"sub":"40000000-0000-0000-0000-000000000001","role":"authenticated"}',
  true
);
select public.set_fleet_membership_status(:'primary_membership'::uuid, 'suspended')
as suspended_status \gset
select is(:'suspended_status'::text, 'suspended'::text, 'suspensão revoga projeção de transporte');
select set_config(
  'request.jwt.claims',
  '{"sub":"60000000-0000-0000-0000-000000000001","role":"authenticated"}',
  true
);
set local role authenticated;
select is(
  jsonb_array_length(public.get_my_transport()->'reservations'),
  0,
  'responsável suspenso não recebe reservas'
);
select is(
  (select status from public.student_guardians
   where student_id = (select id from planning_ids where kind = 'minor')
     and guardian_user_id = '60000000-0000-0000-0000-000000000001'),
  'active'::text,
  'suspensão não revoga a relação de responsável'
);
reset role;
select set_config(
  'request.jwt.claims',
  '{"sub":"40000000-0000-0000-0000-000000000001","role":"authenticated"}',
  true
);
select public.set_fleet_membership_status(:'primary_membership'::uuid, 'active')
as restored_status \gset
select is(:'restored_status'::text, 'active'::text, 'membro pode ser reativado');

set local role anon;
select is(
  jsonb_array_length((select jsonb_agg(row_to_json(v)) from public.list_marketplace_vans(
    '41000000-0000-0000-0000-000000000001'
  ) v)),
  1,
  'marketplace anônimo vê van da frota publicada'
);
select ok(
  not exists (
    select 1 from public.list_marketplace_vans(
      '41000000-0000-0000-0000-000000000001'
    ) v where to_jsonb(v) ? 'plate'
  ),
  'marketplace não expõe placa'
);
select is(
  (select count(*)::integer from public.list_marketplace_vans(
    '41000000-0000-0000-0000-000000000002'
  )),
  0,
  'marketplace não retorna frota não publicada'
);
reset role;

select * from finish();
rollback;
