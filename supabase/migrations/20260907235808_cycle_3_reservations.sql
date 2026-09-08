-- A recurring assignment identifies one enrollment, route schedule, day and direction.
alter table public.fleet_enrollments
  add constraint fleet_enrollments_fleet_id_id_key unique (fleet_id, id);

alter table public.fleet_join_requests
  add constraint fleet_join_requests_fleet_id_id_key unique (fleet_id, id);

alter table public.fleet_join_requests
  drop constraint fleet_join_requests_status_valid;
alter table public.fleet_join_requests
  add constraint fleet_join_requests_status_valid
  check (status in ('pending', 'waitlisted', 'approved', 'rejected', 'cancelled'));
alter table public.fleet_join_requests
  drop constraint fleet_join_requests_decision_dates_valid;
alter table public.fleet_join_requests
  add constraint fleet_join_requests_decision_dates_valid check (
    (status in ('pending', 'waitlisted') and decided_at is null)
    or (status not in ('pending', 'waitlisted') and decided_at is not null)
  );
alter table public.fleet_join_requests
  add column request_kind text not null default 'new';
alter table public.fleet_join_requests
  add column enrollment_id uuid;
alter table public.fleet_join_requests
  add column effective_on date;
alter table public.fleet_join_requests
  add constraint fleet_join_requests_kind_valid
  check (request_kind in ('new', 'change'));
alter table public.fleet_join_requests
  add constraint fleet_join_requests_kind_enrollment_valid
  check ((request_kind = 'new' and (enrollment_id is null or status = 'approved')) or (request_kind = 'change' and enrollment_id is not null));
alter table public.fleet_join_requests
  add constraint fleet_join_requests_enrollment_fleet_fk
  foreign key (fleet_id, enrollment_id)
  references public.fleet_enrollments(fleet_id, id) on delete restrict;

alter table public.fleet_enrollments
  add column school_id uuid references public.schools(id) on delete restrict;
alter table public.fleet_enrollments
  add column shift text;
alter table public.fleet_enrollments
  add column routing_revision bigint not null default 1;

-- Preserve factual Ciclo 2 state before the new planning commands read these
-- fields.  The source request is the only authoritative snapshot for an old
-- enrollment; this does not invent a route, reservation, or allocation.
update public.fleet_enrollments e
set school_id = r.school_id,
    shift = r.shift
from public.fleet_join_requests r
where r.id = e.source_request_id
  and (e.school_id is null or e.shift is null);

update public.fleet_join_requests r
set enrollment_id = e.id,
    effective_on = coalesce(r.effective_on, e.started_at::date)
from public.fleet_enrollments e
where e.source_request_id = r.id
  and r.status = 'approved'
  and r.request_kind = 'new'
  and r.enrollment_id is null;

alter table public.fleet_enrollments
  add constraint fleet_enrollments_shift_valid
  check (shift is null or shift in ('morning', 'afternoon', 'evening', 'full_time'));
alter table public.fleet_enrollments
  add constraint fleet_enrollments_revision_positive
  check (routing_revision > 0);

-- The old index only covered pending requests. Open waitlisted requests share the same queue.
drop index if exists public.fleet_join_requests_pending_student_fleet_key;
create unique index fleet_join_requests_open_student_fleet_key
on public.fleet_join_requests (fleet_id, student_id)
where status in ('pending', 'waitlisted');

create index fleet_join_requests_queue_idx
on public.fleet_join_requests (fleet_id, status, created_at, id);
create index fleet_join_requests_enrollment_idx
on public.fleet_join_requests (enrollment_id, status);

create table public.route_student_schedules (
  id uuid primary key default extensions.gen_random_uuid(),
  fleet_id uuid not null,
  enrollment_id uuid not null,
  route_id uuid not null,
  schedule_id uuid not null,
  weekday smallint not null,
  direction text not null,
  valid_from date not null,
  valid_until date not null,
  status text not null default 'active',
  cancelled_at timestamptz,
  cancellation_reason text,
  created_at timestamptz not null default now(),
  constraint route_student_schedules_fleet_id_id_key unique (fleet_id, id),
  constraint route_student_schedules_enrollment_fleet_fk
    foreign key (fleet_id, enrollment_id)
    references public.fleet_enrollments(fleet_id, id) on delete restrict,
  constraint route_student_schedules_route_fleet_fk
    foreign key (fleet_id, route_id)
    references public.routes(fleet_id, id) on delete restrict,
  constraint route_student_schedules_schedule_fleet_fk
    foreign key (fleet_id, schedule_id)
    references public.route_schedules(fleet_id, id) on delete restrict,
  constraint route_student_schedules_weekday_valid check (weekday between 1 and 7),
  constraint route_student_schedules_direction_valid check (direction in ('going', 'return')),
  constraint route_student_schedules_dates_finite check (isfinite(valid_from) and isfinite(valid_until)),
  constraint route_student_schedules_dates_valid check (valid_until >= valid_from),
  constraint route_student_schedules_status_valid check (status in ('active', 'cancelled')),
  constraint route_student_schedules_cancelled_valid check (
    (status = 'active' and cancelled_at is null and cancellation_reason is null)
    or (status = 'cancelled' and cancelled_at is not null
        and cancellation_reason is not null and btrim(cancellation_reason) <> '')
  )
);

create index route_student_schedules_enrollment_idx
on public.route_student_schedules (enrollment_id, valid_from, valid_until);
create index route_student_schedules_schedule_idx
on public.route_student_schedules (schedule_id, weekday, valid_from, valid_until);
create index route_student_schedules_fleet_idx
on public.route_student_schedules (fleet_id, direction, weekday);

create table public.transport_reservations (
  id uuid primary key default extensions.gen_random_uuid(),
  fleet_id uuid not null,
  enrollment_id uuid not null,
  student_id uuid not null,
  route_student_schedule_id uuid not null,
  route_id uuid not null,
  schedule_id uuid not null,
  van_id uuid not null,
  weekday smallint not null,
  direction text not null,
  valid_from date not null,
  valid_until date not null,
  status text not null default 'active',
  cancelled_at timestamptz,
  cancellation_reason text,
  created_at timestamptz not null default now(),
  constraint transport_reservations_fleet_id_id_key unique (fleet_id, id),
  constraint transport_reservations_enrollment_fleet_fk
    foreign key (fleet_id, enrollment_id)
    references public.fleet_enrollments(fleet_id, id) on delete restrict,
  constraint transport_reservations_student_fk
    foreign key (student_id) references public.students(id) on delete restrict,
  constraint transport_reservations_student_schedule_fleet_fk
    foreign key (fleet_id, route_student_schedule_id)
    references public.route_student_schedules(fleet_id, id) on delete restrict,
  constraint transport_reservations_route_fleet_fk
    foreign key (fleet_id, route_id)
    references public.routes(fleet_id, id) on delete restrict,
  constraint transport_reservations_schedule_fleet_fk
    foreign key (fleet_id, schedule_id)
    references public.route_schedules(fleet_id, id) on delete restrict,
  constraint transport_reservations_van_fleet_fk
    foreign key (fleet_id, van_id)
    references public.vans(fleet_id, id) on delete restrict,
  constraint transport_reservations_weekday_valid check (weekday between 1 and 7),
  constraint transport_reservations_direction_valid check (direction in ('going', 'return')),
  constraint transport_reservations_dates_finite check (isfinite(valid_from) and isfinite(valid_until)),
  constraint transport_reservations_dates_valid check (valid_until >= valid_from),
  constraint transport_reservations_status_valid check (status in ('active', 'cancelled')),
  constraint transport_reservations_cancelled_valid check (
    (status = 'active' and cancelled_at is null and cancellation_reason is null)
    or (status = 'cancelled' and cancelled_at is not null
        and cancellation_reason is not null and btrim(cancellation_reason) <> '')
  )
);

