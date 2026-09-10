begin;

create extension if not exists pgtap with schema extensions;
\ir ../_helpers.psql
\ir ../_planning.psql

select plan(18);
select has_function(
  'private', 'assert_van_releasable', array['uuid'],
  'guard de liberação de van existe'
);
select has_function(
  'private', 'assert_driver_releasable', array['uuid', 'uuid'],
  'guard de liberação de motorista existe'
);

set local time zone 'Pacific/Kiritimati';
select is(
  current_setting('TimeZone'),
  'Pacific/Kiritimati',
  'o teste fixa o fuso do relógio da sessão'
);

select pg_temp.seed_cycle_3();
update public.route_schedules
set status = 'inactive'
where id in (
  (select id from planning_ids where kind = 'going-schedule'),
  (select id from planning_ids where kind = 'return-schedule')
);

create temp table resource_release_fixture(
  van_id uuid not null,
  driver_id uuid not null,
  route_id uuid not null,
  schedule_id uuid not null,
  schedule_date date not null,
  trip_id uuid
) on commit drop;

select set_config(
  'request.jwt.claims',
  '{"sub":"40000000-0000-0000-0000-000000000001","role":"authenticated"}',
  true
);

do $fixture$
declare
  v_local_now timestamp := clock_timestamp() at time zone 'Etc/GMT+12';
  v_service_date date := v_local_now::date;
  v_route_id uuid := (select id from planning_ids where kind = 'going-route');
  v_van_id uuid := (select id from planning_ids where kind = 'van');
  v_driver_id uuid := '40000000-0000-0000-0000-000000000003';
  v_schedule_id uuid;
begin
  v_schedule_id := public.save_route_schedule(
    v_route_id,
    null,
    jsonb_build_object(
      'weekdays', jsonb_build_array(extract(isodow from v_service_date)::integer),
      'starts_at', to_char(v_local_now::time + interval '2 minutes', 'HH24:MI'),
      'ends_at', to_char((v_local_now + interval '5 minutes')::time, 'HH24:MI'),
      'ends_next_day', (v_local_now + interval '5 minutes')::date > v_service_date,
      'timezone', 'Etc/GMT+12',
      'valid_from', v_service_date::text,
      'valid_until', v_service_date::text,
      'confirmation_minutes', 0
    )
  );
  insert into resource_release_fixture(
    van_id, driver_id, route_id, schedule_id, schedule_date
  ) values (
    v_van_id, v_driver_id, v_route_id, v_schedule_id, v_service_date
  );
end;
$fixture$;

select ok(
  (select schedule_date < current_date from resource_release_fixture),
  'agenda Etc/GMT+12 usa a data local anterior à data da sessão'
);
select ok(
  exists (
    select 1
    from resource_release_fixture f
    cross join lateral private.schedule_windows(f.schedule_id, f.schedule_date, f.schedule_date) w
    where upper(w."window") > clock_timestamp()
  ),
  'janela local termina depois do relógio real'
);
select throws_ok(
  $$select private.assert_van_releasable((select van_id from resource_release_fixture))$$,
  'PGRST', null,
  'van não é liberada enquanto a janela futura cruza o próximo dia UTC'
);
select throws_ok(
  $$select private.assert_driver_releasable(
    '41000000-0000-0000-0000-000000000001',
    (select driver_id from resource_release_fixture)
  )$$,
  'PGRST', null,
  'motorista não é liberado enquanto a janela futura cruza o próximo dia UTC'
);

do $closed$
declare
  v_local_now timestamp := clock_timestamp() at time zone 'Etc/GMT+12';
  v_start timestamp := v_local_now - interval '30 minutes';
  v_end timestamp := v_local_now - interval '20 minutes';
begin
  update public.route_schedules
  set weekdays = array[extract(isodow from v_start::date)::smallint],
      starts_at = v_start::time,
      ends_at = v_end::time,
      ends_next_day = v_end::date > v_start::date,
      valid_from = v_start::date,
      valid_until = v_start::date,
      status = 'active'
  where id = (select schedule_id from resource_release_fixture);
end;
$closed$;

