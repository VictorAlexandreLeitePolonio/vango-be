begin;
create extension if not exists pgtap with schema extensions;
\ir ../_helpers.psql
\ir ../_planning.psql
\ir ../_operations.psql
\ir ../_tracking.psql
select plan(25);
select has_function('public','sync_trip_events',array['uuid','uuid','jsonb'],'offline presence RPC exists');
select pg_temp.seed_tracking();
create temp table offline_batch as select jsonb_build_array(
 jsonb_build_object('command_id','77000000-0000-0000-0000-000000000002','sequence',2,'student_id',(select id from tracking_ids where kind='student'),'kind','dropped_off','captured_at',clock_timestamp()-interval '10 seconds'),
 jsonb_build_object('command_id','77000000-0000-0000-0000-000000000001','sequence',1,'student_id',(select id from tracking_ids where kind='student'),'kind','boarded','captured_at',clock_timestamp()-interval '20 seconds')
) as events;
select set_config('request.jwt.claims','{"sub":"40000000-0000-0000-0000-000000000003","role":"authenticated"}',true);
select is((select string_agg(e->>'status',',' order by ord) from jsonb_array_elements(public.sync_trip_events((select id from tracking_ids where kind='trip'),(select id from tracking_ids where kind='assignment'),(select events from offline_batch))) with ordinality as r(e,ord)), 'accepted,accepted','out-of-order batch applies in sequence');
select is((select operation_status from public.trip_passengers where id=(select id from tracking_ids where kind='passenger')),'dropped_off','boarding and drop both applied');
select is((select string_agg(e->>'status',',' order by ord) from jsonb_array_elements(public.sync_trip_events((select id from tracking_ids where kind='trip'),(select id from tracking_ids where kind='assignment'),(select events from offline_batch))) with ordinality as r(e,ord)), 'duplicate,duplicate','retry does not append again');
select is((select count(*) from public.trip_events where command_id in ('77000000-0000-0000-0000-000000000001','77000000-0000-0000-0000-000000000002')),2::bigint,'exactly two facts persisted');
select is(public.sync_trip_events((select id from tracking_ids where kind='trip'),(select id from tracking_ids where kind='assignment'),jsonb_build_array(jsonb_set((select events->1 from offline_batch),'{kind}','"absent"'))) ->0->>'status','conflict','same sequence with another payload conflicts');

select is(public.sync_trip_events((select id from tracking_ids where kind='trip'),(select id from tracking_ids where kind='assignment'),jsonb_build_array('null'::jsonb,(select events->1 from offline_batch)))->0->>'status','duplicate','valid retry survives malformed neighbor');
select throws_ok($$select public.sync_trip_events((select id from tracking_ids where kind='trip'),(select id from tracking_ids where kind='assignment'),(select jsonb_agg('{}'::jsonb) from generate_series(1,101)))$$,'PGRST',null,'oversized batches are rejected');
update public.trip_passengers set operation_status='waiting',confirmation_status='expired' where id=(select id from tracking_ids where kind='passenger');
select throws_ok($$select public.record_passenger_event((select id from tracking_ids where kind='trip'),(select id from tracking_ids where kind='student'),'absent','77000000-0000-0000-0000-000000000088')$$,'PGRST',null,'online absence cannot create a fact for non-executable passenger');
update public.trip_passengers set operation_status='dropped_off',confirmation_status='confirmed' where id=(select id from tracking_ids where kind='passenger');
-- Invalid items do not abort a valid neighbor; new events cannot reopen a finished trip.
select is(public.sync_trip_events((select id from tracking_ids where kind='trip'),(select id from tracking_ids where kind='assignment'),'[null,{"sequence":"wrong"}]')->0->>'code','invalid_input','null item is rejected');
select is(jsonb_array_length(public.sync_trip_events((select id from tracking_ids where kind='trip'),(select id from tracking_ids where kind='assignment'),'[null,{"sequence":"wrong"}]')),2,'one result for each malformed item');
select is(public.sync_trip_events((select id from tracking_ids where kind='trip'),(select id from tracking_ids where kind='assignment'),jsonb_build_array(
 (select events->1 from offline_batch)||jsonb_build_object('command_id','77000000-0000-0000-0000-000000000003','sequence',3,'captured_at',clock_timestamp()+interval '1 minute')))->0->>'code','invalid_capture_time','future capture is rejected');
select is(public.sync_trip_events((select id from tracking_ids where kind='trip'),(select id from tracking_ids where kind='assignment'),jsonb_build_array(
 (select events->1 from offline_batch)||jsonb_build_object('command_id','77000000-0000-0000-0000-000000000003','sequence',3,'captured_at',clock_timestamp()-interval '2 minutes')))->0->>'code','invalid_capture_time','capture before trip started is rejected');