create index transport_reservations_schedule_capacity_idx
on public.transport_reservations (schedule_id, weekday, status, valid_from, valid_until);
create index transport_reservations_student_idx
on public.transport_reservations (student_id, status, valid_from, valid_until);
create index transport_reservations_enrollment_idx
on public.transport_reservations (enrollment_id, status);

-- Replacing route_schools is implemented as delete/insert by save_route. Keep
-- every school referenced by an active or future reservation on that route;
-- callers may still add schools or reorder the retained ones. The enrollment
-- school is the C3 operational school snapshot used by the reservation.
create function private.assert_route_school_change(
  p_route_id uuid,
  p_schools jsonb
) returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_route_id is null or jsonb_typeof(p_schools) is distinct from 'array' then
    perform private.raise_api_error('invalid_input', 'Route schools are invalid', 400);
  end if;
  if exists (
    select 1
    from public.transport_reservations tr
    join public.fleet_enrollments e
      on e.id = tr.enrollment_id and e.fleet_id = tr.fleet_id
    where tr.route_id = p_route_id
      and tr.status = 'active'
      and tr.valid_until >= current_date
      and e.school_id is not null
      and not exists (
        select 1
        from jsonb_array_elements(p_schools) item
        where lower(item->>'school_id') = e.school_id::text
      )
  ) then
    perform private.raise_api_error(
      'resource_in_use',
      'Route has current or future reservations for a removed school',
      409
    );
  end if;
end;
$$;

create table public.join_request_van_preferences (
  request_id uuid not null references public.fleet_join_requests(id) on delete cascade,
  fleet_id uuid not null,
  van_id uuid not null,
  position smallint not null,
  created_at timestamptz not null default now(),
  constraint join_request_van_preferences_pkey primary key (request_id, van_id),
  constraint join_request_van_preferences_request_fleet_fk
    foreign key (fleet_id, request_id)
    references public.fleet_join_requests(fleet_id, id) on delete cascade,
  constraint join_request_van_preferences_van_fleet_fk
    foreign key (fleet_id, van_id)
    references public.vans(fleet_id, id) on delete restrict,
  constraint join_request_van_preferences_position_valid check (position between 1 and 3),
  constraint join_request_van_preferences_position_unique unique (request_id, position)
);

create index join_request_van_preferences_fleet_idx
on public.join_request_van_preferences (fleet_id, request_id, position);

alter table public.route_student_schedules enable row level security;
alter table public.transport_reservations enable row level security;
alter table public.join_request_van_preferences enable row level security;
revoke all on table public.route_student_schedules from anon, authenticated;
revoke all on table public.transport_reservations from anon, authenticated;
revoke all on table public.join_request_van_preferences from anon, authenticated;

-- Resource-defining route and schedule fields cannot change while an
-- execution is reserved.  Display fields remain editable.  To change a
-- resource pattern, the owner uses a future schedule-change allocation (or
-- ends the enrollment), so existing reservations keep their physical van
-- and time window.
create function private.prevent_reserved_route_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if (
    new.fleet_id is distinct from old.fleet_id
    or new.direction is distinct from old.direction
    or new.shift is distinct from old.shift
    or new.paired_route_id is distinct from old.paired_route_id
    or new.van_id is distinct from old.van_id
    or new.driver_user_id is distinct from old.driver_user_id
    or new.status is distinct from old.status
  ) and exists (
    select 1
    from public.transport_reservations tr
    where tr.fleet_id = old.fleet_id
      and tr.route_id = old.id
      and tr.status = 'active'
      and tr.valid_until >= current_date
  ) then
    perform private.raise_api_error(
      'resource_in_use',
      'Route has current or future transport reservations',
      409
    );
  end if;
  return new;
end;
$$;

create function private.prevent_reserved_schedule_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if (
    new.fleet_id is distinct from old.fleet_id
    or new.route_id is distinct from old.route_id
    or new.weekdays is distinct from old.weekdays
    or new.starts_at is distinct from old.starts_at
    or new.ends_at is distinct from old.ends_at
    or new.ends_next_day is distinct from old.ends_next_day
    or new.timezone is distinct from old.timezone
    or new.valid_from is distinct from old.valid_from
    or new.valid_until is distinct from old.valid_until
    or new.confirmation_minutes is distinct from old.confirmation_minutes
    or new.status is distinct from old.status
  ) and exists (
    select 1
    from public.transport_reservations tr
    where tr.fleet_id = old.fleet_id
      and tr.schedule_id = old.id
      and tr.status = 'active'
      and tr.valid_until >= current_date
  ) then
    perform private.raise_api_error(
      'resource_in_use',
      'Schedule has current or future transport reservations',
      409
    );
  end if;
  return new;
end;
$$;

create trigger routes_reserved_change_guard
before update on public.routes
for each row execute function private.prevent_reserved_route_change();

create trigger route_schedules_reserved_change_guard
before update on public.route_schedules
for each row execute function private.prevent_reserved_schedule_change();

revoke execute on function private.prevent_reserved_route_change() from public, anon, authenticated;
revoke execute on function private.prevent_reserved_schedule_change() from public, anon, authenticated;
revoke execute on function private.assert_route_school_change(uuid, jsonb) from public, anon, authenticated;
grant execute on function private.prevent_reserved_route_change() to postgres;
grant execute on function private.prevent_reserved_schedule_change() to postgres;
grant execute on function private.assert_route_school_change(uuid, jsonb) to postgres, supabase_admin;

create function private.request_allocation_candidates(
  p_request_id uuid,
  p_effective_on date
) returns table(
  direction text,
  weekday smallint,
  schedule_id uuid,
  route_id uuid,
  van_id uuid
)
language sql
stable
security definer
set search_path = ''
as $$
  select requested.direction,
         requested_days.weekday,
         rs.id,
         rs.route_id,
         r.van_id
  from public.fleet_join_requests rj
  cross join lateral unnest(rj.directions) as requested(direction)
  cross join lateral unnest(rj.weekdays) as requested_days(weekday)
  join public.routes r
    on r.fleet_id = rj.fleet_id
   and r.direction = requested.direction
   and r.shift = rj.shift
   and r.status = 'active'
  join public.route_schools rsch
    on rsch.fleet_id = r.fleet_id
   and rsch.route_id = r.id
   and rsch.school_id = rj.school_id
  join public.route_schedules rs
    on rs.fleet_id = r.fleet_id
   and rs.route_id = r.id
   and rs.status = 'active'
   and requested_days.weekday = any(rs.weekdays)
   and p_effective_on between rs.valid_from and rs.valid_until
  where rj.id = p_request_id
  order by requested.direction, requested_days.weekday, rs.id
