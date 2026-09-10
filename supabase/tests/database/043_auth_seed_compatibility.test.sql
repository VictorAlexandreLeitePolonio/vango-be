begin;

create extension if not exists pgtap with schema extensions;

select plan(2);

select is(
  (
    select count(*)::integer
    from auth.users
    where email like 'seed-%@example.test'
  ),
  5,
  'all local Auth seed users are present'
);

select ok(
  not exists (
    select 1
    from auth.users
    where email like 'seed-%@example.test'
      and (
        confirmation_token is null
        or recovery_token is null
        or email_change_token_new is null
        or email_change is null
      )
  ),
  'local Auth seed users have non-null token fields for recovery'
);

select * from finish();

rollback;
