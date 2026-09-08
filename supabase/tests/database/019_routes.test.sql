begin;
create extension if not exists pgtap with schema extensions;
\ir ../_helpers.psql
\ir ../_planning.psql

select plan(31);
select has_table('public', 'routes', 'rotas existem');
select has_table('public', 'route_schools', 'escolas das rotas existem');
select has_table('public', 'route_schedules', 'agendas existem');
select has_function('public', 'save_route', array['uuid', 'uuid', 'jsonb'], 'salvar rota');
select has_function('public', 'save_route_schedule', array['uuid', 'uuid', 'jsonb'], 'salvar agenda');
select has_function('public', 'set_route_status', array['uuid', 'text', 'text'], 'alterar estado da rota');
select has_function('private', 'schedule_windows', array['uuid', 'date', 'date'], 'agenda produz intervalos com fuso');
select throws_ok(
  $$select private.validate_schedule('{"weekdays":[8]}'::jsonb)$$,
  'PGRST', null, 'dia inválido rejeitado'
);

select pg_temp.seed_cycle_3();
select is(
  (select count(*)::integer from private.schedule_windows(
    (select id from planning_ids where kind = 'going-schedule'),
    current_date + 1, current_date + 90
  )),
  (select count(*)::integer from generate_series(current_date + 1, current_date + 90, interval '1 day') d
   where extract(isodow from d)::integer between 1 and 5),
  'janela recorre todas as datas úteis finitas'
);
select is(
  lower("window")::date,
  (select min(d::date) from generate_series(current_date + 1, current_date + 7, interval '1 day') d where extract(isodow from d) between 1 and 5),
  'janela começa no primeiro dia útil solicitado'
) from private.schedule_windows(
  (select id from planning_ids where kind = 'going-schedule'), current_date + 1, current_date + 7
) order by service_date limit 1;
select ok(
  (select isfinite(valid_from) and isfinite(valid_until)
   from public.route_schedules
   where id = (select id from planning_ids where kind = 'going-schedule')),
  'vigências são finitas'
);

select set_config('request.jwt.claims', '{"sub":"40000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select throws_ok(
  $$select public.save_route('41000000-0000-0000-0000-000000000001', null, '{"name":"incompleta"}'::jsonb)$$,
  'PGRST', null, 'configuração de rota incompleta é rejeitada'
);
select throws_ok(
  $$select public.save_route(
    '41000000-0000-0000-0000-000000000001', null,
    jsonb_build_object(
      'name','Rota sem rótulo','direction','going','shift','morning',
      'van_id',(select id from planning_ids where kind='van'),
      'driver_user_id','40000000-0000-0000-0000-000000000003',
      'origin',jsonb_build_object('latitude',-23.55,'longitude',-46.63),
      'destination',jsonb_build_object('latitude',-23.56,'longitude',-46.65,'label','Destino'),
      'schools',jsonb_build_array(jsonb_build_object('school_id',(select id from planning_ids where kind='school'),'position',1))
    )
  )$$,
  'PGRST', null,
  'rótulo de origem ausente é rejeitado como entrada inválida'
);
select throws_ok(
  $$select public.save_route_schedule(
    (select id from planning_ids where kind = 'going-route'), null,
    '{"weekdays":[1],"starts_at":"08:00","ends_at":"09:00","ends_next_day":false,"timezone":"America/Sao_Paulo","valid_from":"infinity","valid_until":"infinity","confirmation_minutes":30}'::jsonb
  )$$,
  'PGRST', null, 'vigência infinita é rejeitada'
);