$$;

create or replace function private.reservation_has_capacity(
  p_schedule_id uuid,
  p_weekday smallint,
  p_effective_on date,
  p_capacity integer,
  p_exclude_enrollment_id uuid default null
) returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_candidate record;
  v_candidate_van_id uuid;
  v_reserved integer;
  v_seen boolean := false;
begin
  if p_capacity is null or p_capacity < 1 then
    return false;
  end if;
  select r.van_id into v_candidate_van_id
  from public.route_schedules rs
  join public.routes r on r.id = rs.route_id and r.fleet_id = rs.fleet_id
  where rs.id = p_schedule_id;
  if v_candidate_van_id is null then
    return false;
  end if;

  -- Capacity is per physical execution: every reservation using the same van
  -- must be compared by its real window, including schedules in another route.
  for v_candidate in
    select service_date, "window"
    from private.schedule_windows(p_schedule_id, p_effective_on, null)
    where extract(isodow from service_date)::smallint = p_weekday
  loop
    v_seen := true;
    select count(distinct tr.id)::integer into v_reserved
    from public.transport_reservations tr
    join public.routes existing_route
      on existing_route.id = tr.route_id and existing_route.fleet_id = tr.fleet_id
    join public.route_schedules existing_schedule
      on existing_schedule.id = tr.schedule_id
     and existing_schedule.fleet_id = tr.fleet_id
    join lateral private.schedule_windows(
      existing_schedule.id,
      v_candidate.service_date - 1,
      v_candidate.service_date + 1
    ) existing_window on true
    where existing_route.van_id = v_candidate_van_id
      and tr.status = 'active'
      and tr.valid_from <= v_candidate.service_date + 1
      and tr.valid_until >= v_candidate.service_date - 1
      and existing_window.service_date between tr.valid_from and tr.valid_until
      and extract(isodow from existing_window.service_date)::smallint = tr.weekday
      and existing_window."window" && v_candidate."window"
      and (p_exclude_enrollment_id is null or tr.enrollment_id <> p_exclude_enrollment_id);
    if v_reserved >= p_capacity then
      return false;
    end if;
  end loop;
  return v_seen;
end;
$$;

create or replace function private.student_schedule_conflicts(
  p_student_id uuid,
  p_schedule_id uuid,
  p_weekday smallint,
  p_effective_on date,
  p_exclude_enrollment_id uuid default null
) returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_candidate public.route_schedules%rowtype;
  v_existing record;
  v_from date;
  v_until date;
begin
  select rs.* into v_candidate from public.route_schedules rs where rs.id = p_schedule_id;
  if not found then return true; end if;
  for v_existing in
    select tr.schedule_id, tr.fleet_id, tr.weekday, tr.valid_from, tr.valid_until
    from public.transport_reservations tr
    where tr.student_id = p_student_id
      and tr.status = 'active'
      and tr.valid_until >= p_effective_on - 1
      and (p_exclude_enrollment_id is null or tr.enrollment_id <> p_exclude_enrollment_id)
  loop
    v_from := greatest(p_effective_on, v_existing.valid_from, v_candidate.valid_from) - 1;
    v_until := least(v_existing.valid_until, v_candidate.valid_until) + 1;
    if v_from <= v_until and exists (
      select 1
      from private.schedule_windows(v_candidate.id, v_from, v_until) left_window
      join private.schedule_windows(v_existing.schedule_id, v_from, v_until) right_window
        on left_window."window" && right_window."window"
      where extract(isodow from left_window.service_date)::smallint = p_weekday
        and extract(isodow from right_window.service_date)::smallint = v_existing.weekday
        and left_window.service_date >= p_effective_on
        and left_window.service_date between v_candidate.valid_from and v_candidate.valid_until
        and right_window.service_date between v_existing.valid_from and v_existing.valid_until
    ) then
      return true;
    end if;
  end loop;
  return false;
end;
$$;

create function private.allocation_set_conflicts(
  p_selected jsonb,
  p_schedule_id uuid,
  p_weekday smallint,
  p_effective_on date
) returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_selected jsonb;
  v_other_schedule public.route_schedules%rowtype;
  v_candidate public.route_schedules%rowtype;
  v_other_weekday smallint;
  v_from date;
  v_until date;
begin
  if p_selected is null or jsonb_typeof(p_selected) <> 'array' then return true; end if;
  select * into v_candidate from public.route_schedules where id = p_schedule_id;
  if not found then return true; end if;
  for v_selected in select value from jsonb_array_elements(p_selected) loop
    begin
      v_other_weekday := (v_selected->>'weekday')::smallint;
    exception when others then
      return true;
    end;
    select * into v_other_schedule from public.route_schedules
    where id = (v_selected->>'schedule_id')::uuid;
    if not found then return true; end if;
    v_from := greatest(p_effective_on, v_candidate.valid_from, v_other_schedule.valid_from) - 1;
    v_until := least(v_candidate.valid_until, v_other_schedule.valid_until) + 1;
    if v_from <= v_until and exists (
      select 1
      from private.schedule_windows(v_candidate.id, v_from, v_until) left_window
      join private.schedule_windows(v_other_schedule.id, v_from, v_until) right_window
        on left_window."window" && right_window."window"
      where extract(isodow from left_window.service_date)::smallint = p_weekday
        and extract(isodow from right_window.service_date)::smallint = v_other_weekday
        and left_window.service_date >= p_effective_on
        and left_window.service_date between v_candidate.valid_from and v_candidate.valid_until
        and right_window.service_date between v_other_schedule.valid_from and v_other_schedule.valid_until
    ) then
      return true;
    end if;
  end loop;
  return false;
end;
$$;

create function private.find_request_allocation_step(
  p_request_id uuid,
  p_effective_on date,
  p_remaining jsonb,
  p_selected jsonb,
  p_exclude_enrollment_id uuid default null
) returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_need jsonb;
  v_candidate record;
  v_result jsonb;
  v_next jsonb;
