begin;
create extension if not exists pgtap with schema extensions;
\ir ../_fleet_planning.psql
\ir ../_fleet_planning_baseline.psql
select no_plan();
select pg_temp.seed_fleet_transport();
select ok(public.get_fleet_planning(fleet_id)?'service_cities','Owner projection includes coverage') from transport_case;
select ok(public.get_fleet_planning(fleet_id)->'routes'->0 ? 'origin','Owner routes include editable endpoints') from transport_case;
select ok(public.get_fleet_planning(fleet_id) @> pg_temp.previous_fleet_planning(fleet_id),'All integrated projection fields and values survive the additive extension') from transport_case;
update public.profiles set full_name=null where id='40000000-0000-0000-0000-000000000003';
select ok(exists(select 1 from jsonb_array_elements(public.get_fleet_planning(fleet_id)->'drivers') d where d->>'user_id'='40000000-0000-0000-0000-000000000003' and d->'display_name'='null'::jsonb),'Driver without profile name remains selectable without exposing email') from transport_case;
select set_config('request.jwt.claims','{"sub":"40000000-0000-0000-0000-000000000003","role":"authenticated"}',true);
select is(public.get_fleet_planning(fleet_id),pg_temp.previous_fleet_planning(fleet_id),'Driver projection remains exactly unchanged') from transport_case;
select * from finish();
rollback;
