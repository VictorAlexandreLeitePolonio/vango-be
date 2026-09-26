begin;
create extension if not exists pgtap with schema extensions;
\ir ../_fleet_transport.psql
select no_plan();
select has_column('public','vans','edit_revision','Vans expose a configuration revision');
select pg_temp.seed_fleet_transport();
create temp table previous_versions as
 select id, edit_revision from public.vans where id=(select id from planning_ids where kind='van');
select public.save_van(fleet_id,(select id from planning_ids where kind='van'),'CYC1234','Updated','Updated',10) from transport_case;
select ok(v.edit_revision>p.edit_revision,'Legacy van edits advance configuration revision')
from public.vans v join previous_versions p using(id);
create temp table route_version as select id,edit_revision from public.routes where id=(select id from planning_ids where kind='going-route');
update public.route_schools set position=2 where route_id=(select id from route_version);
select ok(r.edit_revision>v.edit_revision,'School ordering advances parent configuration revision') from public.routes r join route_version v using(id);
create temp table schedule_version as select id,edit_revision from public.route_schedules where id=(select going_schedule_id from transport_case);
update public.route_schedules set confirmation_minutes=20 where id=(select id from schedule_version);
select ok(s.edit_revision>v.edit_revision,'Schedule configuration advances its edit revision') from public.route_schedules s join schedule_version v using(id);
update route_version set edit_revision=(select edit_revision from public.routes where id=route_version.id);
update public.routes set routing_revision=routing_revision+1 where id=(select id from route_version);
select is(r.edit_revision,v.edit_revision,'Calculation bookkeeping leaves edit revision unchanged') from public.routes r join route_version v using(id);
update public.routes set name='New route name' where id=(select id from route_version);
select ok(r.edit_revision>v.edit_revision,'Route fields invalidate open editors') from public.routes r join route_version v using(id);
select ok(not has_column_privilege('authenticated','public.routes','edit_revision','UPDATE'),'Client cannot forge route edit revisions');
select ok(not has_column_privilege('authenticated','public.vans','edit_revision','UPDATE'),'Client cannot forge van edit revisions');
select ok(not has_column_privilege('authenticated','public.route_schedules','edit_revision','UPDATE'),'Client cannot forge schedule edit revisions');
select * from finish();
rollback;