begin
  if jsonb_array_length(p_remaining) = 0 then
    return p_selected;
  end if;
  v_need := p_remaining->0;
  for v_candidate in
    select c.*, v.capacity
    from private.request_allocation_candidates(p_request_id, p_effective_on) c
    join public.vans v on v.id = c.van_id
    where c.direction = v_need->>'direction'
      and c.weekday = (v_need->>'weekday')::smallint
      and v.status = 'active'
    order by c.schedule_id
  loop
    if private.reservation_has_capacity(
      v_candidate.schedule_id, v_candidate.weekday, p_effective_on,
      v_candidate.capacity, p_exclude_enrollment_id
    ) and not private.student_schedule_conflicts(
      (select student_id from public.fleet_join_requests where id = p_request_id),
      v_candidate.schedule_id, v_candidate.weekday,
      p_effective_on, p_exclude_enrollment_id
    ) and not private.allocation_set_conflicts(
      p_selected, v_candidate.schedule_id, v_candidate.weekday,
      p_effective_on
    ) then
      v_next := p_selected || jsonb_build_array(jsonb_build_object(
        'schedule_id', v_candidate.schedule_id,
        'weekday', v_candidate.weekday,
        'direction', v_candidate.direction
      ));
      v_result := private.find_request_allocation_step(
        p_request_id, p_effective_on, p_remaining - 0, v_next,
        p_exclude_enrollment_id
      );
      if v_result is not null then return v_result; end if;
    end if;
  end loop;
  return null;
end;
$$;

create or replace function private.find_request_allocation(
  p_request_id uuid,
  p_effective_on date
) returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_request public.fleet_join_requests%rowtype;
  v_remaining jsonb;
  v_selected jsonb;
  v_result jsonb;
begin
  if p_request_id is null or p_effective_on is null or not isfinite(p_effective_on) then
    return null;
  end if;
  select * into v_request from public.fleet_join_requests where id = p_request_id;
  if not found or v_request.status not in ('pending', 'waitlisted') then return null; end if;
  select jsonb_agg(jsonb_build_object('direction', d.direction, 'weekday', w.weekday) order by d.direction, w.weekday)
  into v_remaining
  from unnest(v_request.directions) d(direction)
  cross join unnest(v_request.weekdays) w(weekday);
  v_selected := private.find_request_allocation_step(
    p_request_id, p_effective_on, coalesce(v_remaining, '[]'::jsonb), '[]'::jsonb,
    v_request.enrollment_id
  );
  if v_selected is null then return null; end if;
  select jsonb_agg(
    jsonb_build_object('schedule_id', item.value->>'schedule_id', 'weekday', (item.value->>'weekday')::integer)
    order by item.ordinality
  ) into v_result
  from jsonb_array_elements(v_selected) with ordinality item(value, ordinality);
  return v_result;
end;
$$;

create or replace function private.apply_request_allocation(
  p_request_id uuid,
  p_allocations jsonb,
  p_effective_on date
) returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_request public.fleet_join_requests%rowtype;
  v_student public.students%rowtype;
  v_alloc jsonb;
  v_schedule public.route_schedules%rowtype;
  v_route public.routes%rowtype;
  v_van public.vans%rowtype;
  v_enrollment_id uuid;
  v_rss_id uuid;
  v_schedule_id uuid;
  v_weekday smallint;
  v_direction text;
  v_expected integer;
  v_seen integer := 0;
  v_selected jsonb := '[]'::jsonb;
  v_guardian record;
  v_constraint text;
