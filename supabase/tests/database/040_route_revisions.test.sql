begin;

create extension if not exists pgtap with schema extensions;
\ir ../_helpers.psql
\ir ../_planning.psql
\ir ../_operations.psql

select plan(33);
select has_table(
  'public', 'trip_route_calculations',
  'cálculos de percurso têm histórico versionado'
);
select has_function(
  'public', 'request_trip_route_calculation', array['uuid'],
  'owner solicita uma revisão de percurso'
);
select has_function(
  'public', 'get_route_calculation_input', array['uuid', 'bigint'],
  'serviço lê a entrada congelada da revisão'
);
select has_function(
  'public', 'apply_trip_route_result', array['uuid', 'bigint', 'jsonb'],
  'serviço aplica resultado com CAS'
);
select has_column(
  'public', 'trip_route_calculations', 'applied_input_hash',
  'cálculo guarda o hash do estado depois da aplicação'
);
select ok(
  not has_table_privilege('authenticated', 'public.trip_route_calculations', 'SELECT'),
  'conteúdo externo não tem SELECT direto'
);

select pg_temp.seed_cycle_4();
grant select on operation_ids to authenticated, service_role;
select set_config(
  'request.jwt.claims',
  '{"sub":"40000000-0000-0000-0000-000000000001","role":"authenticated"}',
  true
);
set local role authenticated;
select public.request_trip_route_calculation(
  (select id from operation_ids where kind = 'going')
) as first_revision \gset
reset role;
select is(:first_revision::bigint, 1::bigint, 'primeiro pedido usa revisão inicial');

reset role;
select is(
  (select status from public.trip_route_calculations
   where trip_id = (select id from operation_ids where kind = 'going')
     and revision = :first_revision::bigint),
  'pending',
  'pedido fica pendente sem chamar provedor'
);
select ok(
  (public.get_route_calculation_input(
    (select id from operation_ids where kind = 'going'), :first_revision::bigint
  ) ?& array['trip_id', 'revision', 'departure_at', 'points', 'passengers', 'school_order']),
  'entrada congela pontos, passageiros e ordem'
);
reset role;

select set_config(
  'request.jwt.claims',
  '{"sub":"40000000-0000-0000-0000-000000000001","role":"authenticated"}',
  true
);
set local role authenticated;
select is(
  public.request_trip_route_calculation(
    (select id from operation_ids where kind = 'going')
  ),
  :first_revision::bigint,
  'pedido idêntico é idempotente'
);
reset role;

select jsonb_build_object(
  'revision', :first_revision::bigint,
  'orderedPointIds', (
    select jsonb_agg(id order by case kind
      when 'origin' then 1 when 'school' then 2 when 'home' then 3 else 4 end)
    from public.trip_stops
    where trip_id = (select id from operation_ids where kind = 'going')
  ),
  'distanceMeters', 100,
  'durationSeconds', 120,
  'calculatedAt', clock_timestamp(),
  'legs', '[]'::jsonb
) as invalid_result \gset
reset role;
select throws_ok(
  'select public.apply_trip_route_result(' ||
    quote_literal((select id from operation_ids where kind = 'going')::text) || ', ' ||
    :first_revision::text || ', ' || quote_literal(:'invalid_result') || '::jsonb)',
  'PGRST', null,
  'ordem casa-escola inválida é rejeitada'
);
reset role;

update public.trip_stops
set address_snapshot = jsonb_build_object('label', 'Ponto revisado'),
    latitude = -23.551,
    longitude = -46.631
where id = (select id from operation_ids where kind = 'home-stop');
select set_config(
  'request.jwt.claims',
  '{"sub":"40000000-0000-0000-0000-000000000001","role":"authenticated"}',
  true
);
set local role authenticated;
select public.request_trip_route_calculation(
  (select id from operation_ids where kind = 'going')
) as second_revision \gset
reset role;
select is(:second_revision::bigint, 2::bigint, 'mudança de snapshot gera nova revisão');
select is(
  (select status from public.trip_route_calculations
   where trip_id = (select id from operation_ids where kind = 'going')
     and revision = :first_revision::bigint),
  'superseded',
  'resposta anterior fica obsoleta'
);
reset role;
select is(
  public.apply_trip_route_result(
    (select id from operation_ids where kind = 'going'),
    :first_revision::bigint, '{}'::jsonb
  ),
  'superseded',
  'resposta atrasada não sobrescreve rota nova'
);
select ok(
  (public.get_route_calculation_input(
    (select id from operation_ids where kind = 'going'), :second_revision::bigint
  )->'points')::text like '%Ponto revisado%',
  'revisão nova usa snapshot atualizado'
);
reset role;

