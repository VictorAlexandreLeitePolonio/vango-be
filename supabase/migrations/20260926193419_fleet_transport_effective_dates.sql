-- Evaluate exact service dates in each schedule's timezone, including removed pairs.
create or replace function private.transport_change_date_is_open(
 p_fleet_id uuid, p_enrollment_id uuid, p_allocations jsonb,
 p_effective_on date, p_now timestamptz
) returns boolean language plpgsql stable security definer set search_path = '' as $$
declare
 v_item jsonb;
 v_schedule public.route_schedules%rowtype;
 v_window record;
 v_old record;
 v_replacement boolean;
begin
 if p_effective_on is null or not isfinite(p_effective_on) or p_now is null
   or not isfinite(p_now) or jsonb_typeof(p_allocations) is distinct from 'array' then
   return false;
 end if;
 if jsonb_array_length(p_allocations)=0 then return false; end if;
 select exists(select 1 from public.route_student_schedules
   where enrollment_id=p_enrollment_id and status='active') into v_replacement;
 for v_item in select value from jsonb_array_elements(p_allocations) loop
   select * into v_schedule from public.route_schedules
   where id=(v_item->>'schedule_id')::uuid and fleet_id=p_fleet_id and status='active';
   if not found or p_effective_on not between v_schedule.valid_from and v_schedule.valid_until
     or p_effective_on < (p_now at time zone v_schedule.timezone)::date
        + (case when v_replacement then 1 else 0 end) then return false; end if;
   select * into v_window from private.schedule_windows(v_schedule.id,p_effective_on,v_schedule.valid_until)
   where extract(isodow from service_date)::integer=(v_item->>'weekday')::integer
   order by service_date limit 1;
   if not found or p_now >= lower(v_window."window")-make_interval(mins=>v_schedule.confirmation_minutes) then
     return false;
   end if;
 end loop;
 for v_old in select rss.* from public.route_student_schedules rss
   where rss.enrollment_id=p_enrollment_id and rss.fleet_id=p_fleet_id
     and rss.status='active' and rss.valid_until>=p_effective_on
 loop
   select * into v_schedule from public.route_schedules where id=v_old.schedule_id;
   if p_effective_on <= (p_now at time zone v_schedule.timezone)::date then return false; end if;
   select * into v_window from private.schedule_windows(v_old.schedule_id,
     greatest(p_effective_on,v_old.valid_from),least(v_old.valid_until,v_schedule.valid_until))
   where extract(isodow from service_date)::integer=v_old.weekday
   order by service_date limit 1;
   if found and p_now >= lower(v_window."window")-make_interval(mins=>v_schedule.confirmation_minutes) then
     return false;
   end if;
 end loop;
 -- Both removed participation and newly selected materialized executions are protected.
 if exists(select 1 from public.trips t where t.fleet_id=p_fleet_id and t.service_date>=p_effective_on
   and (t.status<>'scheduled' or t.started_at is not null or p_now>=t.confirmation_deadline)
   and (exists(select 1 from public.trip_passengers p where p.trip_id=t.id and p.enrollment_id=p_enrollment_id and p.removed_at is null)
     or exists(select 1 from jsonb_array_elements(p_allocations) item
       where (item->>'schedule_id')::uuid=t.schedule_id
         and (item->>'weekday')::integer=extract(isodow from t.service_date)::integer))) then
   return false;
 end if;
 return true;
exception when invalid_text_representation or numeric_value_out_of_range then return false;
end;
$$;
revoke execute on function private.transport_change_date_is_open(uuid,uuid,jsonb,date,timestamptz) from public,anon,authenticated;
grant execute on function private.transport_change_date_is_open(uuid,uuid,jsonb,date,timestamptz) to postgres;

create or replace function private.next_change_date(
  p_request_id uuid,
  p_now timestamptz,
  p_allocations jsonb
) returns date
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_request public.fleet_join_requests%rowtype;
  v_date date;
  v_search_from date;
  v_search_until date;
  v_allocation jsonb;
  v_item jsonb;
  v_schedule public.route_schedules%rowtype;
  v_window record;
  v_old record;
  v_old_window record;
  v_open boolean;
  v_has_service boolean;