begin
  if p_allocations is null or jsonb_typeof(p_allocations) is distinct from 'array'
    or p_effective_on is null or not isfinite(p_effective_on) then
    perform private.raise_api_error('invalid_input', 'Complete allocation and effective date are required', 400);
  end if;
  select * into v_request from public.fleet_join_requests
  where id = p_request_id for update;
  if not found then perform private.raise_api_error('not_found', 'Request not found', 404); end if;
  if v_request.status not in ('pending', 'waitlisted') then
    perform private.raise_api_error('invalid_transition', 'Request is no longer open', 409);
  end if;
  if p_effective_on < current_date then
    perform private.raise_api_error('invalid_input', 'Effective date cannot be in the past', 400);
  end if;
  if v_request.request_kind = 'new' and v_request.enrollment_id is not null then
    perform private.raise_api_error('invalid_input', 'Initial request cannot reference enrollment', 400);
  end if;

  v_expected := cardinality(v_request.directions) * cardinality(v_request.weekdays);
  if jsonb_array_length(p_allocations) <> v_expected then
    perform private.raise_api_error('allocation_required', 'Every requested day and direction needs an allocation', 409);
  end if;
  select * into v_student from public.students s where s.id = v_request.student_id for update;
  if not found then perform private.raise_api_error('not_found', 'Student not found', 404); end if;

  for v_alloc in select value from jsonb_array_elements(p_allocations) loop
    if jsonb_typeof(v_alloc) is distinct from 'object'
      or jsonb_typeof(v_alloc->'schedule_id') is distinct from 'string'
      or jsonb_typeof(v_alloc->'weekday') is distinct from 'number' then
      perform private.raise_api_error('invalid_input', 'Invalid allocation item', 400);
    end if;
    begin
      v_schedule_id := (v_alloc->>'schedule_id')::uuid;
      v_weekday := (v_alloc->>'weekday')::smallint;
    exception when others then
      perform private.raise_api_error('invalid_input', 'Invalid allocation item', 400);
    end;
    if v_schedule_id is null or v_weekday is null
      or v_weekday not between 1 and 7
      or ((v_alloc ? 'direction') and v_alloc->>'direction' is null) then
      perform private.raise_api_error('invalid_input', 'Invalid allocation item', 400);
    end if;
    select rs.* into v_schedule
    from public.route_schedules rs
    where rs.id = v_schedule_id and rs.fleet_id = v_request.fleet_id
      and rs.status = 'active' and v_weekday = any(rs.weekdays)
      and p_effective_on between rs.valid_from and rs.valid_until
    for update;
    if not found then perform private.raise_api_error('invalid_input', 'Allocation schedule is not available', 400); end if;
    select r.* into v_route
    from public.routes r
    join public.route_schools rsch on rsch.route_id = r.id and rsch.fleet_id = r.fleet_id
    where r.id = v_schedule.route_id and r.fleet_id = v_request.fleet_id
      and r.shift = v_request.shift and r.status = 'active'
      and rsch.school_id = v_request.school_id;
    if not found then perform private.raise_api_error('invalid_input', 'Allocation route does not meet request', 400); end if;
    v_direction := v_route.direction;
    if (v_alloc ? 'direction') and v_alloc->>'direction' is distinct from v_direction then
      perform private.raise_api_error('invalid_input', 'Allocation direction does not match route', 400);
    end if;
    if not exists (
      select 1 from unnest(v_request.directions) requested(direction)
      where requested.direction = v_direction
    ) then
      perform private.raise_api_error('invalid_input', 'Allocation direction was not requested', 400);
    end if;
    if exists (
      select 1 from jsonb_array_elements(v_selected) chosen(value)
      where chosen.value->>'direction' = v_direction
        and (chosen.value->>'weekday')::smallint = v_weekday
    ) then
      perform private.raise_api_error('invalid_input', 'Each requested direction and weekday must be allocated once', 400);
    end if;
    if not exists (
      select 1 from unnest(v_request.weekdays) requested(weekday)
      where requested.weekday = v_weekday
    ) then
      perform private.raise_api_error('invalid_input', 'Allocation weekday was not requested', 400);
    end if;
    select * into v_van from public.vans v
    where v.id = v_route.van_id and v.fleet_id = v_request.fleet_id and v.status = 'active'
    for update;
    if not found then perform private.raise_api_error('not_found', 'Vehicle not found', 404); end if;
    if not private.reservation_has_capacity(
      v_schedule.id, v_weekday, p_effective_on, v_van.capacity, v_request.enrollment_id
    ) then
      perform private.raise_api_error('capacity_exceeded', 'No seats remain for the requested execution', 409);
    end if;
    if private.student_schedule_conflicts(
      v_request.student_id, v_schedule.id, v_weekday,
      p_effective_on, v_request.enrollment_id
    ) then
      perform private.raise_api_error('schedule_conflict', 'Student has a conflicting reservation', 409);
    end if;
    if private.allocation_set_conflicts(
      v_selected, v_schedule.id, v_weekday, p_effective_on
    ) then
      perform private.raise_api_error('schedule_conflict', 'Allocations conflict with each other', 409);
    end if;
    v_selected := v_selected || jsonb_build_array(jsonb_build_object(
      'schedule_id', v_schedule.id, 'weekday', v_weekday, 'direction', v_direction
    ));
    v_seen := v_seen + 1;
  end loop;
  if v_seen <> v_expected then
    perform private.raise_api_error('allocation_required', 'Every requested day and direction needs an allocation', 409);
  end if;

  if v_request.request_kind = 'new' then
    if exists (
      select 1 from public.fleet_enrollments e
      where e.fleet_id = v_request.fleet_id and e.student_id = v_request.student_id and e.status = 'active'
    ) then
      perform private.raise_api_error('enrollment_conflict', 'Student is already enrolled in this fleet', 409);
    end if;
    insert into public.fleet_enrollments (
      fleet_id, student_id, source_request_id, school_id, shift
    ) values (
      v_request.fleet_id, v_request.student_id, v_request.id, v_request.school_id, v_request.shift
    ) returning id into v_enrollment_id;
    if v_student.student_type = 'adult' then
      perform private.ensure_enrollment_membership(
        v_request.fleet_id, v_student.profile_id, 'student', v_enrollment_id
      );
    else
      for v_guardian in
        select sg.guardian_user_id
        from public.student_guardians sg
        where sg.student_id = v_student.id and sg.status = 'active'
        order by sg.guardian_user_id
      loop
        perform private.ensure_enrollment_membership(
          v_request.fleet_id, v_guardian.guardian_user_id, 'guardian', v_enrollment_id
        );
      end loop;
    end if;
  else
    v_enrollment_id := v_request.enrollment_id;
    if v_enrollment_id is null then
      perform private.raise_api_error('invalid_input', 'Change request requires an enrollment', 400);
    end if;
    perform 1
    from public.fleet_enrollments e
    where e.id = v_enrollment_id and e.fleet_id = v_request.fleet_id and e.status = 'active'
    for update;
    if not found then perform private.raise_api_error('not_found', 'Enrollment not found', 404); end if;
    update public.route_student_schedules
    set valid_until = p_effective_on - 1
    where enrollment_id = v_enrollment_id and status = 'active'
      and valid_from < p_effective_on and valid_until >= p_effective_on;
    update public.route_student_schedules
    set status = 'cancelled', cancelled_at = clock_timestamp(),
        cancellation_reason = 'superseded by approved schedule change'
    where enrollment_id = v_enrollment_id and status = 'active'
      and valid_from >= p_effective_on;
    update public.transport_reservations
    set valid_until = p_effective_on - 1
    where enrollment_id = v_enrollment_id and status = 'active'
      and valid_from < p_effective_on and valid_until >= p_effective_on;
    update public.transport_reservations
    set status = 'cancelled', cancelled_at = clock_timestamp(),
        cancellation_reason = 'superseded by approved schedule change'
    where enrollment_id = v_enrollment_id and status = 'active' and valid_from >= p_effective_on;
  end if;

  for v_alloc in select value from jsonb_array_elements(v_selected) loop
    v_schedule_id := (v_alloc->>'schedule_id')::uuid;
    v_weekday := (v_alloc->>'weekday')::smallint;
    v_direction := v_alloc->>'direction';
    select rs.* into v_schedule from public.route_schedules rs
    where rs.id = v_schedule_id and rs.fleet_id = v_request.fleet_id;
    select r.* into v_route from public.routes r
    where r.id = v_schedule.route_id and r.fleet_id = v_request.fleet_id;
    insert into public.route_student_schedules (
      fleet_id, enrollment_id, route_id, schedule_id, weekday, direction, valid_from, valid_until
    ) values (
      v_request.fleet_id, v_enrollment_id, v_route.id, v_schedule.id, v_weekday,
      v_direction, p_effective_on, v_schedule.valid_until
    ) returning id into v_rss_id;
    insert into public.transport_reservations (
      fleet_id, enrollment_id, student_id, route_student_schedule_id, route_id,
      schedule_id, van_id, weekday, direction, valid_from, valid_until
    ) values (
      v_request.fleet_id, v_enrollment_id, v_request.student_id, v_rss_id, v_route.id,
      v_schedule.id, v_route.van_id, v_weekday, v_direction, p_effective_on, v_schedule.valid_until
    );
  end loop;

  update public.fleet_join_requests
  set status = 'approved', enrollment_id = v_enrollment_id, effective_on = p_effective_on,
      decided_by = auth.uid(), decided_at = clock_timestamp()
  where id = p_request_id;
  insert into public.audit_events (
    fleet_id, actor_user_id, action, entity_type, entity_id, metadata
  ) values (
    v_request.fleet_id, auth.uid(), 'join_request_approved', 'join_request', p_request_id,
    jsonb_build_object('enrollment_id', v_enrollment_id, 'allocation_count', v_expected,
      'effective_on', p_effective_on)
  );
  return v_enrollment_id;
exception
  when unique_violation then
    get stacked diagnostics v_constraint = constraint_name;
    if v_constraint in ('fleet_enrollments_active_student_fleet_key',
      'fleet_enrollments_source_request_unique', 'route_student_schedules_fleet_id_id_key') then
      perform private.raise_api_error('enrollment_conflict', 'Student already has an active enrollment', 409);
    end if;
    raise;
end;
$$;

create function private.van_capacity_is_sufficient(
  p_van_id uuid,
  p_capacity integer
) returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_schedule record;
  v_candidate record;
  v_reserved integer;