select jsonb_build_object(
  'revision', :second_revision::bigint,
  'orderedPointIds', (
    select jsonb_agg(id order by position)
    from public.trip_stops
    where trip_id = (select id from operation_ids where kind = 'going')
  ),
  'distanceMeters', 100,
  'durationSeconds', 120,
  'calculatedAt', clock_timestamp(),
  'legs', (
    select coalesce(jsonb_agg(jsonb_build_object(
      'fromId', id, 'toId', next_id,
      'distanceMeters', 10, 'durationSeconds', 12
    ) order by position), '[]'::jsonb)
    from (
      select id, position, lead(id) over (order by position) as next_id
      from public.trip_stops
      where trip_id = (select id from operation_ids where kind = 'going')
    ) chain
    where next_id is not null
  )
) as valid_result \gset
reset role;
select is(
  public.apply_trip_route_result(
    (select id from operation_ids where kind = 'going'),
    :second_revision::bigint, :'valid_result'::jsonb
  ),
  'calculated',
  'resultado válido aplica somente na revisão atual'
);
select is(
  (select status from public.trip_route_calculations
   where trip_id = (select id from operation_ids where kind = 'going')
     and revision = :second_revision::bigint),
  'calculated',
  'resultado aplicado fica calculado'
);
reset role;

select route_revision as applied_route_revision, revision as applied_trip_revision
from public.trips
where id = (select id from operation_ids where kind = 'going') \gset
select is(
  public.apply_trip_route_result(
    (select id from operation_ids where kind = 'going'),
    :second_revision::bigint, :'valid_result'::jsonb
  ),
  'calculated',
  'repetir o mesmo resultado é idempotente'
);
select is(
  (select route_revision from public.trips
   where id = (select id from operation_ids where kind = 'going')),
  :applied_route_revision::bigint,
  'replay não cria revisão de rota falsa'
);
select is(
  (select revision from public.trips
   where id = (select id from operation_ids where kind = 'going')),
  :applied_trip_revision::bigint,
  'replay não incrementa revisão operacional'
);
select set_config(
  'request.jwt.claims',
  '{"sub":"40000000-0000-0000-0000-000000000001","role":"authenticated"}',
  true
);
set local role authenticated;
select public.request_trip_route_calculation(
  (select id from operation_ids where kind = 'going')
) as applied_request_revision \gset
reset role;
select is(
  :applied_request_revision::bigint,
  :second_revision::bigint,
  'pedido após aplicar sem edição mantém a revisão calculada'
);

update public.trip_stops
set address_snapshot = jsonb_build_object('label', 'Ponto revisado novamente'),
    latitude = -23.552,
    longitude = -46.632
where id = (select id from operation_ids where kind = 'home-stop');
select set_config(
  'request.jwt.claims',
  '{"sub":"40000000-0000-0000-0000-000000000001","role":"authenticated"}',
  true
);
set local role authenticated;
select public.request_trip_route_calculation(
  (select id from operation_ids where kind = 'going')
) as third_revision \gset
reset role;
select is(:third_revision::bigint, 3::bigint,
  'alteração após aplicação cria uma terceira revisão');
select is(
  (select status from public.trip_route_calculations
   where trip_id = (select id from operation_ids where kind = 'going')
     and revision = :second_revision::bigint),
  'superseded',
  'resultado calculado obsoleto preserva o histórico como superseded'
);
select ok(
  (select result is not null from public.trip_route_calculations
   where trip_id = (select id from operation_ids where kind = 'going')
     and revision = :second_revision::bigint),
  'resultado superseded mantém a resposta aplicada'
);
select ok(
  (select applied_at is not null from public.trip_route_calculations
   where trip_id = (select id from operation_ids where kind = 'going')
     and revision = :second_revision::bigint),
  'resultado superseded mantém o instante de aplicação'
);

update public.trips
set status = 'active', started_at = clock_timestamp(), ended_at = null
where id = (select id from operation_ids where kind = 'going');
select set_config(
  'request.jwt.claims',
  '{"sub":"40000000-0000-0000-0000-000000000001","role":"authenticated"}',
  true
);
set local role authenticated;
select throws_ok(
  $$select public.request_trip_route_calculation(
    (select id from operation_ids where kind = 'going'))$$,
  'PGRST', null,
  'viagem iniciada preserva seu snapshot'
);
reset role;

insert into public.trip_incidents (fleet_id, trip_id, category, description, actor_user_id)
select t.fleet_id, t.id, 'detour', 'desvio autorizado para teste de rota',
  '40000000-0000-0000-0000-000000000001'
