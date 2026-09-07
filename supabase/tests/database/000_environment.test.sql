begin;

create extension if not exists pgtap with schema extensions;

select plan(4);

select has_schema(
  'private',
  'private schema exists'
);

select ok(
  not has_schema_privilege('anon', 'private', 'usage'),
  'anon cannot use private schema'
);

select ok(
  has_schema_privilege('authenticated', 'private', 'usage'),
  'authenticated can resolve private RLS helpers'
);

select ok(
  has_function_privilege(
    'authenticated',
    'private.is_active_fleet_member(uuid, uuid)',
    'execute'
  )
  and not has_function_privilege(
    'anon',
    'private.is_active_fleet_member(uuid, uuid)',
    'execute'
  ),
  'only authenticated can execute the RLS helper'
);

select * from finish();

rollback;