begin
  if p_capacity is null or p_capacity < 1 then return false; end if;
  for v_schedule in
    select rs.id
    from public.route_schedules rs
    join public.routes r on r.id = rs.route_id and r.fleet_id = rs.fleet_id
    where r.van_id = p_van_id and r.status = 'active' and rs.status = 'active'
  loop
    for v_candidate in
      select service_date, "window"
      from private.schedule_windows(v_schedule.id, null, null)
    loop
      select count(distinct tr.id)::integer into v_reserved
      from public.transport_reservations tr
      join public.routes existing_route
        on existing_route.id = tr.route_id and existing_route.fleet_id = tr.fleet_id
      join public.route_schedules existing_schedule
        on existing_schedule.id = tr.schedule_id
       and existing_schedule.fleet_id = tr.fleet_id
      join lateral private.schedule_windows(
        existing_schedule.id,
        v_candidate.service_date - 1,
        v_candidate.service_date + 1
      ) existing_window on true
      where existing_route.van_id = p_van_id
        and tr.status = 'active'
        and tr.valid_from <= v_candidate.service_date + 1
        and tr.valid_until >= v_candidate.service_date - 1
        and existing_window.service_date between tr.valid_from and tr.valid_until
        and extract(isodow from existing_window.service_date)::smallint = tr.weekday
        and existing_window."window" && v_candidate."window";
      if v_reserved > p_capacity then return false; end if;
    end loop;
  end loop;
  return true;
end;
$$;

revoke execute on function private.van_capacity_is_sufficient(uuid, integer) from public, anon, authenticated;
grant execute on function private.van_capacity_is_sufficient(uuid, integer) to postgres;

create or replace function public.save_van(
  p_fleet_id uuid,
  p_van_id uuid,
  p_plate text,
  p_model text,
  p_public_name text,
  p_capacity integer
) returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_van public.vans%rowtype;
  v_plate text := upper(regexp_replace(coalesce(p_plate, ''), '[[:space:]-]+', '', 'g'));
  v_id uuid;
  v_action text;
  v_constraint text;
begin
  if v_user_id is null then
    perform private.raise_api_error('unauthenticated', 'Authentication required', 401);
  end if;
  if not private.current_user_email_confirmed() then
    perform private.raise_api_error('email_unverified', 'Email confirmation required', 403);
  end if;
  if v_plate !~ '^[A-Z]{3}[0-9]{4}$' and v_plate !~ '^[A-Z]{3}[0-9][A-Z][0-9]{2}$'
    or p_model is null or btrim(p_model) = ''
    or p_public_name is null or btrim(p_public_name) = ''
    or p_capacity is null or p_capacity < 1 or p_capacity > 100 then
    perform private.raise_api_error('invalid_input', 'Invalid vehicle fields', 400);
  end if;
  perform private.lock_planning();
  if p_fleet_id is null or not private.has_fleet_role(p_fleet_id, v_user_id, 'owner') then
    perform private.raise_api_error('not_found', 'Fleet not found', 404);
  end if;
  perform 1 from public.fleets where id = p_fleet_id for update;
  if p_van_id is null then
    insert into public.vans (fleet_id, plate, model, public_name, capacity)
    values (p_fleet_id, v_plate, btrim(p_model), btrim(p_public_name), p_capacity)
    returning id into v_id;
    v_action := 'van_created';
  else
    select * into v_van from public.vans where id = p_van_id and fleet_id = p_fleet_id for update;
    if not found then
      perform private.raise_api_error('not_found', 'Vehicle not found', 404);
    end if;
    if p_capacity < v_van.capacity
      and not private.van_capacity_is_sufficient(p_van_id, p_capacity) then
      perform private.raise_api_error('capacity_exceeded', 'Vehicle capacity cannot break active reservations', 409);
    end if;
    update public.vans
    set plate = v_plate, model = btrim(p_model), public_name = btrim(p_public_name), capacity = p_capacity
    where id = p_van_id;
    v_id := p_van_id;
    v_action := 'van_updated';
  end if;
  insert into public.audit_events (fleet_id, actor_user_id, action, entity_type, entity_id, metadata)
  values (p_fleet_id, v_user_id, v_action, 'van', v_id,
    jsonb_build_object('changed_fields', jsonb_build_array('plate', 'model', 'public_name', 'capacity')));
  return v_id;
exception
  when unique_violation then
    get stacked diagnostics v_constraint = constraint_name;
    if v_constraint = 'vans_active_plate_key' then
      perform private.raise_api_error('plate_conflict', 'Vehicle plate is already in use', 409);
    end if;
    raise;
end;
$$;

create or replace function public.submit_fleet_join_request(
  p_fleet_id uuid,
  p_student_id uuid,
  p_school_id uuid,
  p_shift text,
  p_directions text[],
  p_weekdays smallint[]
) returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_student public.students%rowtype;
  v_school public.schools%rowtype;
  v_request_id uuid;
  v_directions text[];
  v_weekdays smallint[];
  v_fleet_status text;
  v_constraint text;
begin
  if v_user_id is null then
    perform private.raise_api_error('unauthenticated', 'Authentication required', 401);
  end if;
  if not private.current_user_email_confirmed() then
    perform private.raise_api_error('email_unverified', 'Email confirmation required', 403);
  end if;
  perform private.validate_request_preferences(p_shift, p_directions, p_weekdays);
  perform private.lock_planning();
  select f.status into v_fleet_status from public.fleets f where f.id = p_fleet_id for update;
  if not found or v_fleet_status <> 'published' then
    perform private.raise_api_error('not_found', 'Fleet not found', 404);
  end if;
  select * into v_student from public.students s where s.id = p_student_id for update;
  if not found then
    perform private.raise_api_error('not_found', 'Student not found', 404);
  end if;
  if not private.can_manage_student(p_student_id, v_user_id) then
    perform private.raise_api_error('forbidden', 'Student management permission required', 403);
  end if;
  select * into v_school from public.schools s where s.id = p_school_id for update;
  if not found or v_school.status <> 'active' then
    perform private.raise_api_error('not_found', 'School not found', 404);
  end if;
  if not exists (
    select 1 from public.fleet_service_schools fss
    where fss.fleet_id = p_fleet_id and fss.school_id = p_school_id
  ) or not exists (
    select 1 from public.fleet_service_cities fsc
    where fsc.fleet_id = p_fleet_id and fsc.city_ibge_code = v_student.city_ibge_code
  ) then
    perform private.raise_api_error('invalid_input', 'Fleet does not cover the school and student city', 400);
  end if;
  if exists (select 1 from public.fleet_enrollments e where e.fleet_id = p_fleet_id and e.student_id = p_student_id and e.status = 'active') then
    perform private.raise_api_error('enrollment_conflict', 'Student is already enrolled in this fleet', 409);
  end if;
  select array_agg(direction order by direction) into v_directions
  from (select distinct direction from unnest(p_directions) direction) directions;
  select array_agg(day_value order by day_value) into v_weekdays
  from (select distinct day_value from unnest(p_weekdays) day_value) weekdays;
  insert into public.fleet_join_requests (
    fleet_id, requester_user_id, student_id, school_id, origin, shift, directions, weekdays,
    postal_code, street, street_number, address_complement, neighborhood, city_name,
    city_ibge_code, state_code, latitude, longitude, request_kind
  ) values (
    p_fleet_id, v_user_id, p_student_id, p_school_id, 'marketplace', p_shift, v_directions, v_weekdays,
    v_student.postal_code, v_student.street, v_student.street_number, v_student.address_complement,
    v_student.neighborhood, v_student.city_name, v_student.city_ibge_code, v_student.state_code,
    v_student.latitude, v_student.longitude, 'new'
  ) returning id into v_request_id;
  insert into public.audit_events (fleet_id, actor_user_id, action, entity_type, entity_id, metadata)
  values (p_fleet_id, v_user_id, 'join_request_created', 'join_request', v_request_id,
    jsonb_build_object('student_id', p_student_id, 'school_id', p_school_id, 'request_kind', 'new'));
  return v_request_id;
