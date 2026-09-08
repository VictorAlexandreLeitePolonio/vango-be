-- ponytail: finite calendar scan under the shared planning lock; replace with
-- candidate boundary dates if fleet volume makes this queue preview expensive.
create function private.request_fully_serviceable(p_request_id uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_request public.fleet_join_requests%rowtype;
  v_from date;
  v_until date;
  v_date date;
  v_change_date date;
  v_allocation jsonb;
begin
  select * into v_request from public.fleet_join_requests where id=p_request_id;
  if not found or v_request.status not in ('pending','waitlisted') then return false; end if;
  select greatest(current_date,min(rs.valid_from)), max(rs.valid_until)
  into v_from,v_until
  from public.routes r
  join public.route_schools school on school.route_id=r.id and school.fleet_id=r.fleet_id
  join public.route_schedules rs on rs.route_id=r.id and rs.fleet_id=r.fleet_id
  where r.fleet_id=v_request.fleet_id and r.status='active' and rs.status='active'
    and school.school_id=v_request.school_id and r.shift=v_request.shift
    and r.direction=any(v_request.directions);
  if v_until is null or v_from>v_until then return false; end if;
  for v_date in select day::date from generate_series(v_from,v_until,interval '1 day') day loop
    v_allocation := private.find_request_allocation(p_request_id,v_date);
    if v_allocation is null then continue; end if;
    if v_request.request_kind='new' then return true; end if;
    v_change_date := private.next_change_date(p_request_id,statement_timestamp(),v_allocation);
    if v_change_date is not null
      and private.find_request_allocation(p_request_id,v_change_date) is not null then return true; end if;
  end loop;
  return false;
end;
$$;
revoke all on function private.request_fully_serviceable(uuid) from public,anon,authenticated;
grant execute on function private.request_fully_serviceable(uuid) to postgres,supabase_admin;

create or replace function public.list_transport_queue(
  p_fleet_id uuid,
  p_limit integer,
  p_offset integer
) returns table(
  request_id uuid,
  request_kind text,
  status text,
  created_at timestamptz,
  fully_serviceable boolean
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
begin
  if v_user_id is null then
    perform private.raise_api_error('unauthenticated', 'Authentication required', 401);
  end if;
  if not private.current_user_email_confirmed() then
    perform private.raise_api_error('email_unverified', 'Email confirmation required', 403);
  end if;
  if p_limit is null or p_limit < 1 or p_limit > 100
    or p_offset is null or p_offset < 0 then
    perform private.raise_api_error('invalid_input', 'Queue pagination is invalid', 400);
  end if;
  if p_fleet_id is null or not private.has_fleet_role(p_fleet_id, v_user_id, 'owner') then
    perform private.raise_api_error('not_found', 'Fleet not found', 404);
  end if;

  return query
  select r.id,
         r.request_kind,
         r.status,
         r.created_at,
         private.request_fully_serviceable(r.id) as fully_serviceable
  from public.fleet_join_requests r
  where r.fleet_id = p_fleet_id
    and r.status in ('pending', 'waitlisted')
  order by r.created_at, r.id
  limit p_limit offset p_offset;
end;
$$;

create or replace function public.set_request_van_preferences(
  p_request_id uuid,
  p_van_ids uuid[]
) returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_request public.fleet_join_requests%rowtype;
  v_van_id uuid;
begin
  if v_user_id is null then
    perform private.raise_api_error('unauthenticated', 'Authentication required', 401);
  end if;
  if not private.current_user_email_confirmed() then
    perform private.raise_api_error('email_unverified', 'Email confirmation required', 403);
  end if;
  if p_request_id is null or p_van_ids is null then
    perform private.raise_api_error('invalid_input', 'Request and preferences are required', 400);
  end if;
  if cardinality(p_van_ids) > 3
    or array_position(p_van_ids, null) is not null
    or cardinality(p_van_ids) <> (
      select count(distinct van_id)::integer from unnest(p_van_ids) as values(van_id)
    ) then
    perform private.raise_api_error('invalid_input', 'At most three distinct vehicles are allowed', 400);
  end if;

  perform private.lock_planning();
  select * into v_request
  from public.fleet_join_requests r
  where r.id = p_request_id
  for update;
  if not found or v_request.requester_user_id <> v_user_id then
    perform private.raise_api_error('not_found', 'Request not found', 404);
  end if;
  if v_request.status not in ('pending', 'waitlisted') then
    perform private.raise_api_error('invalid_transition', 'Request is no longer open', 409);
  end if;

  for v_van_id in select unnest(p_van_ids) loop
    if not exists (
      select 1 from public.vans v
      where v.id = v_van_id and v.fleet_id = v_request.fleet_id and v.status = 'active'
    ) then
      perform private.raise_api_error('not_found', 'Vehicle not found', 404);
    end if;
  end loop;

  delete from public.join_request_van_preferences
  where request_id = v_request.id;
  insert into public.join_request_van_preferences (request_id, fleet_id, van_id, position)
  select v_request.id, v_request.fleet_id, selected.van_id, selected.ordinality::smallint
  from unnest(p_van_ids) with ordinality as selected(van_id, ordinality);

  insert into public.audit_events (
    fleet_id, actor_user_id, action, entity_type, entity_id, metadata
  ) values (
    v_request.fleet_id, v_user_id, 'join_request_changed', 'join_request', v_request.id,
    jsonb_build_object('changed_fields', jsonb_build_array('van_preferences'),
      'preference_count', cardinality(p_van_ids))
  );
end;
$$;

revoke execute on function public.list_transport_queue(uuid, integer, integer) from public, anon;
revoke execute on function public.set_request_van_preferences(uuid, uuid[]) from public, anon;
grant execute on function public.list_transport_queue(uuid, integer, integer) to authenticated;
grant execute on function public.set_request_van_preferences(uuid, uuid[]) to authenticated;
