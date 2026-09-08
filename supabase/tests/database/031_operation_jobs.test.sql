begin;

create extension if not exists pgtap with schema extensions;
\ir ../_helpers.psql
\ir ../_planning.psql
\ir ../_operations.psql

select plan(12);
select has_function(
  'private', 'run_daily_operations', array['timestamp with time zone'],
  'job diário expõe o orquestrador privado'
);
select ok(
  not has_function_privilege(
    'authenticated',
    'private.run_daily_operations(timestamp with time zone)',
    'EXECUTE'
  ),
  'cliente não dispara a operação diária'
);
select lives_ok(
  $$select pg_temp.seed_cycle_4()$$,
  'fixture cria agendas e viagens para o job'
);

create temp table operation_job_counts (
  stage text primary key,
  trip_count bigint not null,
  unique_schedule_dates bigint not null
) on commit drop;

insert into operation_job_counts(stage, trip_count, unique_schedule_dates)
select
  'before',
  count(*),
  count(distinct (schedule_id, service_date))
from public.trips;

select lives_ok(
  $$select private.run_daily_operations(clock_timestamp())$$,
  'uma execução gera o amanhã local e fecha confirmações vencidas'
);
insert into operation_job_counts(stage, trip_count, unique_schedule_dates)
select
  'after_first',
  count(*),
  count(distinct (schedule_id, service_date))
from public.trips;
select is(
  (select trip_count from operation_job_counts where stage = 'after_first'),
  (select trip_count from operation_job_counts where stage = 'before'),
  'a geração idempotente não duplica viagens existentes'
);
select is(
  (select unique_schedule_dates from operation_job_counts where stage = 'after_first'),
  (select trip_count from operation_job_counts where stage = 'after_first'),
  'cada agenda e data de serviço aparece uma única vez'
);

select lives_ok(
  $$select private.run_daily_operations(clock_timestamp())$$,
  'execução repetida permanece segura'
);
insert into operation_job_counts(stage, trip_count, unique_schedule_dates)
select
  'after_second',
  count(*),
  count(distinct (schedule_id, service_date))
from public.trips;
select is(
  (select trip_count from operation_job_counts where stage = 'after_second'),
  (select trip_count from operation_job_counts where stage = 'after_first'),
  'execução repetida não cria viagens adicionais'
);

-- pg_cron lives in the configured database (the hosted/integrated target is
-- normally postgres).  Keep the observation dynamic so DB4 can still run the
-- business-function assertions without resolving a missing cron.job relation.
create temp table operation_job_cron_observation (
  table_present boolean not null,
  job_count bigint not null,
  active boolean,
  command text
) on commit drop;
do $observe_cron$
declare
  v_present boolean := to_regclass('cron.job') is not null;
  v_count bigint := 0;
  v_active boolean;
  v_command text;
begin
  if v_present then
    execute $query$
      select count(*)::bigint
      from cron.job
      where jobname = 'vango-daily-operations'
    $query$ into v_count;
    execute $query$
      select active, command
      from cron.job
      where jobname = 'vango-daily-operations'
      order by jobid
      limit 1
    $query$ into v_active, v_command;
  end if;
  insert into operation_job_cron_observation(table_present, job_count, active, command)
  values (v_present, v_count, v_active, v_command);
end;
$observe_cron$;

select ok(
  (select table_present from operation_job_cron_observation),
  'pg_cron fornece a tabela real de jobs no banco integrado'
);
select is(
  (select job_count from operation_job_cron_observation),
  1::bigint,
  'existe exatamente um job diário de operações'
);
select is(
  (select active from operation_job_cron_observation),
  false,
  'job diário nasce inativo para revisão operacional'
);
select is(
  (select command from operation_job_cron_observation),
  'select private.run_daily_operations(clock_timestamp());',
  'job chama o orquestrador registrado'
);

select * from finish();

rollback;
