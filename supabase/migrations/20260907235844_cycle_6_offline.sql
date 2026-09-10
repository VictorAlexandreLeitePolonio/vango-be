-- Online and offline presence share the same transition and event writer.
create function private.apply_passenger_event(
 p_trip_id uuid, p_student_id uuid, p_kind text, p_command_id uuid,
 p_captured_at timestamptz, p_metadata jsonb
) returns bigint language plpgsql security definer set search_path = '' as $$
declare
 v_passenger public.trip_passengers%rowtype;
 v_event_id bigint;
 v_event_kind text := case p_kind when 'boarded' then 'student_boarded'
   when 'dropped_off' then 'student_dropped_off' else 'student_absent' end;
begin
 if p_kind is null or p_kind not in ('boarded','dropped_off','absent') then
   perform private.raise_api_error('invalid_input','Invalid passenger event',400);
 end if;
  if (select status from public.trips where id = p_trip_id) <> 'active' then
    perform private.raise_api_error('invalid_transition', 'Trip is not active', 409);
  end if;
  select * into v_passenger from public.trip_passengers
  where trip_id = p_trip_id and student_id = p_student_id for update;
  if not found or v_passenger.removed_at is not null then
    perform private.raise_api_error('not_found', 'Passenger not found', 404);
  end if;
  if p_kind = 'boarded' and (v_passenger.confirmation_status <> 'confirmed'
    or v_passenger.operation_status <> 'waiting') then
    perform private.raise_api_error('invalid_transition', 'Passenger cannot board', 409);
  elsif p_kind = 'absent' and (v_passenger.confirmation_status <> 'confirmed'
    or v_passenger.operation_status <> 'waiting') then
    perform private.raise_api_error('invalid_transition', 'Passenger cannot be absent', 409);
  elsif p_kind = 'dropped_off' and v_passenger.operation_status <> 'boarded' then
    perform private.raise_api_error('invalid_transition', 'Passenger was not boarded', 409);
  end if;
  update public.trip_passengers set operation_status = p_kind where id = v_passenger.id;
  v_event_id := private.append_trip_event(
    p_trip_id, p_command_id, v_event_kind,
    jsonb_build_object('student_id', p_student_id, 'kind', p_kind) || p_metadata, p_captured_at
  );
  update public.trip_events set result = p_kind where id = v_event_id;
  return v_event_id;
end;
$$;
revoke all on function private.apply_passenger_event(uuid,uuid,text,uuid,timestamptz,jsonb) from public,anon,authenticated;
grant execute on function private.apply_passenger_event(uuid,uuid,text,uuid,timestamptz,jsonb) to postgres,supabase_admin;

create or replace function public.record_passenger_event(
  p_trip_id uuid,
  p_student_id uuid,
  p_kind text,
  p_command_id uuid
) returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_trip public.trips%rowtype;
  v_event public.trip_events%rowtype;
  v_result text;
  v_event_kind text;
begin
  if v_user_id is null then
    perform private.raise_api_error('unauthenticated', 'Authentication required', 401);
  end if;
  if not private.current_user_email_confirmed() then
    perform private.raise_api_error('email_unverified', 'Email confirmation required', 403);
  end if;
  if p_trip_id is null or p_student_id is null or p_kind is null
    or p_kind not in ('boarded', 'dropped_off', 'absent')
    or p_command_id is null then
    perform private.raise_api_error('invalid_input', 'Invalid passenger event', 400);
  end if;
  v_result := p_kind;
  v_event_kind := case p_kind
    when 'boarded' then 'student_boarded'
    when 'dropped_off' then 'student_dropped_off'
    else 'student_absent' end;
  perform private.lock_planning();
  select * into v_trip from public.trips where id = p_trip_id for update;
  if not found then
    perform private.raise_api_error('not_found', 'Trip not found', 404);
  end if;
  if not (private.has_fleet_role(v_trip.fleet_id, v_user_id, 'owner')
    or (v_trip.driver_user_id = v_user_id and private.has_fleet_role(v_trip.fleet_id, v_user_id, 'driver'))) then
    perform private.raise_api_error('not_found', 'Trip not found', 404);
  end if;
  select * into v_event from public.trip_events where trip_id = p_trip_id and command_id = p_command_id;
  if found then
    if v_event.kind <> v_event_kind
      or v_event.actor_user_id is distinct from v_user_id
      or v_event.payload_hash <> extensions.digest(
        jsonb_build_object('student_id', p_student_id, 'kind', p_kind)::text, 'sha256'
      ) then
      perform private.raise_api_error('idempotency_conflict', 'Command payload differs', 409);
    end if;
    return v_event.result;
  end if;
  perform private.apply_passenger_event(p_trip_id,p_student_id,p_kind,p_command_id,clock_timestamp(),'{}'::jsonb);
  return v_result;
