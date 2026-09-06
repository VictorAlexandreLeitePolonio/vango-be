begin;

create extension if not exists pgtap with schema extensions;
\ir ../_helpers.psql

select plan(9);
select pg_temp.seed_foundation();

select set_config(
  'request.jwt.claims',
  '{"sub":"40000000-0000-0000-0000-000000000001","role":"authenticated"}',
  true
);
set local role authenticated;

select lives_ok(
  $$update public.fleets
    set name = 'Fleet A Updated',
        slug = 'fleet-a-updated',
        description = 'Updated description',
        logo_path = 'fleets/fleet-a/logo.png',
        status = 'published'
    where id = '41000000-0000-0000-0000-000000000001'$$,
  'owner updates permitted fleet fields'
);

select ok(
  (
    select name = 'Fleet A Updated'
      and slug = 'fleet-a-updated'
      and description = 'Updated description'
      and logo_path = 'fleets/fleet-a/logo.png'
      and status = 'published'
    from public.fleets
    where id = '41000000-0000-0000-0000-000000000001'
  ),
  'all permitted fields are persisted'
);

select cmp_ok(
  (select updated_at from public.fleets where id = '41000000-0000-0000-0000-000000000001'),
  '>',
  (select created_at from public.fleets where id = '41000000-0000-0000-0000-000000000001'),
  'updated_at advances'
);

select is(
  (select count(*)::integer from public.audit_events where action = 'fleet_updated'),
  1,
  'one fleet_updated event is created'
);

select is(
  (select metadata from public.audit_events where action = 'fleet_updated'),
  '{"changed_fields":["name","slug","description","logo_path","status"]}'::jsonb,
  'audit metadata contains field names but no values'
);

select throws_ok(
  $$update public.fleets set status = 'suspended'
    where id = '41000000-0000-0000-0000-000000000001'$$,
  '42501', null, 'owner cannot set suspended through Data API'
);

reset role;
select set_config(
  'request.jwt.claims',
  '{"sub":"40000000-0000-0000-0000-000000000003","role":"authenticated"}',
  true
);
set local role authenticated;

update public.fleets
set name = 'Blocked member update'
where id = '41000000-0000-0000-0000-000000000001';

select is(
  (select count(*)::integer
   from public.fleets
   where id = '41000000-0000-0000-0000-000000000001'
     and name = 'Blocked member update'),
  0,
  'non-owner updates no fleet rows'
);

reset role;
select set_config(
  'request.jwt.claims',
  '{"sub":"40000000-0000-0000-0000-000000000001","role":"authenticated"}',
  true
);
set local role authenticated;

select throws_ok(
  $$update public.fleets
    set created_by = '40000000-0000-0000-0000-000000000002'
    where id = '41000000-0000-0000-0000-000000000001'$$,
  '42501', null, 'owner has no grant to change created_by'
);

update public.fleets
set name = 'Blocked tenant update'
where id = '41000000-0000-0000-0000-000000000002';

reset role;
select is(
  (select name from public.fleets where id = '41000000-0000-0000-0000-000000000002'),
  'Fleet B',
  'owner cannot update another tenant by known UUID'
);

select * from finish();
rollback;
