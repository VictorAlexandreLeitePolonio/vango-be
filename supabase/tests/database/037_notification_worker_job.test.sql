begin;

create extension if not exists pgtap with schema extensions;
\ir ../_helpers.psql

select plan(15);
select ok(
  exists (select 1 from private.notification_worker_state where id = true),
  'estado singleton é inicializado pela migration'
);
select is(
  (select activation_event_id from private.notification_worker_state where id = true),
  0::bigint,
  'corte inicial começa em zero'
);
select is(
  (select enabled from private.notification_worker_state where id = true),
  false,
  'materialização começa desativada'
);
select ok(
  to_regclass('cron.job') is not null,
  'pg_cron fornece a tabela real de jobs'
);
select has_function('private', 'dispatch_notification_worker', array[]::text[],
  'despacho usa configuração segura');
select is(
  (select count(*)::integer from cron.job
   where jobname = 'notification-dispatch'),
  1,
  'existe um job real de notificação'
);
select is(
  (select schedule from cron.job where jobname = 'notification-dispatch'),
  '* * * * *',
  'frequência inicial é de um minuto'
);
select is(
  (select active from cron.job where jobname = 'notification-dispatch'),
  false,
  'job nasce desativado antes da configuração'
);
select is(
  (select command from cron.job where jobname = 'notification-dispatch'),
  'select private.dispatch_notification_worker();',
  'job chama o dispatcher registrado'
);
select ok(
  to_regclass('private.notification_worker_job') is null,
  'não há tabela substituta no lugar do pg_cron'
);
select throws_ok(
  $$select private.dispatch_notification_worker()$$,
  'PGRST', null,
  'segredo ausente impede o despacho'
);
select ok(
  not has_function_privilege('authenticated',
    'private.dispatch_notification_worker()', 'EXECUTE'),
  'cliente não dispara o worker'
);
select ok(
  exists (
    select 1 from pg_proc p
    cross join lateral unnest(coalesce(p.proconfig, '{}'::text[])) config(value)
    where p.oid = 'private.dispatch_notification_worker()'::regprocedure
      and config.value = 'search_path=""'
  ),
  'despacho fixa search_path vazio'
);

update private.notification_worker_state
set activation_event_id = 42,
    enabled = true,
    activated_at = clock_timestamp()
where id = true;
select is(
  (select activation_event_id from private.notification_worker_state where id = true),
  42::bigint,
  'operador pode fixar o corte de ativação'
);
select is(
  (select enabled from private.notification_worker_state where id = true),
  true,
  'ativação persistida habilita o worker'
);

select * from finish();

rollback;