select is(public.sync_trip_events((select id from tracking_ids where kind='trip'),(select id from tracking_ids where kind='assignment'),jsonb_build_array(
 (select events->1 from offline_batch)||jsonb_build_object('command_id','77000000-0000-0000-0000-000000000003','sequence',3,'captured_at',clock_timestamp()-interval '30 seconds')))->0->>'code','stale_event','older presence cannot overwrite more recent fact');
select is(public.sync_trip_events((select id from tracking_ids where kind='trip'),(select id from tracking_ids where kind='assignment'),jsonb_build_array(
 (select events->1 from offline_batch)||jsonb_build_object('command_id','77000000-0000-0000-0000-000000000003','sequence',3,'captured_at',clock_timestamp()-interval '1 second','student_id','77000000-0000-0000-0000-000000000099')))->0->>'code','passenger_not_executable','arbitrary student cannot enter an active trip');
update public.trips set status='completed',ended_at=clock_timestamp() where id=(select id from tracking_ids where kind='trip');
select is(public.sync_trip_events((select id from tracking_ids where kind='trip'),(select id from tracking_ids where kind='assignment'),jsonb_build_array(
 (select events->1 from offline_batch)||jsonb_build_object('command_id','77000000-0000-0000-0000-000000000003','sequence',3,'captured_at',clock_timestamp()-interval '1 second')))->0->>'code','trip_not_active','completed trip rejects new presence');
select is(public.sync_trip_events((select id from tracking_ids where kind='trip'),(select id from tracking_ids where kind='assignment'),(select events from offline_batch))->0->>'status','duplicate','completed trip permits authorized retry');
select set_config('request.jwt.claims','{"sub":"40000000-0000-0000-0000-000000000002","role":"authenticated"}',true);
select throws_ok($$select public.sync_trip_events((select id from tracking_ids where kind='trip'),(select id from tracking_ids where kind='assignment'),(select events from offline_batch))$$,'PGRST',null,'other tenant cannot replay assignment');
select set_config('request.jwt.claims','{"sub":"40000000-0000-0000-0000-000000000003","role":"authenticated"}',true);
-- A historical assignment remains eligible only while the uploader is currently a driver.
update public.trip_assignments set valid_until=clock_timestamp()-interval '5 seconds' where id=(select id from tracking_ids where kind='assignment');
update public.trips set status='active',ended_at=null,driver_user_id='40000000-0000-0000-0000-000000000001' where id=(select id from tracking_ids where kind='trip');
update public.trip_passengers set operation_status='waiting' where id=(select id from tracking_ids where kind='passenger');
select is(public.sync_trip_events((select id from tracking_ids where kind='trip'),(select id from tracking_ids where kind='assignment'),jsonb_build_array(
 (select events->1 from offline_batch)||jsonb_build_object('command_id','77000000-0000-0000-0000-000000000003','sequence',3,'captured_at',clock_timestamp()-interval '1 second')))->0->>'code','invalid_capture_time','old driver cannot claim capture after substitution');
select is(public.sync_trip_events((select id from tracking_ids where kind='trip'),(select id from tracking_ids where kind='assignment'),jsonb_build_array(
 (select events->1 from offline_batch)||jsonb_build_object('command_id','77000000-0000-0000-0000-000000000003','sequence',3,'captured_at',clock_timestamp()-interval '7 seconds')))->0->>'status','accepted','still eligible old driver may upload valid pre-substitution capture');
select set_config('request.jwt.claims','{"sub":"40000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select is(public.record_passenger_event((select id from tracking_ids where kind='trip'),(select id from tracking_ids where kind='student'),'dropped_off','77000000-0000-0000-0000-000000000004'),'dropped_off','online wrapper shares transition writer');
select set_config('request.jwt.claims','{"sub":"40000000-0000-0000-0000-000000000003","role":"authenticated"}',true);
select is(public.sync_trip_events((select id from tracking_ids where kind='trip'),(select id from tracking_ids where kind='assignment'),jsonb_build_array(
 (select events->1 from offline_batch)||jsonb_build_object('command_id','77000000-0000-0000-0000-000000000005','sequence',4,'captured_at',clock_timestamp()-interval '6 seconds')))->0->>'code','stale_event','offline capture cannot overwrite latest online correction');
-- Remove the old role after replacement; even exact accepted commands lose access.
delete from public.fleet_membership_roles where role='driver' and membership_id in (
 select id from public.fleet_memberships where fleet_id=(select id from tracking_ids where kind='fleet') and user_id='40000000-0000-0000-0000-000000000003');
select throws_ok($$select public.sync_trip_events((select id from tracking_ids where kind='trip'),(select id from tracking_ids where kind='assignment'),(select events from offline_batch))$$,'PGRST',null,'revoked driver cannot replay historical data');
select ok(not has_function_privilege('authenticated','private.apply_passenger_event(uuid,uuid,text,uuid,timestamptz,jsonb)','EXECUTE'),'clients cannot bypass public authorization through shared writer');
select ok(not has_table_privilege('authenticated','public.trip_events','INSERT'),'clients cannot write offline ledger directly');

select * from finish();
rollback;