exception
  when unique_violation then
    get stacked diagnostics v_constraint = constraint_name;
    if v_constraint = 'fleet_join_requests_open_student_fleet_key' then
      perform private.raise_api_error('request_conflict', 'An open request already exists', 409);
    end if;
    raise;
end;
$$;

create or replace function public.approve_transport_request(
  p_request_id uuid,
  p_allocations jsonb,
  p_effective_on date
) returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_request public.fleet_join_requests%rowtype;
  v_previous public.fleet_join_requests%rowtype;
  v_next_change date;
begin
  if v_user_id is null then
    perform private.raise_api_error('unauthenticated', 'Authentication required', 401);
  end if;
  if not private.current_user_email_confirmed() then
    perform private.raise_api_error('email_unverified', 'Email confirmation required', 403);
  end if;
  perform private.lock_planning();
  select * into v_request from public.fleet_join_requests where id = p_request_id for update;
  if not found or not private.has_fleet_role(v_request.fleet_id, v_user_id, 'owner') then
    perform private.raise_api_error('not_found', 'Request not found', 404);
  end if;
  if v_request.status not in ('pending', 'waitlisted') then
    perform private.raise_api_error('invalid_transition', 'Request is no longer open', 409);
  end if;
  if v_request.request_kind = 'change' then
    -- The effective date is part of the approval contract.  Derive it from
    -- every affected old and new execution so callers cannot bypass a closed
    -- confirmation deadline by supplying an arbitrary future date.
    v_next_change := private.next_change_date(
      p_request_id, clock_timestamp(), p_allocations
    );
    if v_next_change is null or p_effective_on is distinct from v_next_change then
      perform private.raise_api_error(
        'invalid_input',
        'Effective date must equal the next available change date',
        400
      );
    end if;
  end if;
  for v_previous in
    select r.* from public.fleet_join_requests r
    where r.fleet_id = v_request.fleet_id
      and r.status in ('pending', 'waitlisted')
      and (r.created_at, r.id) < (v_request.created_at, v_request.id)
    order by r.created_at, r.id
    for update
  loop
    if private.request_fully_serviceable(v_previous.id) then
      perform private.raise_api_error('queue_priority', 'An older compatible request must be decided first', 409);
    end if;
  end loop;
  return private.apply_request_allocation(p_request_id, p_allocations, p_effective_on);
end;
$$;

create function public.set_transport_request_status(
  p_request_id uuid,
  p_status text,
  p_reason text
) returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_request public.fleet_join_requests%rowtype;
begin
  if v_user_id is null then
    perform private.raise_api_error('unauthenticated', 'Authentication required', 401);
  end if;
  if not private.current_user_email_confirmed() then
    perform private.raise_api_error('email_unverified', 'Email confirmation required', 403);
  end if;
  if p_status is null or p_status not in ('waitlisted', 'rejected') then
    perform private.raise_api_error('invalid_status', 'Only waitlisted or rejected are accepted', 400);
  end if;
  if p_status = 'rejected' and (p_reason is null or btrim(p_reason) = '') then
    perform private.raise_api_error('invalid_input', 'A reason is required to reject a request', 400);
  end if;
  perform private.lock_planning();
  select * into v_request from public.fleet_join_requests r where r.id = p_request_id for update;
  if not found or not private.has_fleet_role(v_request.fleet_id, v_user_id, 'owner') then
    perform private.raise_api_error('not_found', 'Request not found', 404);
  end if;
  if v_request.status not in ('pending', 'waitlisted') then
    perform private.raise_api_error('invalid_transition', 'Request is no longer open', 409);
  end if;
  if p_status = 'waitlisted' then
    update public.fleet_join_requests
    set status = 'waitlisted'
    where id = p_request_id;
    insert into public.audit_events (fleet_id, actor_user_id, action, entity_type, entity_id, metadata)
    values (v_request.fleet_id, v_user_id, 'join_request_waitlisted', 'join_request', p_request_id,
      jsonb_build_object('reason_recorded', p_reason is not null and btrim(p_reason) <> ''));
  else
    update public.fleet_join_requests
    set status = 'rejected', decided_by = v_user_id, decided_at = clock_timestamp()
    where id = p_request_id;
    insert into public.audit_events (fleet_id, actor_user_id, action, entity_type, entity_id, metadata)
    values (v_request.fleet_id, v_user_id, 'join_request_rejected', 'join_request', p_request_id,
      jsonb_build_object('reason_recorded', true));
  end if;
  return p_status;
end;
$$;

create or replace function public.decide_fleet_join_request(
  p_request_id uuid,
  p_decision text
) returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_fleet_id uuid;
begin
  if v_user_id is null then
    perform private.raise_api_error('unauthenticated', 'Authentication required', 401);
  end if;
  if not private.current_user_email_confirmed() then
    perform private.raise_api_error('email_unverified', 'Email confirmation required', 403);
  end if;
  perform private.lock_planning();
  select fleet_id into v_fleet_id from public.fleet_join_requests where id = p_request_id for update;
  if not found or not private.has_fleet_role(v_fleet_id, v_user_id, 'owner') then
    perform private.raise_api_error('not_found', 'Request not found', 404);
  end if;
  if p_decision = 'approved' then
    perform private.raise_api_error('allocation_required', 'Approval requires complete allocations', 409);
  elsif p_decision = 'rejected' then
    return public.set_transport_request_status(p_request_id, 'rejected', 'rejected by owner');
  else
    perform private.raise_api_error('invalid_input', 'Decision must be approved or rejected', 400);
  end if;
end;
$$;

create or replace function public.accept_fleet_invitation(
  p_token text,
  p_student_id uuid,
  p_school_id uuid,
  p_shift text,
  p_directions text[],
  p_weekdays smallint[]
) returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_invitation public.fleet_invitations%rowtype;
  v_fleet_status text;
  v_student public.students%rowtype;
  v_school public.schools%rowtype;
  v_request_id uuid;
  v_guardian_exists boolean;