from public.trips t
where t.id = (select id from operation_ids where kind = 'going');
update public.trip_stops
set reached_at = clock_timestamp()
where id = (
  select id from public.trip_stops
  where trip_id = (select id from operation_ids where kind = 'going')
  order by position
  limit 1
);
select set_config(
  'request.jwt.claims',
  '{"sub":"40000000-0000-0000-0000-000000000001","role":"authenticated"}',
  true
);
set local role authenticated;
select public.request_trip_route_calculation(
  (select id from operation_ids where kind = 'going')
) as fourth_revision \gset
select is(
  :fourth_revision::bigint,
  :third_revision::bigint + 1,
  'ocorrência autorizada permite recalcular viagem ativa'
);
reset role;

with route_order as (
  select jsonb_build_array(
    (select id from public.trip_stops where trip_id = (select id from operation_ids where kind = 'going')
      and reached_at is null order by position limit 1),
    (select id from public.trip_stops where trip_id = (select id from operation_ids where kind = 'going')
      and reached_at is not null order by position limit 1),
    (select id from public.trip_stops where trip_id = (select id from operation_ids where kind = 'going')
      and reached_at is null order by position offset 1 limit 1),
    (select id from public.trip_stops where trip_id = (select id from operation_ids where kind = 'going')
      and reached_at is null order by position offset 2 limit 1)
  ) as ids
), route_chain as (
  select value::uuid as id, ordinality as position,
    lead(value::uuid) over (order by ordinality) as next_id
  from route_order, jsonb_array_elements_text(route_order.ids) with ordinality
)
select jsonb_build_object(
  'revision', :fourth_revision::bigint,
  'orderedPointIds', (select ids from route_order),
  'distanceMeters', 100,
  'durationSeconds', 120,
  'calculatedAt', clock_timestamp(),
  'legs', coalesce((select jsonb_agg(jsonb_build_object(
    'fromId', id, 'toId', next_id,
    'distanceMeters', 10, 'durationSeconds', 12
  ) order by position) from route_chain where next_id is not null), '[]'::jsonb)
) as invalid_active_result \gset
reset role;
select throws_ok(
  'select public.apply_trip_route_result(' ||
    quote_literal((select id from operation_ids where kind = 'going')::text) || ', ' ||
    :fourth_revision::text || ', ' || quote_literal(:'invalid_active_result') || '::jsonb)',
  'PGRST', null,
  'resultado ativo não pode alterar o prefixo já percorrido'
);
select is(
  (select status from public.trip_route_calculations
   where trip_id = (select id from operation_ids where kind = 'going')
     and revision = :fourth_revision::bigint),
  'pending',
  'resultado que altera o prefixo falha sem consumir a revisão pendente'
);

select set_config(
  'request.jwt.claims',
  '{"sub":"40000000-0000-0000-0000-000000000001","role":"authenticated"}',
  true
);
set local role authenticated;
select public.request_trip_route_calculation(
  (select id from operation_ids where kind = 'going')
) as retry_revision \gset
reset role;
select is(:retry_revision::bigint, :fourth_revision::bigint,
  'novo pedido após resultado inválido reutiliza a revisão pendente');

select jsonb_build_object(
  'revision', :retry_revision::bigint,
  'orderedPointIds', (
    select jsonb_agg(id order by position)
    from public.trip_stops
    where trip_id = (select id from operation_ids where kind = 'going')
  ),
  'distanceMeters', 100,
  'durationSeconds', 120,
  'calculatedAt', clock_timestamp(),
  'legs', (
    select coalesce(jsonb_agg(jsonb_build_object(
      'fromId', id, 'toId', next_id,
      'distanceMeters', 10, 'durationSeconds', 12
    ) order by position), '[]'::jsonb)
    from (
      select id, position, lead(id) over (order by position) as next_id
      from public.trip_stops
      where trip_id = (select id from operation_ids where kind = 'going')
    ) chain
    where next_id is not null
  )
) as active_valid_result \gset
select is(
  public.apply_trip_route_result(
    (select id from operation_ids where kind = 'going'),
    :retry_revision::bigint, :'active_valid_result'::jsonb
  ),
  'calculated',
  'desvio autorizado aplica somente a revisão ativa atual'
);
select is(
  (select position from public.trip_stops
   where trip_id = (select id from operation_ids where kind = 'going')
     and reached_at is not null
   order by position limit 1),
  1,
  'aplicação ativa preserva a posição do prefixo percorrido'
);
select ok(
  not exists (
    select 1 from public.trip_stops pending
    where pending.trip_id = (select id from operation_ids where kind = 'going')
      and pending.reached_at is null
      and pending.position <= (
        select max(reached.position) from public.trip_stops reached
        where reached.trip_id = pending.trip_id and reached.reached_at is not null
      )
  ),
  'aplicação ativa mantém o sufixo pendente após o prefixo'
);

select * from finish();

rollback;
