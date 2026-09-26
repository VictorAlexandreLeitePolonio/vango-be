begin;
create extension if not exists pgtap with schema extensions;
\ir ../_fleet_transport.psql
select no_plan();
select pg_temp.seed_fleet_transport();
set local role authenticated;
select ok(exists(select 1 from jsonb_array_elements(public.get_fleet_planning(c.fleet_id)->'enrollment_revisions') item
 where item->>'enrollment_id'=c.enrollment_id::text and (item->>'routing_revision')::bigint=c.initial_revision),
 'owner sees revision before allocation') from transport_case c;
reset role;
select set_config('request.jwt.claims','{"sub":"40000000-0000-0000-0000-000000000003","role":"authenticated"}',true);
set local role authenticated;
select is(public.get_fleet_planning(fleet_id)->'enrollment_revisions','[]'::jsonb,'driver has no owner enrollment revisions') from transport_case;
reset role;
select * from finish();
rollback;
