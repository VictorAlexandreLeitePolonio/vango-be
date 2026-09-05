begin;

create extension if not exists pgtap with schema extensions;

select plan(3);

select has_schema(
  'private',
  'private schema exists'
);

select ok(
  not has_schema_privilege('anon', 'private', 'usage'),
  'anon cannot use private schema'
);

select ok(
  not has_schema_privilege('authenticated', 'private', 'usage'),
  'authenticated cannot use private schema'
);

select * from finish();

rollback;