end;
$$;

-- Keep client sequence identity on the existing immutable fact ledger.
alter table public.trip_events
 add column offline_assignment_id uuid references public.trip_assignments(id) on delete restrict,
 add column client_sequence bigint,
 add constraint trip_events_offline_sequence_valid check (
   (offline_assignment_id is null and client_sequence is null)
   or (offline_assignment_id is not null and client_sequence is not null and client_sequence > 0)
 );
create unique index trip_events_offline_sequence_key
 on public.trip_events(offline_assignment_id,client_sequence)
 where offline_assignment_id is not null;

create function public.sync_trip_events(p_trip_id uuid,p_assignment_id uuid,p_events jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
 v_user uuid := auth.uid();
 v_trip public.trips%rowtype;
 v_assignment public.trip_assignments%rowtype;
 v_existing public.trip_events%rowtype;
 v_item jsonb;
 v_command uuid;
 v_student uuid;
 v_sequence bigint;
 v_kind text;
 v_captured timestamptz;
 v_now timestamptz;
 v_payload jsonb;
 v_metadata jsonb;
 v_id bigint;
 v_status text;
 v_code text;
 v_results jsonb := '[]'::jsonb;
begin
 if v_user is null then
  perform private.raise_api_error('unauthenticated','Authentication required',401);
 end if;
 if not private.current_user_email_confirmed() then
  perform private.raise_api_error('email_unverified','Email confirmation required',403);
 end if;
 if p_trip_id is null or p_assignment_id is null
   or jsonb_typeof(p_events) is distinct from 'array' then
  perform private.raise_api_error('invalid_input','Trip, assignment and event array required',400);
 end if;
 if jsonb_array_length(p_events) > 100 then
  perform private.raise_api_error('invalid_input','At most 100 events are allowed',400);
 end if;
 perform private.lock_planning();
 select * into v_trip from public.trips where id=p_trip_id for update;
 if not found then
  perform private.raise_api_error('not_found','Trip not found',404);
 end if;
 select * into v_assignment from public.trip_assignments
 where id=p_assignment_id and trip_id=p_trip_id and fleet_id=v_trip.fleet_id;
 -- Recheck current eligibility even for a previously accepted command.
 if not found or v_assignment.driver_user_id is distinct from v_user
   or not private.has_fleet_role(v_trip.fleet_id,v_user,'driver') then
  perform private.raise_api_error('not_found','Assignment not found',404);
 end if;
 v_now := clock_timestamp();
 -- Invalid sequences sort last and are rejected individually without aborting valid items.
 for v_item in select e.value from jsonb_array_elements(p_events) with ordinality e(value,ord)
   order by case when jsonb_typeof(e.value->'sequence')='number'
     and (e.value->>'sequence') ~ '^[0-9]{1,18}$'
     then (e.value->>'sequence')::bigint end nulls last,e.ord
 loop
  v_command:=null; v_id:=null; v_status:='rejected'; v_code:='invalid_input';
  begin
   if jsonb_typeof(v_item) is distinct from 'object'
     or jsonb_typeof(v_item->'command_id') is distinct from 'string'
     or jsonb_typeof(v_item->'student_id') is distinct from 'string'
     or jsonb_typeof(v_item->'captured_at') is distinct from 'string'
     or jsonb_typeof(v_item->'kind') is distinct from 'string'
     or jsonb_typeof(v_item->'sequence') is distinct from 'number'
     or (v_item->>'sequence') !~ '^[0-9]{1,18}$' then
    raise invalid_parameter_value;
   end if;
   v_command := (v_item->>'command_id')::uuid;
   v_student := (v_item->>'student_id')::uuid;
   v_sequence := (v_item->>'sequence')::bigint;
   v_kind := v_item->>'kind';
   v_captured := (v_item->>'captured_at')::timestamptz;
   if v_sequence <= 0 or v_kind not in ('boarded','dropped_off','absent')
     or not isfinite(v_captured)
     or (v_item->>'captured_at') !~ '(Z|[+-][0-9]{2}:[0-9]{2})$' then
    raise invalid_parameter_value;
   end if;
   v_metadata := jsonb_build_object('assignment_id',p_assignment_id,
     'client_sequence',v_sequence,'captured_at',v_captured,'offline',true);
   v_payload := jsonb_build_object('student_id',v_student,'kind',v_kind)||v_metadata;
   select * into v_existing from public.trip_events
   where trip_id=p_trip_id and (command_id=v_command
     or (offline_assignment_id=p_assignment_id and client_sequence=v_sequence))
   order by (command_id=v_command) desc limit 1;
   if found then
    if v_existing.command_id=v_command and v_existing.offline_assignment_id=p_assignment_id
      and v_existing.client_sequence=v_sequence and v_existing.actor_user_id=v_user
      and v_existing.payload_hash=extensions.digest(v_payload::text,'sha256') then
     v_status:='duplicate'; v_code:=null; v_id:=v_existing.id;
    else
     v_status:='conflict'; v_code:='idempotency_conflict';
    end if;
   elsif v_captured > v_now or v_captured < v_now-interval '30 days'
     or v_trip.started_at is null or v_captured < v_trip.started_at
     or (v_trip.ended_at is not null and v_captured > v_trip.ended_at)
     or v_captured < v_assignment.valid_from
     or (v_assignment.valid_until is not null and v_captured >= v_assignment.valid_until) then
    v_code:='invalid_capture_time';
   elsif v_trip.status <> 'active' then
    v_status:='conflict'; v_code:='trip_not_active';
   elsif not exists (select 1 from public.trip_passengers
     where trip_id=p_trip_id and student_id=v_student and removed_at is null
       and confirmation_status='confirmed') then
    v_code:='passenger_not_executable';
   elsif exists (select 1 from public.trip_events e
     where e.trip_id=p_trip_id and e.payload->>'student_id'=v_student::text
       and e.kind in ('student_boarded','student_dropped_off','student_absent')
       and (e.occurred_at > v_captured
         or (e.offline_assignment_id=p_assignment_id and e.client_sequence >= v_sequence))) then
    v_status:='conflict'; v_code:='stale_event';
   else
    -- A savepoint per event preserves valid earlier items if a transition conflicts.
    begin
     v_id:=private.apply_passenger_event(p_trip_id,v_student,v_kind,v_command,v_captured,v_metadata);
     update public.trip_events set offline_assignment_id=p_assignment_id,client_sequence=v_sequence
     where id=v_id;
     v_status:='accepted'; v_code:=null;
    exception when sqlstate 'PGRST' then
     v_status:='conflict'; v_code:='invalid_transition'; v_id:=null;
    end;
   end if;
  exception when invalid_text_representation or invalid_parameter_value
    or datetime_field_overflow or invalid_datetime_format or numeric_value_out_of_range then
   v_status:='rejected'; v_code:='invalid_input'; v_id:=null;
  end;
  v_results:=v_results||jsonb_build_array(jsonb_build_object(
   'command_id',v_command,'status',v_status,'code',v_code,'event_id',v_id));
 end loop;
 return v_results;
end;
$$;
revoke all on function public.sync_trip_events(uuid,uuid,jsonb) from public,anon;
grant execute on function public.sync_trip_events(uuid,uuid,jsonb) to authenticated;