begin
  if v_user_id is null then
    perform private.raise_api_error('unauthenticated', 'Authentication required', 401);
  end if;
  if not private.current_user_email_confirmed() then
    perform private.raise_api_error('email_unverified', 'Email confirmation required', 403);
  end if;
  perform private.validate_request_preferences(p_shift, p_directions, p_weekdays);
  if p_token is null or btrim(p_token) = '' then
    perform private.raise_api_error('not_found', 'Invitation not found', 404);
  end if;
  perform private.lock_planning();
  select * into v_invitation from public.fleet_invitations i
  where i.token_hash = extensions.digest(p_token, 'sha256') for update;
  if not found then
    perform private.raise_api_error('not_found', 'Invitation not found', 404);
  end if;
  if v_invitation.status <> 'pending' then
    if v_invitation.status = 'expired' then return null; end if;
    perform private.raise_api_error('invalid_transition', 'Invitation is no longer pending', 409);
  end if;
  if clock_timestamp() > v_invitation.expires_at then
    update public.fleet_invitations set status = 'expired', responded_by = v_user_id, responded_at = clock_timestamp() where id = v_invitation.id;
    return null;
  end if;
  if private.current_user_email() is distinct from v_invitation.email then
    perform private.raise_api_error('invitation_email_mismatch', 'Authenticated email does not match invitation', 403);
  end if;
  if v_invitation.role not in ('guardian', 'student') then
    perform private.raise_api_error('invalid_input', 'Invitation is not for transport', 400);
  end if;
  select f.status into v_fleet_status from public.fleets f where f.id = v_invitation.fleet_id for update;
  if not found or v_fleet_status <> 'published' then
    perform private.raise_api_error('invalid_transition', 'Fleet is not accepting enrollments', 409);
  end if;
  select * into v_student from public.students s where s.id = p_student_id for update;
  if not found then perform private.raise_api_error('not_found', 'Student not found', 404); end if;
  if v_invitation.role = 'student' then
    if v_student.student_type <> 'adult' or v_student.profile_id <> v_user_id then
      perform private.raise_api_error('forbidden', 'Student invitation requires the invited adult student', 403);
    end if;
  else
    select exists (
      select 1 from public.student_guardians sg
      where sg.student_id = p_student_id and sg.guardian_user_id = v_user_id
        and sg.is_primary and sg.status = 'active'
    ) into v_guardian_exists;
    if v_student.student_type <> 'minor' or not v_guardian_exists then
      perform private.raise_api_error('forbidden', 'Guardian invitation requires a managed minor', 403);
    end if;
  end if;
  select * into v_school from public.schools s where s.id = p_school_id for update;
  if not found or v_school.status <> 'active' then perform private.raise_api_error('not_found', 'School not found', 404); end if;
  if not exists (select 1 from public.fleet_service_schools fss where fss.fleet_id = v_invitation.fleet_id and fss.school_id = p_school_id)
    or not exists (select 1 from public.fleet_service_cities fsc where fsc.fleet_id = v_invitation.fleet_id and fsc.city_ibge_code = v_student.city_ibge_code) then
    perform private.raise_api_error('invalid_input', 'Fleet does not cover the school and student city', 400);
  end if;
  if exists (select 1 from public.fleet_enrollments e where e.fleet_id = v_invitation.fleet_id and e.student_id = p_student_id and e.status = 'active') then
    perform private.raise_api_error('enrollment_conflict', 'Student is already enrolled in this fleet', 409);
  end if;
  insert into public.fleet_join_requests (
    fleet_id, requester_user_id, student_id, school_id, origin, fleet_invitation_id, shift,
    directions, weekdays, postal_code, street, street_number, address_complement, neighborhood,
    city_name, city_ibge_code, state_code, latitude, longitude, request_kind
  ) values (
    v_invitation.fleet_id, v_user_id, p_student_id, p_school_id, 'invitation', v_invitation.id, p_shift,
    (select array_agg(direction order by direction) from (select distinct direction from unnest(p_directions) direction) directions),
    (select array_agg(day_value order by day_value) from (select distinct day_value from unnest(p_weekdays) day_value) weekdays),
    v_student.postal_code, v_student.street, v_student.street_number, v_student.address_complement,
    v_student.neighborhood, v_student.city_name, v_student.city_ibge_code, v_student.state_code,
    v_student.latitude, v_student.longitude, 'new'
  ) returning id into v_request_id;
  update public.fleet_invitations set status = 'accepted', responded_by = v_user_id, responded_at = clock_timestamp() where id = v_invitation.id;
  insert into public.audit_events (fleet_id, actor_user_id, action, entity_type, entity_id, metadata)
  values (v_invitation.fleet_id, v_user_id, 'fleet_invitation_accepted', 'fleet_invitation', v_invitation.id,
    jsonb_build_object('role', v_invitation.role, 'request_id', v_request_id));
  return v_request_id;
end;
$$;

revoke all on function private.allocation_set_conflicts(jsonb,uuid,smallint,date) from public,anon,authenticated;
revoke all on function private.find_request_allocation_step(uuid,date,jsonb,jsonb,uuid) from public,anon,authenticated;
grant execute on function private.allocation_set_conflicts(jsonb,uuid,smallint,date) to postgres,supabase_admin;
grant execute on function private.find_request_allocation_step(uuid,date,jsonb,jsonb,uuid) to postgres,supabase_admin;
revoke execute on function private.request_allocation_candidates(uuid, date) from public, anon, authenticated;
revoke execute on function private.reservation_has_capacity(uuid, smallint, date, integer, uuid) from public, anon, authenticated;
revoke execute on function private.student_schedule_conflicts(uuid, uuid, smallint, date, uuid) from public, anon, authenticated;
revoke execute on function private.find_request_allocation(uuid, date) from public, anon, authenticated;
revoke execute on function private.apply_request_allocation(uuid, jsonb, date) from public, anon, authenticated;
grant execute on function private.request_allocation_candidates(uuid, date) to postgres;
grant execute on function private.reservation_has_capacity(uuid, smallint, date, integer, uuid) to postgres;
grant execute on function private.student_schedule_conflicts(uuid, uuid, smallint, date, uuid) to postgres;
grant execute on function private.find_request_allocation(uuid, date) to postgres;
grant execute on function private.apply_request_allocation(uuid, jsonb, date) to postgres;

revoke execute on function public.submit_fleet_join_request(uuid, uuid, uuid, text, text[], smallint[]) from public, anon;
revoke execute on function public.approve_transport_request(uuid, jsonb, date) from public, anon;
revoke execute on function public.set_transport_request_status(uuid, text, text) from public, anon;
revoke execute on function public.decide_fleet_join_request(uuid, text) from public, anon;
revoke execute on function public.accept_fleet_invitation(text, uuid, uuid, text, text[], smallint[]) from public, anon;
revoke execute on function public.save_van(uuid, uuid, text, text, text, integer) from public, anon;
grant execute on function public.submit_fleet_join_request(uuid, uuid, uuid, text, text[], smallint[]) to authenticated;
grant execute on function public.approve_transport_request(uuid, jsonb, date) to authenticated;
grant execute on function public.set_transport_request_status(uuid, text, text) to authenticated;
grant execute on function public.decide_fleet_join_request(uuid, text) to authenticated;
grant execute on function public.accept_fleet_invitation(text, uuid, uuid, text, text[], smallint[]) to authenticated;
grant execute on function public.save_van(uuid, uuid, text, text, text, integer) to authenticated;
