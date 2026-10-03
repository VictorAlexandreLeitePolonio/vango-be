begin;
create extension if not exists pgtap with schema extensions;
\ir ../_fleet_planning.psql
select no_plan();
select has_function('public','save_van',array['uuid','uuid','text','text','text','integer','uuid','bigint'],'Van command overload exists');
select pg_temp.seed_fleet_transport();
create temp table saved_van as select public.save_van(fleet_id,null,'NEW1234','Model','School van',12,command_a,null) id from transport_case;
select is(pg_temp.fleet_transport_error(format('select public.save_van(%L,null,%L,%L,%L,12,%L,null)',fleet_id,'NEW1234','Model','School van',command_a)),null,'Identical create replay returns success') from transport_case;
select has_function('public','save_route',array['uuid','uuid','jsonb','uuid','bigint'],'Route command overload exists');
select has_function('public','save_route_schedule',array['uuid','uuid','jsonb','uuid','bigint'],'Schedule command overload exists');
select has_function('public','enable_owner_driving',array['uuid','uuid'],'Owner driver adapter exists');
select is((select count(*)::integer from private.fleet_planning_commands),1,'One receipt for replayed creation');
select is(public.save_van(fleet_id,null,'new-1234','Model','School van',12,command_a,null),(select id from saved_van),'Plate normalization preserves command identity') from transport_case;
select is(pg_temp.fleet_transport_error(format('select public.save_van(%L,null,%L,%L,%L,13,%L,null)',fleet_id,'NEW1234','Model','School van',command_a)), 'idempotency_conflict','Changed command payload is rejected') from transport_case;
select public.save_van(fleet_id,(select id from saved_van),'NEW1234','Changed','School van',12,command_b,1) from transport_case;
select is(pg_temp.fleet_transport_error(format('select public.save_van(%L,%L,%L,%L,%L,12,%L,1)',fleet_id,(select id from saved_van),'NEW1234','Lost edit','School van',gen_random_uuid())), 'revision_conflict','Competing stale edit does not overwrite accepted configuration') from transport_case;
select public.save_van(fleet_id,null,'NEW1234','Model','School van',12,command_a,null) from transport_case;
select is((select model from public.vans where id=(select id from saved_van)), 'Changed','Late creation replay leaves later edits intact');
select public.enable_owner_driving(fleet_id,gen_random_uuid()) from transport_case;
select ok(private.has_fleet_role(fleet_id,owner_id,'driver'),'Owner explicitly enabled self driving') from transport_case;
select ok(private.has_fleet_role(fleet_id,owner_id,'owner'),'Owner role survives self enablement') from transport_case;
select is(pg_temp.fleet_transport_error(format('select public.save_van(%L,null,%L,%L,%L,12,%L,1)',fleet_id,'BAD1234','Model','Name',gen_random_uuid())), 'invalid_input','Creation cannot carry expected revision') from transport_case;
select ok(not has_table_privilege('authenticated','private.fleet_planning_commands','SELECT'),'Clients cannot read receipts');
select ok(not has_table_privilege('authenticated','private.fleet_planning_commands','INSERT'),'Clients cannot forge receipts');
select is((select pronargdefaults::integer from pg_proc where oid='public.save_van(uuid,uuid,text,text,text,integer,uuid,bigint)'::regprocedure),0,'New overload has no optional named arguments');
select has_function('public','link_fleet_service_city',array['uuid','text','uuid'],'City linking command exists');
select has_function('public','link_fleet_service_school',array['uuid','uuid','uuid'],'School linking command exists');
select is(pg_temp.fleet_transport_error(format('select public.save_route(%L,null,%L::jsonb,%L,null)',fleet_id,
 pg_temp.route_config((select id from planning_ids where kind='going-route')) || '{"unexpected":true}'::jsonb,gen_random_uuid())), 'invalid_input','Unknown route command keys cannot disappear') from transport_case;
create temp table schedule_command as select gen_random_uuid() command, s.id, s.route_id, s.edit_revision, pg_temp.schedule_config(s.id) config
from public.route_schedules s where s.id=(select going_schedule_id from transport_case);
select public.save_route_schedule(route_id,id,config,command,edit_revision) from schedule_command;
select is(pg_temp.fleet_transport_error(format('select public.save_route_schedule(%L,%L,%L::jsonb,%L,%L)',route_id,id,
 jsonb_set(config,'{weekdays}','[5,4,3,2,1]'),command,edit_revision)),null,'Weekday set order does not change command identity') from schedule_command;