begin
  if p_request_id is null or p_now is null
    or p_allocations is null
    or jsonb_typeof(p_allocations) is distinct from 'array' then
    return null;
  end if;
  if exists (
    select 1
    from jsonb_array_elements(p_allocations) item
    where jsonb_typeof(item) is distinct from 'object'
      or jsonb_typeof(item->'schedule_id') is distinct from 'string'
      or item->>'schedule_id' !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      or jsonb_typeof(item->'weekday') is distinct from 'number'
      or item->>'weekday' !~ '^[1-7]$'
  ) then
    return null;
  end if;
  select * into v_request
  from public.fleet_join_requests r
  where r.id = p_request_id;
  if not found or v_request.status not in ('pending', 'waitlisted') then
    return null;
  end if;

  select max(greatest(rs.valid_from, (p_now at time zone rs.timezone)::date + 1)),
         min(rs.valid_until)
  into v_search_from, v_search_until
  from jsonb_array_elements(p_allocations) item
  join public.route_schedules rs
    on rs.id = (item->>'schedule_id')::uuid
   and rs.fleet_id = v_request.fleet_id
   and rs.status = 'active';
  if v_search_from is null or v_search_until is null then
    return null;
  end if;
  if v_search_from > v_search_until then
    return null;
  end if;

  -- Search the complete finite schedule intersection.  A change starts on a
  -- service date of either the new assignments or an old assignment that is
  -- being removed.  Including old weekdays is required when a direction/day
  -- is removed: its already-closed execution can still defer the whole swap.
  for v_date in
    select value::date
    from generate_series(v_search_from, v_search_until, interval '1 day') values(value)
    where extract(isodow from value)::smallint = any(v_request.weekdays)
       or (
         v_request.enrollment_id is not null
         and exists (
           select 1
           from public.route_student_schedules rss
           where rss.enrollment_id = v_request.enrollment_id
             and rss.status = 'active'
             and rss.valid_until >= value::date
             and rss.weekday = extract(isodow from value)::smallint
         )
       )
  loop
    v_allocation := p_allocations;
    v_open := true;
    v_has_service := false;
    for v_item in select value from jsonb_array_elements(v_allocation) loop
      select * into v_schedule
      from public.route_schedules rs
      where rs.id = (v_item->>'schedule_id')::uuid;
      select * into v_window
      from private.schedule_windows(v_schedule.id, v_date, v_schedule.valid_until)
        where extract(isodow from service_date)::smallint = (v_item->>'weekday')::smallint
        order by service_date
        limit 1;
      if not found then
        v_open := false;
        continue;
      end if;
      if v_window.service_date = v_date then
        v_has_service := true;
      end if;
      if p_now >= lower(v_window."window")
        - make_interval(mins => v_schedule.confirmation_minutes) then
        v_open := false;
      end if;
    end loop;
    if not v_open then
      continue;
    end if;

    -- A change also replaces the old recurring assignments.  Their first
    -- execution from the candidate effective date must still be open; this
    -- prevents dropping a direction whose deadline has already closed.
    if v_request.enrollment_id is not null then
      for v_old in
        select rss.schedule_id, rss.weekday, rss.valid_from, rss.valid_until
        from public.route_student_schedules rss
        where rss.enrollment_id = v_request.enrollment_id
          and rss.status = 'active'
          and rss.valid_until >= v_date
      loop
        select rs.* into v_schedule
        from public.route_schedules rs
        where rs.id = v_old.schedule_id;
        select * into v_old_window
        from private.schedule_windows(
          v_old.schedule_id,
          greatest(v_date, v_old.valid_from),
          least(v_old.valid_until, v_schedule.valid_until)
        )
        where extract(isodow from service_date)::smallint = v_old.weekday
          and service_date between v_old.valid_from and v_old.valid_until
        order by service_date
        limit 1;
        if found then
          if v_old_window.service_date = v_date then
            v_has_service := true;
          end if;
          if p_now >= lower(v_old_window."window")
            - make_interval(mins => v_schedule.confirmation_minutes) then
            v_open := false;
            exit;
          end if;
        end if;
      end loop;
    end if;
    if v_has_service and v_open and private.transport_change_date_is_open(
      v_request.fleet_id,v_request.enrollment_id,v_allocation,v_date,p_now) then
      return v_date;
    end if;
  end loop;
  return null;
end;
$$;
