begin;

create extension if not exists pgtap with schema extensions;
\ir ../_helpers.psql

select plan(12);
select pg_temp.seed_cycle_2_users();

select set_config(
  'request.jwt.claims',
  '{"sub":"60000000-0000-0000-0000-000000000001","role":"authenticated"}',
  true
);
set local role authenticated;

select lives_ok(
  $$select public.create_minor_student(
    'Teste Menor', '2015-02-03', '18000000', 'Rua Teste', '10', null,
    'Centro', 'Teste', '3550000', 'SP', null, null
  )$$,
  'confirmed user creates a minor student'
);
select is(
  (select count(*)::integer from public.students where student_type = 'minor' and full_name = 'Teste Menor'),
  1,
  'minor student is stored once'
);
select is(
  (select count(*)::integer from public.student_guardians sg
   join public.students s on s.id = sg.student_id
   where s.full_name = 'Teste Menor' and sg.guardian_user_id = '60000000-0000-0000-0000-000000000001' and sg.is_primary and sg.status = 'active'),
  1,
  'minor creation creates one primary guardian'
);
select throws_ok(
  $$select public.create_minor_student(
    'Teste Adulto Invalido', (current_date - interval '18 years')::date, '18000000', 'Rua Teste', '10', null,
    'Centro', 'Teste', '3550000', 'SP', null, null
  )$$,
  'PGRST', null, 'minor creation rejects exact age eighteen'
);
select throws_ok(
  $$select public.create_minor_student(
    'Teste Coordenada Invalida', '2015-02-03', '18000000', 'Rua Teste', '10', null,
    'Centro', 'Teste', '3550000', 'SP', -23.5, null
  )$$,
  'PGRST', null, 'coordinates must be paired'
);

reset role;
select set_config(
  'request.jwt.claims',
  '{"sub":"60000000-0000-0000-0000-000000000003","role":"authenticated"}',
  true
);
set local role authenticated;

select lives_ok(
  $$select public.create_adult_student(
    'Teste Adulto', (current_date - interval '18 years')::date, '18000000', 'Rua Adulto', '20', null,
    'Centro', 'Teste', '3550000', 'SP', -23.5, -47.5
  )$$,
  'adult creates own student record at exact age eighteen'
);
select is(
  (select count(*)::integer from public.students where profile_id = '60000000-0000-0000-0000-000000000003' and student_type = 'adult'),
  1,
  'adult student is linked to own profile'
);
select is(
  (select count(*)::integer from public.student_guardians sg join public.students s on s.id = sg.student_id where s.profile_id = '60000000-0000-0000-0000-000000000003'),
  0,
  'adult does not receive guardian rows'
);
select throws_ok(
  $$select public.create_adult_student(
    'Teste Adulto Duplicado', (current_date - interval '18 years')::date, '18000000', 'Rua Adulto', '20', null,
    'Centro', 'Teste', '3550000', 'SP', null, null
  )$$,
  'PGRST', null, 'one adult student per profile is enforced'
);
select lives_ok(
  $$select public.update_student(
    (select id from public.students where profile_id = '60000000-0000-0000-0000-000000000003'),
    'Teste Adulto Atualizado', (current_date - interval '18 years')::date, '18000000', 'Rua Nova', '21', null,
    'Centro', 'Teste', '3550000', 'SP', null, null
  )$$,
  'adult updates own student'
);
select is(
  (select street from public.students where profile_id = '60000000-0000-0000-0000-000000000003'),
  'Rua Nova',
  'student address update is persisted'
);

reset role;
select set_config(
  'request.jwt.claims',
  '{"sub":"60000000-0000-0000-0000-000000000004","role":"authenticated"}',
  true
);
set local role authenticated;
select throws_ok(
  $$select public.create_adult_student(
    'Teste Não Confirmado', '2000-01-01', '18000000', 'Rua', '1', null,
    'Centro', 'Teste', '3550000', 'SP', null, null
  )$$,
  'PGRST', null, 'unconfirmed email cannot create a student'
);

select * from finish();

rollback;
