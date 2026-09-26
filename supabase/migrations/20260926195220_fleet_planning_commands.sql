-- Durable command receipts belong to planning, not registration or allocation.
create table private.fleet_planning_commands (
 fleet_id uuid not null references public.fleets(id) on delete restrict,
 command_id uuid not null,
 actor_user_id uuid not null references auth.users(id) on delete restrict,
 operation text not null check(operation in ('van','route','schedule','driving','city','school')),
 payload_hash bytea not null check(octet_length(payload_hash)=32),
 result jsonb not null,
 created_at timestamptz not null default clock_timestamp(),
 primary key(fleet_id,command_id)
);
create index fleet_planning_commands_actor_idx on private.fleet_planning_commands(actor_user_id);
alter table private.fleet_planning_commands enable row level security;
revoke all on private.fleet_planning_commands from public,anon,authenticated;
create trigger fleet_planning_commands_immutable before update or delete on private.fleet_planning_commands
 for each row execute function private.reject_transport_receipt_mutation();

-- All six commands share current access checks and the existing planning lock.
create function private.planning_command_receipt(p_fleet uuid,p_command uuid,p_operation text,p_payload jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_receipt private.fleet_planning_commands%rowtype;
begin
 if auth.uid() is null then perform private.raise_api_error('unauthenticated','Authentication required',401); end if;
 perform private.lock_planning();
 if not private.current_user_email_confirmed() then perform private.raise_api_error('email_unverified','Email confirmation required',403); end if;
 if p_fleet is null or not private.has_fleet_role(p_fleet,auth.uid(),'owner') then perform private.raise_api_error('not_found','Fleet not found',404); end if;
 if p_command is null then perform private.raise_api_error('invalid_input','Command is required',400); end if;
 select * into v_receipt from private.fleet_planning_commands where fleet_id=p_fleet and command_id=p_command;
 if found then
   if v_receipt.actor_user_id<>auth.uid() or v_receipt.operation<>p_operation
     or v_receipt.payload_hash<>extensions.digest(jsonb_build_array(1,p_operation,p_payload)::text,'sha256') then
     perform private.raise_api_error('idempotency_conflict','Command already used with different input',409);
   end if;
   return v_receipt.result;
 end if;
 return null;
end;
$$;
revoke all on function private.planning_command_receipt(uuid,uuid,text,jsonb) from public,anon,authenticated;

create function private.record_planning_command(p_fleet uuid,p_command uuid,p_operation text,p_payload jsonb,p_result jsonb)
returns void language sql security definer set search_path = '' as $$
 insert into private.fleet_planning_commands(fleet_id,command_id,actor_user_id,operation,payload_hash,result)
 values(p_fleet,p_command,auth.uid(),p_operation,extensions.digest(jsonb_build_array(1,p_operation,p_payload)::text,'sha256'),p_result);
$$;
revoke all on function private.record_planning_command(uuid,uuid,text,jsonb,jsonb) from public,anon,authenticated;

create function private.assert_planning_revision(p_id uuid,p_expected bigint,p_actual bigint)
returns void language plpgsql set search_path = '' as $$
begin
 if (p_id is null) <> (p_expected is null) or p_expected<1 then
   perform private.raise_api_error('invalid_input','Creation requires null ID and revision; editing requires both',400);
 end if;
 if p_id is not null and p_actual is null then perform private.raise_api_error('not_found','Configuration not found',404); end if;
 if p_expected is distinct from p_actual then perform private.raise_api_error('revision_conflict','Configuration has changed',409); end if;
end;
$$;
revoke all on function private.assert_planning_revision(uuid,bigint,bigint) from public,anon,authenticated;

create or replace function public.save_van(p_fleet_id uuid,p_van_id uuid,p_plate text,p_model text,p_public_name text,p_capacity integer,p_command_id uuid,p_expected_revision bigint) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
 v_payload jsonb := jsonb_build_object('id',p_van_id,'plate',upper(regexp_replace(coalesce(p_plate,''),'[[:space:]-]+','','g')),
   'model',btrim(p_model),'public_name',btrim(p_public_name),'capacity',p_capacity,'revision',p_expected_revision);
 v_receipt jsonb;
 v_id uuid;
 v_revision bigint;
begin
 v_receipt := private.planning_command_receipt(p_fleet_id,p_command_id,'van',v_payload);
 if v_receipt is not null then return (v_receipt->>'id')::uuid; end if;
 select edit_revision into v_revision from public.vans where id=p_van_id and fleet_id=p_fleet_id;
 perform private.assert_planning_revision(p_van_id,p_expected_revision,v_revision);
 v_id := public.save_van(p_fleet_id,p_van_id,p_plate,p_model,p_public_name,p_capacity);
 select edit_revision into v_revision from public.vans where id=v_id;
 perform private.record_planning_command(p_fleet_id,p_command_id,'van',v_payload,jsonb_build_object('id',v_id,'edit_revision',v_revision));
 return v_id;
end;
$$;
revoke all on function public.save_van(uuid,uuid,text,text,text,integer,uuid,bigint) from public,anon;
grant execute on function public.save_van(uuid,uuid,text,text,text,integer,uuid,bigint) to authenticated;
revoke all on function public.save_van(uuid,uuid,text,text,text,integer) from public,anon;
grant execute on function public.save_van(uuid,uuid,text,text,text,integer) to authenticated;

create function public.save_route(p_fleet_id uuid,p_route_id uuid,p_config jsonb,p_command_id uuid,p_expected_revision bigint) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_payload jsonb := jsonb_build_object('id',p_route_id,'config',p_config,'revision',p_expected_revision);
 v_receipt jsonb; v_id uuid; v_revision bigint; v_normalized jsonb; v_key text; v_point text;
begin
 if jsonb_typeof(p_config) is distinct from 'object' or
   p_config-array['name','direction','shift','van_id','driver_user_id','paired_route_id','proximity_minutes','origin','destination','schools'] <> '{}'::jsonb then
   perform private.raise_api_error('invalid_input','Invalid route command keys',400);
 end if;
 if jsonb_typeof(p_config->'origin') is distinct from 'object' or jsonb_typeof(p_config->'destination') is distinct from 'object' then
   perform private.raise_api_error('invalid_input','Route points are required',400);
 end if;
 if (p_config->'origin')-array['latitude','longitude','label']<>'{}'::jsonb
   or (p_config->'destination')-array['latitude','longitude','label']<>'{}'::jsonb then
   perform private.raise_api_error('invalid_input','Invalid point keys',400);
 end if;
 if jsonb_typeof(p_config->'schools') is distinct from 'array' then
   perform private.raise_api_error('invalid_input','Schools must be an array',400);
 end if;
 if exists(select 1 from jsonb_array_elements(p_config->'schools') school
   where jsonb_typeof(school) is distinct from 'object' or school-array['school_id','position']<>'{}'::jsonb) then
   perform private.raise_api_error('invalid_input','Invalid school keys',400);
 end if;
 -- Match legacy persistence normalization without changing meaningful school order.
 v_normalized := p_config;
 if jsonb_typeof(p_config->'name')='string' then
   v_normalized := jsonb_set(v_normalized,'{name}',to_jsonb(btrim(p_config->>'name')));
 end if;
 if not p_config?'proximity_minutes' then v_normalized := v_normalized||'{"proximity_minutes":10}'::jsonb; end if;
 begin
   foreach v_key in array array['van_id','driver_user_id','paired_route_id'] loop
     if jsonb_typeof(p_config->v_key)='string' or v_key='paired_route_id' then
       v_normalized := jsonb_set(v_normalized,array[v_key],coalesce(to_jsonb(nullif(p_config->>v_key,'')::uuid),'null'::jsonb));
     end if;
   end loop;
   foreach v_point in array array['origin','destination'] loop
     if jsonb_typeof(p_config->v_point->'label')='string' then
       v_normalized := jsonb_set(v_normalized,array[v_point,'label'],to_jsonb(btrim(p_config->v_point->>'label')));
     end if;
     foreach v_key in array array['latitude','longitude'] loop
       if jsonb_typeof(p_config->v_point->v_key)='number' then
         v_normalized := jsonb_set(v_normalized,array[v_point,v_key],to_jsonb(trim_scale((p_config->v_point->>v_key)::numeric)));
       end if;
     end loop;
   end loop;
   v_normalized := jsonb_set(v_normalized,'{schools}',coalesce((select jsonb_agg(
     case when jsonb_typeof(school->'school_id')='string' then jsonb_set(school,'{school_id}',to_jsonb((school->>'school_id')::uuid)) else school end order by ordinal)
     from jsonb_array_elements(p_config->'schools') with ordinality as items(school,ordinal)),'[]'::jsonb));
 exception when invalid_text_representation then
   perform private.raise_api_error('invalid_input','Invalid route reference',400);
 end;
 v_payload := jsonb_build_object('id',p_route_id,'config',v_normalized,'revision',p_expected_revision);
 v_receipt := private.planning_command_receipt(p_fleet_id,p_command_id,'route',v_payload);
 if v_receipt is not null then return (v_receipt->>'id')::uuid; end if;
 select edit_revision into v_revision from public.routes where id=p_route_id and fleet_id=p_fleet_id;
 perform private.assert_planning_revision(p_route_id,p_expected_revision,v_revision);
 v_id := public.save_route(p_fleet_id,p_route_id,p_config);
 select edit_revision into v_revision from public.routes where id=v_id;
 perform private.record_planning_command(p_fleet_id,p_command_id,'route',v_payload,jsonb_build_object('id',v_id,'edit_revision',v_revision));
 return v_id;
end;
$$;
revoke all on function public.save_route(uuid,uuid,jsonb,uuid,bigint) from public,anon;
grant execute on function public.save_route(uuid,uuid,jsonb,uuid,bigint) to authenticated;
revoke all on function public.save_route(uuid,uuid,jsonb) from public,anon;
grant execute on function public.save_route(uuid,uuid,jsonb) to authenticated;

create function public.save_route_schedule(p_route_id uuid,p_schedule_id uuid,p_schedule jsonb,p_command_id uuid,p_expected_revision bigint) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_fleet uuid; v_payload jsonb; v_receipt jsonb; v_id uuid; v_revision bigint;
begin
 perform private.lock_planning();
 select fleet_id into v_fleet from public.routes where id=p_route_id;
 perform private.validate_schedule(p_schedule);
 if p_schedule-array['weekdays','starts_at','ends_at','ends_next_day','timezone','valid_from','valid_until','confirmation_minutes']<>'{}'::jsonb then
   perform private.raise_api_error('invalid_input','Invalid schedule command keys',400);
 end if;
 p_schedule := jsonb_set(p_schedule,'{weekdays}',(select jsonb_agg(value order by value) from jsonb_array_elements(p_schedule->'weekdays')));
 v_payload := jsonb_build_object('route_id',p_route_id,'id',p_schedule_id,'schedule',p_schedule,'revision',p_expected_revision);
 v_receipt := private.planning_command_receipt(v_fleet,p_command_id,'schedule',v_payload);
 if v_receipt is not null then return (v_receipt->>'id')::uuid; end if;
 select edit_revision into v_revision from public.route_schedules where id=p_schedule_id and route_id=p_route_id and fleet_id=v_fleet;
 perform private.assert_planning_revision(p_schedule_id,p_expected_revision,v_revision);
 v_id := public.save_route_schedule(p_route_id,p_schedule_id,p_schedule);
 select edit_revision into v_revision from public.route_schedules where id=v_id;
 perform private.record_planning_command(v_fleet,p_command_id,'schedule',v_payload,jsonb_build_object('id',v_id,'edit_revision',v_revision));
 return v_id;
end;
$$;
revoke all on function public.save_route_schedule(uuid,uuid,jsonb,uuid,bigint) from public,anon;
grant execute on function public.save_route_schedule(uuid,uuid,jsonb,uuid,bigint) to authenticated;
revoke all on function public.save_route_schedule(uuid,uuid,jsonb) from public,anon;
grant execute on function public.save_route_schedule(uuid,uuid,jsonb) to authenticated;

create function public.enable_owner_driving(p_fleet_id uuid,p_command_id uuid) returns text[]
language plpgsql security definer set search_path = '' as $$
declare v_receipt jsonb; v_membership uuid; v_roles text[];
begin
 v_receipt := private.planning_command_receipt(p_fleet_id,p_command_id,'driving','{}');
 if v_receipt is not null then return array(select jsonb_array_elements_text(v_receipt->'roles')); end if;
 select id into v_membership from public.fleet_memberships where fleet_id=p_fleet_id and user_id=auth.uid() and status='active';
 if not private.has_fleet_role(p_fleet_id,auth.uid(),'driver') then
   -- Only manual sources are copied; effective guardian/student roles remain derived.
   select array_agg(role order by role) into v_roles from (
     select role from public.fleet_membership_role_sources where membership_id=v_membership and source_type='manual'
     union select 'driver'
   ) roles;
   perform public.set_fleet_member_roles(v_membership,v_roles);
 end if;
 select array_agg(role order by role) into v_roles from public.fleet_membership_roles where membership_id=v_membership;
 perform private.record_planning_command(p_fleet_id,p_command_id,'driving','{}',jsonb_build_object('roles',v_roles));
 return v_roles;
end;
$$;
revoke all on function public.enable_owner_driving(uuid,uuid) from public,anon;
grant execute on function public.enable_owner_driving(uuid,uuid) to authenticated;