select ok(
  not exists (
    select 1
    from resource_release_fixture f
    cross join lateral private.schedule_windows(f.schedule_id, f.schedule_date - 1, f.schedule_date) w
    where upper(w."window") > clock_timestamp()
  ),
  'janela encerrada não fica futura por causa da data global'
);
select lives_ok(
  $$select private.assert_van_releasable((select van_id from resource_release_fixture))$$,
  'van pode ser liberada após a última janela terminar'
);
select lives_ok(
  $$select private.assert_driver_releasable(
    '41000000-0000-0000-0000-000000000001',
    (select driver_id from resource_release_fixture)
  )$$,
  'motorista pode ser liberado após a última janela terminar'
);

update public.route_schedules
set status = 'inactive'
where id = (select schedule_id from resource_release_fixture);

do $trip$
declare
  v_fixture resource_release_fixture%rowtype;
  v_day_id uuid;
  v_trip_id uuid;
  v_now timestamptz := clock_timestamp();
begin
  select * into v_fixture from resource_release_fixture;
  insert into public.service_days(fleet_id, service_date)
  values ('41000000-0000-0000-0000-000000000001', current_date - 1)
  on conflict (fleet_id, service_date) do update
    set service_date = excluded.service_date
  returning id into v_day_id;
  insert into public.trips(
    fleet_id, service_day_id, route_id, schedule_id, service_date,
    planned_start_at, reserved_until, confirmation_deadline, status,
    van_id, driver_user_id
  ) values (
    '41000000-0000-0000-0000-000000000001', v_day_id,
    v_fixture.route_id, v_fixture.schedule_id, current_date - 1,
    v_now + interval '10 minutes', v_now + interval '20 minutes',
    v_now + interval '5 minutes', 'scheduled', v_fixture.van_id, v_fixture.driver_id
  ) returning id into v_trip_id;
  insert into public.trip_assignments(
    fleet_id, trip_id, van_id, driver_user_id, valid_from, reason
  ) values (
    '41000000-0000-0000-0000-000000000001', v_trip_id,
    v_fixture.van_id, v_fixture.driver_id, v_now, 'timezone regression'
  );
  update resource_release_fixture set trip_id = v_trip_id;
end;
$trip$;

select ok(
  (select service_date < current_date from public.trips
   where id = (select trip_id from resource_release_fixture)),
  'viagem tem data anterior à sessão para reproduzir a virada UTC'
);
select ok(
  (select reserved_until > clock_timestamp() from public.trips
   where id = (select trip_id from resource_release_fixture)),
  'fim planejado da viagem ainda está no futuro real'
);
select throws_ok(
  $$select private.assert_van_releasable((select van_id from resource_release_fixture))$$,
  'PGRST', null,
  'van mantém bloqueio quando viagem agendada termina no futuro real'
);
select throws_ok(
  $$select private.assert_driver_releasable(
    '41000000-0000-0000-0000-000000000001',
    (select driver_id from resource_release_fixture)
  )$$,
  'PGRST', null,
  'motorista mantém bloqueio quando viagem agendada termina no futuro real'
);

update public.trips
set planned_start_at = clock_timestamp() - interval '30 minutes',
    reserved_until = clock_timestamp() - interval '20 minutes',
    confirmation_deadline = clock_timestamp() - interval '40 minutes'
where id = (select trip_id from resource_release_fixture);
select lives_ok(
  $$select private.assert_van_releasable((select van_id from resource_release_fixture))$$,
  'van pode ser liberada quando viagem agendada já terminou'
);
select lives_ok(
  $$select private.assert_driver_releasable(
    '41000000-0000-0000-0000-000000000001',
    (select driver_id from resource_release_fixture)
  )$$,
  'motorista pode ser liberado quando viagem agendada já terminou'
);

update public.trips
set status = 'active'
where id = (select trip_id from resource_release_fixture);
select throws_ok(
  $$select private.assert_van_releasable((select van_id from resource_release_fixture))$$,
  'PGRST', null,
  'van continua bloqueada enquanto a viagem está ativa'
);
select throws_ok(
  $$select private.assert_driver_releasable(
    '41000000-0000-0000-0000-000000000001',
    (select driver_id from resource_release_fixture)
  )$$,
  'PGRST', null,
  'motorista continua bloqueado enquanto a viagem está ativa'
);

select * from finish();
rollback;
