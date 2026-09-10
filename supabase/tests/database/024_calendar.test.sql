begin;

create extension if not exists pgtap with schema extensions;
\ir ../_helpers.psql
\ir ../_planning.psql
\ir ../_operations.psql

select plan(19);
select has_table('public', 'route_service_exceptions', 'exceção por rota/data');
select has_table('public', 'service_days', 'dia operacional por frota/data');
select has_table('public', 'trips', 'execução possui identidade própria');

select pg_temp.seed_cycle_4();
select set_config('request.jwt.claims',
  '{"sub":"40000000-0000-0000-0000-000000000001","role":"authenticated"}', true);

select is(public.set_service_enabled(
  '41000000-0000-0000-0000-000000000001',
  array[(select id from operation_ids where kind = 'going-route')],
  current_date + 1, false, 'feriado local'
), 1, 'desabilita rota');
select is((select enabled from public.route_service_exceptions
           where route_id = (select id from operation_ids where kind = 'going-route')
             and service_date = current_date + 1), false,
  'exceção fica desabilitada');
select is((select count(*)::integer from public.route_service_exceptions
           where fleet_id = '41000000-0000-0000-0000-000000000001'
             and service_date = current_date + 1), 1,
  'somente rota informada');
select is(public.set_service_enabled(
  '41000000-0000-0000-0000-000000000001', null, current_date + 1, true, null
), 2, 'NULL aplica todas as rotas');
select is((select count(*)::integer from public.route_service_exceptions
           where fleet_id = '41000000-0000-0000-0000-000000000001'
             and service_date = current_date + 1 and enabled), 2,
  'todas ficam reativadas');
select is(public.set_service_enabled(
  '41000000-0000-0000-0000-000000000001',
  array[(select id from operation_ids where kind = 'going-route')],
  current_date + 1, true, null
), 1, 'repetição é idempotente por chave');
select throws_ok($$select public.set_service_enabled(
  '41000000-0000-0000-0000-000000000001', '{}'::uuid[], current_date + 1, true, null
)$$, 'PGRST', null, 'array vazio rejeitado');
select throws_ok($$select public.set_service_enabled(
  '41000000-0000-0000-0000-000000000001',
  array['41000000-0000-0000-0000-000000000002']::uuid[], current_date + 1, true, null
)$$, 'PGRST', null, 'rota de outro tenant rejeitada');
select throws_ok($$select public.set_service_enabled(
  '41000000-0000-0000-0000-000000000001',
  array[(select id from operation_ids where kind = 'return-route')],
  current_date + 2, false, null
)$$, 'PGRST', null, 'motivo obrigatório');
select set_config('request.jwt.claims', '', true);
select throws_ok($$select public.set_service_enabled(
  '41000000-0000-0000-0000-000000000001', null, current_date + 1, true, null
)$$, 'PGRST', null, 'anônimo rejeitado');
select set_config('request.jwt.claims',
  '{"sub":"40000000-0000-0000-0000-000000000001","role":"authenticated"}', true);

insert into public.service_days(id, fleet_id, service_date)
values ('74000000-0000-0000-0000-000000000001',
        '41000000-0000-0000-0000-000000000001', current_date + 10);
insert into public.trips(
  id, fleet_id, service_day_id, route_id, schedule_id, service_date,
  planned_start_at, reserved_until, confirmation_deadline, status,
  van_id, driver_user_id
)
select '75000000-0000-0000-0000-000000000001', r.fleet_id,
       '74000000-0000-0000-0000-000000000001', r.id, s.id, current_date + 10,
       ((current_date + 10)::date + s.starts_at) at time zone s.timezone,
       ((current_date + 10)::date + s.ends_at) at time zone s.timezone,
       (((current_date + 10)::date + s.starts_at) at time zone s.timezone)
         - make_interval(mins => s.confirmation_minutes),
       'active', r.van_id, r.driver_user_id
from public.routes r
join public.route_schedules s on s.route_id = r.id and s.fleet_id = r.fleet_id
where r.id = (select id from operation_ids where kind = 'going-route');
insert into public.trips(
  id, fleet_id, service_day_id, route_id, schedule_id, service_date,
  planned_start_at, reserved_until, confirmation_deadline, status,
  van_id, driver_user_id
)
select '75000000-0000-0000-0000-000000000002', r.fleet_id,
       '74000000-0000-0000-0000-000000000001', r.id, s.id, current_date + 10,
       ((current_date + 10)::date + s.starts_at) at time zone s.timezone,
       ((current_date + 10)::date + s.ends_at) at time zone s.timezone,
       (((current_date + 10)::date + s.starts_at) at time zone s.timezone)
         - make_interval(mins => s.confirmation_minutes),
       'scheduled', r.van_id, r.driver_user_id
from public.routes r
join public.route_schedules s on s.route_id = r.id and s.fleet_id = r.fleet_id
where r.id = (select id from operation_ids where kind = 'return-route');
update public.trips set started_at = clock_timestamp()
where id = '75000000-0000-0000-0000-000000000001';

select is(public.set_service_enabled(
  '41000000-0000-0000-0000-000000000001', null, current_date + 10, false,
  'cancelamento operacional'
), 2, 'desabilitar cancela somente não iniciadas');
select is((select status from public.trips
           where id = '75000000-0000-0000-0000-000000000002'), 'cancelled',
  'viagem não iniciada é cancelada');
select is((select status from public.trips
           where id = '75000000-0000-0000-0000-000000000001'), 'active',
  'viagem ativa é preservada');
select is(public.set_service_enabled(
  '41000000-0000-0000-0000-000000000001', null, current_date + 10, true, null
), 2, 'reativação atualiza as exceções');
select is((select status from public.trips
           where id = '75000000-0000-0000-0000-000000000002'), 'scheduled',
  'viagem cancelada e nunca iniciada retorna ao planejamento');
select is((select status from public.trips
           where id = '75000000-0000-0000-0000-000000000001'), 'active',
  'reativação não reescreve viagem ativa');

select * from finish();

rollback;