select is(pg_temp.fleet_transport_error(format('select public.save_route(%L,null,%L::jsonb,%L,null)',fleet_id,
 jsonb_set(pg_temp.route_config((select id from planning_ids where kind='going-route')),'{origin,ignored}','true'),gen_random_uuid())), 'invalid_input','Unknown nested point keys are rejected') from transport_case;

create temp table before_fault as select (select count(*) from public.vans) vans,(select count(*) from public.audit_events) audits,(select count(*) from private.fleet_planning_commands) receipts;
create function pg_temp.fail_planning_receipt() returns trigger language plpgsql as $$begin raise exception 'injected receipt failure'; end;$$;
create trigger test_receipt_failure before insert on private.fleet_planning_commands for each row execute function pg_temp.fail_planning_receipt();
select throws_ok(format('select public.save_van(%L,null,%L,%L,%L,12,%L,null)',fleet_id,'ERR1234','Model','Fault',gen_random_uuid()),'P0001','injected receipt failure','Receipt failure aborts the complete command') from transport_case;
select is((select count(*) from public.vans),(select vans from before_fault),'Receipt failure rolls back the entity');
select is((select count(*) from public.audit_events),(select audits from before_fault),'Receipt failure rolls back audit');
select is((select count(*) from private.fleet_planning_commands),(select receipts from before_fault),'Receipt failure leaves no partial receipt');
drop trigger test_receipt_failure on private.fleet_planning_commands;
create trigger test_audit_failure before insert on public.audit_events for each row execute function pg_temp.fail_planning_receipt();
select throws_ok(format('select public.save_van(%L,null,%L,%L,%L,12,%L,null)',fleet_id,'ERR1234','Model','Fault',gen_random_uuid()),'P0001','injected receipt failure','Audit failure aborts the complete command') from transport_case;
select is((select count(*) from public.vans),(select vans from before_fault),'Audit failure rolls back the entity');
select is((select count(*) from private.fleet_planning_commands),(select receipts from before_fault),'Audit failure leaves no receipt');
drop trigger test_audit_failure on public.audit_events;

select is(pg_temp.fleet_transport_error(format('select public.save_route(%L,null,%L::jsonb,%L,null)',fleet_id,
 jsonb_set(pg_temp.route_config((select id from planning_ids where kind='going-route')),'{schools,0,ignored}','true'),gen_random_uuid())), 'invalid_input','Unknown nested school keys are rejected') from transport_case;
select ok(has_function_privilege('authenticated',signature,'EXECUTE') and not has_function_privilege('anon',signature,'EXECUTE'),'Only authenticated clients can execute '||signature)
from unnest(array['public.save_van(uuid,uuid,text,text,text,integer,uuid,bigint)','public.save_route(uuid,uuid,jsonb,uuid,bigint)','public.save_route_schedule(uuid,uuid,jsonb,uuid,bigint)','public.enable_owner_driving(uuid,uuid)','public.link_fleet_service_city(uuid,text,uuid)','public.link_fleet_service_school(uuid,uuid,uuid)']) signature;
select ok(p.prosecdef and p.pronargdefaults=0 and 'search_path=""'=any(p.proconfig),'Command uses definer, safe search path and no defaults: '||p.proname)
from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and 'p_command_id'=any(p.proargnames) and p.proname in ('save_van','save_route','save_route_schedule','enable_owner_driving','link_fleet_service_city','link_fleet_service_school');
create temp table driving_replay as select gen_random_uuid() command;
select public.enable_owner_driving(fleet_id,(select command from driving_replay)) from transport_case;
select public.set_fleet_member_roles('42000000-0000-0000-0000-000000000001',array['owner']);
select public.enable_owner_driving(fleet_id,(select command from driving_replay)) from transport_case;
select ok(not private.has_fleet_role(fleet_id,owner_id,'driver'),'Old driving replay never restores a subsequently removed role') from transport_case;
create temp table route_replay as select gen_random_uuid() command,pg_temp.route_config((select id from planning_ids where kind='going-route')) config;
select public.save_route(fleet_id,null,config,command,null) from transport_case cross join route_replay;
select is(pg_temp.fleet_transport_error(format('select public.save_route(%L,null,%L::jsonb,%L,null)',fleet_id,jsonb_set(config,'{name}',to_jsonb('  '||(config->>'name')||'  ')),command)),null,'Route names normalized by legacy persistence preserve command identity') from transport_case cross join route_replay;
select * from finish();
rollback;