select lives_ok(
  $$select public.save_route(
    '41000000-0000-0000-0000-000000000001', null,
    jsonb_build_object(
      'name','Rota adjacente','direction','going','shift','morning',
      'van_id',(select id from planning_ids where kind = 'van'),
      'driver_user_id','40000000-0000-0000-0000-000000000003',
      'origin',jsonb_build_object('latitude',-23.55,'longitude',-46.63,'label','Origem'),
      'destination',jsonb_build_object('latitude',-23.56,'longitude',-46.65,'label','Destino'),
      'schools',jsonb_build_array(jsonb_build_object('school_id',(select id from planning_ids where kind = 'school'),'position',1))
    )
  )$$,
  'rota com recurso existente sem agenda é criada'
);
select lives_ok(
  $$select public.save_route_schedule(
    (select id from public.routes where name = 'Rota adjacente'), null,
    jsonb_build_object('weekdays',jsonb_build_array(1,2,3,4,5),'starts_at','09:00','ends_at','10:00','ends_next_day',false,'timezone','America/Sao_Paulo','valid_from',current_date + 1,'valid_until',current_date + 90,'confirmation_minutes',30)
  )$$,
  'fim exclusivo permite início no término da agenda anterior'
);
select lives_ok(
  $$select public.save_route(
    '41000000-0000-0000-0000-000000000001', null,
    jsonb_build_object(
      'name','Rota conflitante','direction','return','shift','morning',
      'van_id',(select id from planning_ids where kind = 'van'),
      'driver_user_id','40000000-0000-0000-0000-000000000003',
      'origin',jsonb_build_object('latitude',-23.55,'longitude',-46.63,'label','Origem'),
      'destination',jsonb_build_object('latitude',-23.56,'longitude',-46.65,'label','Destino'),
      'schools',jsonb_build_array(jsonb_build_object('school_id',(select id from planning_ids where kind = 'school'),'position',1))
    )
  )$$,
  'rota conflitante é criada antes da agenda'
);
select throws_ok(
  $$select public.save_route_schedule(
    (select id from public.routes where name = 'Rota conflitante'), null,
    jsonb_build_object('weekdays',jsonb_build_array(1,2,3,4,5),'starts_at','08:59','ends_at','09:30','ends_next_day',false,'timezone','America/Sao_Paulo','valid_from',current_date + 1,'valid_until',current_date + 90,'confirmation_minutes',30)
  )$$,
  'PGRST', null, 'sobreposição de recurso é rejeitada'
);
select throws_ok(
  $$select public.deactivate_van((select id from planning_ids where kind = 'van'),'rota ativa')$$,
  'PGRST', null, 'van atribuída não pode ser inativada'
);
select is(
  (select status from public.vans where id = (select id from planning_ids where kind = 'van')),
  'active',
  'falha de inativação não altera van'
);
select public.save_van(
  '41000000-0000-0000-0000-000000000001', null,
  'CYC-5678', 'Micro antigo', 'Van expirada', 10
) as expired_van \gset
select public.save_route(
  '41000000-0000-0000-0000-000000000001', null,
  jsonb_build_object(
    'name','Rota expirada','direction','going','shift','evening',
    'van_id',:'expired_van','driver_user_id','40000000-0000-0000-0000-000000000003',
    'origin',jsonb_build_object('latitude',-23.55,'longitude',-46.63,'label','Origem'),
    'destination',jsonb_build_object('latitude',-23.56,'longitude',-46.65,'label','Destino'),
    'schools',jsonb_build_array(jsonb_build_object('school_id',(select id from planning_ids where kind='school'),'position',1))
  )
) as expired_route \gset
select public.save_route_schedule(
  :'expired_route', null,
  jsonb_build_object(
    'weekdays',jsonb_build_array(1,2,3,4,5),'starts_at','08:00','ends_at','09:00',
    'ends_next_day',false,'timezone','America/Sao_Paulo',
    'valid_from',current_date - 30,'valid_until',current_date - 1,
    'confirmation_minutes',30
  )
) as expired_schedule \gset
select is(
  public.deactivate_van(:'expired_van','agenda encerrada'),
  'inactive'::text,
  'van com rota somente histórica pode ser inativada'
);
select is(
  (select status from public.vans where id = :'expired_van'),
  'inactive'::text,
  'inativação de van histórica persiste'
);
select public.set_route_status(:'expired_route', 'inactive', 'rota encerrada') as expired_route_status \gset
select throws_ok(
  $$select public.set_route_status(
    (select id from public.routes where name = 'Rota expirada'), 'active', null
  )$$,
  'PGRST', null,
  'rota não pode reativar com veículo inativo'
);
reset role;
update public.route_schedules
set valid_from = current_date + 10
where id = (select id from planning_ids where kind = 'return-schedule');
select is(
  private.next_change_date(
    (select id from planning_ids where kind = 'request'),
    current_date::timestamptz
  ),
  (select min(d::date)
   from generate_series(current_date + 10, current_date + 90, interval '1 day') d
   where extract(isodow from d)::smallint between 1 and 5),
  'preview encontra a primeira interseção quando a volta começa depois da ida'
);
select throws_ok(
  $$select public.save_route(
    '41000000-0000-0000-0000-000000000002', null,
    jsonb_build_object('name','tenant leak','direction','going','shift','morning','van_id',(select id from planning_ids where kind = 'van'),'driver_user_id','40000000-0000-0000-0000-000000000003','origin',jsonb_build_object('latitude',0,'longitude',0,'label','A'),'destination',jsonb_build_object('latitude',1,'longitude',1,'label','B'),'schools',jsonb_build_array(jsonb_build_object('school_id',(select id from planning_ids where kind = 'school'),'position',1)))
  )$$,
  'PGRST', null, 'van de outra frota não é aceito'
);


