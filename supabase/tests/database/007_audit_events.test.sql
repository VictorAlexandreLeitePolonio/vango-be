begin;

create extension if not exists pgtap with schema extensions;
\ir ../_helpers.psql

select plan(8);
select pg_temp.seed_foundation();

insert into public.audit_events (
  id, fleet_id, actor_user_id, action, entity_type, entity_id, metadata
) values
  (
    '43000000-0000-0000-0000-000000000001',
    '41000000-0000-0000-0000-000000000001',
    '40000000-0000-0000-0000-000000000001',
    'fleet_updated',
    'fleet',
    '41000000-0000-0000-0000-000000000001',
    '{"changed_fields":["name"]}'::jsonb
  ),
  (
    '43000000-0000-0000-0000-000000000002',
    '41000000-0000-0000-0000-000000000002',
    '40000000-0000-0000-0000-000000000005',
    'fleet_updated',
    'fleet',
    '41000000-0000-0000-0000-000000000002',
    '{"changed_fields":["status"]}'::jsonb
  );

select set_config(
  'request.jwt.claims',
  '{"sub":"40000000-0000-0000-0000-000000000001","role":"authenticated"}',
  true
);
set local role authenticated;

select is((select count(*)::integer from public.audit_events), 1, 'owner reads own fleet events');
select is(
  (select count(*)::integer from public.audit_events where fleet_id = '41000000-0000-0000-0000-000000000002'),
  0,
  'owner reads no events from another tenant'
);
select is(
  (select metadata from public.audit_events),
  '{"changed_fields":["name"]}'::jsonb,
  'sanitized metadata contains no changed values'
);

reset role;
select set_config(
  'request.jwt.claims',
  '{"sub":"40000000-0000-0000-0000-000000000003","role":"authenticated"}',
  true
);
set local role authenticated;
select is((select count(*)::integer from public.audit_events), 0, 'non-owner reads no audit events');

reset role;
select set_config('request.jwt.claims', '', true);
set local role anon;
select throws_ok(
  $$select count(*) from public.audit_events$$,
  '42501', null, 'anonymous cannot read audit events'
);

reset role;
select set_config(
  'request.jwt.claims',
  '{"sub":"40000000-0000-0000-0000-000000000001","role":"authenticated"}',
  true
);
set local role authenticated;

select throws_ok(
  $$insert into public.audit_events (
      fleet_id, actor_user_id, action, entity_type, entity_id
    ) values (
      '41000000-0000-0000-0000-000000000001',
      '40000000-0000-0000-0000-000000000001',
      'forged',
      'fleet',
      '41000000-0000-0000-0000-000000000001'
    )$$,
  '42501', null, 'authenticated cannot insert audit events'
);

select throws_ok(
  $$update public.audit_events set action = 'forged'
    where id = '43000000-0000-0000-0000-000000000001'$$,
  '42501', null, 'authenticated cannot update audit events'
);

select throws_ok(
  $$delete from public.audit_events
    where id = '43000000-0000-0000-0000-000000000001'$$,
  '42501', null, 'authenticated cannot delete audit events'
);

select * from finish();
rollback;