select set_config('request.jwt.claims', '{"sub":"40000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select public.set_fleet_member_roles('42000000-0000-0000-0000-000000000002', array['owner','driver']);
select public.save_route(
  '41000000-0000-0000-0000-000000000001', null,
  jsonb_build_object(
    'name','Rota sem agenda','direction','going','shift','morning',
    'van_id',(select id from planning_ids where kind='van'),
    'driver_user_id','40000000-0000-0000-0000-000000000002',
    'origin',jsonb_build_object('latitude',0,'longitude',0,'label','Origem'),
    'destination',jsonb_build_object('latitude',1,'longitude',1,'label','Destino'),
    'schools',jsonb_build_array(jsonb_build_object('school_id',(select id from planning_ids where kind='school'),'position',1))
  )
);
select public.set_fleet_membership_status('42000000-0000-0000-0000-000000000002', 'suspended');
select throws_ok(
  $$select public.save_route_schedule(
    (select id from public.routes where name='Rota sem agenda'), null,
    jsonb_build_object('weekdays',jsonb_build_array(1),'starts_at','10:00','ends_at','11:00',
      'ends_next_day',false,'timezone','America/Sao_Paulo','valid_from',current_date+1,
      'valid_until',current_date+30,'confirmation_minutes',30))$$,
  'PGRST', null, 'agenda nova não atribui motorista suspenso após criar rota'
);
select throws_ok(
  $$select public.save_route_schedule(
    (select id from public.routes where name='Rota expirada'), null,
    jsonb_build_object('weekdays',jsonb_build_array(1),'starts_at','10:00','ends_at','11:00',
      'ends_next_day',false,'timezone','America/Sao_Paulo','valid_from',current_date+1,
      'valid_until',current_date+30,'confirmation_minutes',30))$$,
  'PGRST', null, 'agenda nova não atribui van inativa'
);

select jsonb_agg(
  jsonb_build_object('schedule_id', item.schedule_id, 'weekday', item.weekday)
  order by item.direction, item.weekday
) as allocation
from (
  select (select id from planning_ids where kind = 'going-schedule') as schedule_id,
         weekday, 'going' as direction
  from generate_series(1, 5) weekday
  union all
  select (select id from planning_ids where kind = 'return-schedule') as schedule_id,
         weekday, 'return' as direction
  from generate_series(1, 5) weekday
) item \gset
select set_config(
  'request.jwt.claims',
  '{"sub":"40000000-0000-0000-0000-000000000001","role":"authenticated"}',
  true
);
select public.approve_transport_request(
  (select id from planning_ids where kind = 'request'),
  :'allocation'::jsonb,
  current_date + 10
) as enrollment_id \gset
insert into public.schools (
  id, provider, external_id, institution_type, name, postal_code, street,
  street_number, neighborhood, city_name, city_ibge_code, state_code
) values (
  '65000000-0000-0000-0000-000000000010', 'inep', 'cycle3-route-extra-school', 'school',
  'Escola extra da rota', '18000000', 'Rua extra', '10', 'Centro', 'Cidade Teste',
  '3550000', 'SP'
);
insert into public.fleet_service_schools (fleet_id, school_id, created_by)
values (
  '41000000-0000-0000-0000-000000000001',
  '65000000-0000-0000-0000-000000000010',
  '40000000-0000-0000-0000-000000000001'
);
select lives_ok(
  $$select public.save_route(
    '41000000-0000-0000-0000-000000000001',
    (select id from planning_ids where kind = 'going-route'),
    jsonb_build_object(
      'name','Ciclo 3 ida','direction','going','shift','morning',
      'paired_route_id',(select id from planning_ids where kind='return-route'),
      'van_id',(select id from planning_ids where kind='van'),
      'driver_user_id','40000000-0000-0000-0000-000000000003',
      'origin',jsonb_build_object('latitude',-23.5505,'longitude',-46.6333,'label','Residência'),
      'destination',jsonb_build_object('latitude',-23.5610,'longitude',-46.6550,'label','Escola'),
      'schools',jsonb_build_array(
        jsonb_build_object('school_id','65000000-0000-0000-0000-000000000010','position',1),
        jsonb_build_object('school_id',(select id from planning_ids where kind='school'),'position',2)
      )
    )
  )$$,
  'adicionar e reordenar escolas não quebra reserva'
);
select results_eq(
  $$select school_id::text from public.route_schools
    where route_id=(select id from planning_ids where kind='going-route') order by position$$,
  $$values ('65000000-0000-0000-0000-000000000010'),
           ('65000000-0000-0000-0000-000000000001')$$,
  'rota mantém escola reservada ao adicionar e reordenar'
);
select throws_ok(
  $$select public.save_route(
    '41000000-0000-0000-0000-000000000001',
    (select id from planning_ids where kind = 'going-route'),
    jsonb_build_object(
      'name','Ciclo 3 ida','direction','going','shift','morning',
      'paired_route_id',(select id from planning_ids where kind='return-route'),
      'van_id',(select id from planning_ids where kind='van'),
      'driver_user_id','40000000-0000-0000-0000-000000000003',
      'origin',jsonb_build_object('latitude',-23.5505,'longitude',-46.6333,'label','Residência'),
      'destination',jsonb_build_object('latitude',-23.5610,'longitude',-46.6550,'label','Escola'),
      'schools',jsonb_build_array(
        jsonb_build_object('school_id','65000000-0000-0000-0000-000000000010','position',1)
      )
    )
  )$$,
  'PGRST', null, 'não remove escola necessária a reserva futura'
);

select public.save_route(
  '41000000-0000-0000-0000-000000000001', null,
  jsonb_build_object(
    'name','Rota inativa recurso C3','direction','going','shift','evening',
    'van_id',(select id from planning_ids where kind='van'),
    'driver_user_id','40000000-0000-0000-0000-000000000003',
    'origin',jsonb_build_object('latitude',-23.5505,'longitude',-46.6333,'label','Residência'),
    'destination',jsonb_build_object('latitude',-23.5610,'longitude',-46.6550,'label','Escola'),
    'schools',jsonb_build_array(jsonb_build_object('school_id',(select id from planning_ids where kind='school'),'position',1))
  )
) as inactive_route \gset
select public.save_route_schedule(
  :'inactive_route', null,
  jsonb_build_object('weekdays',jsonb_build_array(1),'starts_at','20:00','ends_at','21:00',
    'ends_next_day',false,'timezone','America/Sao_Paulo','valid_from',current_date+1,
    'valid_until',current_date+30,'confirmation_minutes',30)
) as inactive_schedule \gset
select public.set_route_status(:'inactive_route','inactive','temporariamente fora') as inactive_status \gset
select public.save_route(
  '41000000-0000-0000-0000-000000000001', null,
  jsonb_build_object(
    'name','Rota reuso recurso C3','direction','return','shift','evening',
    'van_id',(select id from planning_ids where kind='van'),
    'driver_user_id','40000000-0000-0000-0000-000000000003',
    'origin',jsonb_build_object('latitude',-23.5610,'longitude',-46.6550,'label','Escola'),
    'destination',jsonb_build_object('latitude',-23.5505,'longitude',-46.6333,'label','Residência'),
    'schools',jsonb_build_array(jsonb_build_object('school_id',(select id from planning_ids where kind='school'),'position',1))
  )
) as reuse_route \gset
select lives_ok(
  $$select public.save_route_schedule(
    (select id from public.routes where name='Rota reuso recurso C3'), null,
    jsonb_build_object('weekdays',jsonb_build_array(1),'starts_at','20:00','ends_at','21:00',
      'ends_next_day',false,'timezone','America/Sao_Paulo','valid_from',current_date+1,
      'valid_until',current_date+30,'confirmation_minutes',30))$$,
  'agenda pode reutilizar recurso de rota inativa'
);

select * from finish();
rollback;
