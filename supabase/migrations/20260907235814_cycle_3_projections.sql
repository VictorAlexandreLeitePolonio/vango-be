create or replace function public.get_fleet_planning(
  p_fleet_id uuid
) returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_is_owner boolean;
  v_is_driver boolean;
  v_vans jsonb;
  v_routes jsonb;
  v_schedules jsonb;
  v_reservations jsonb;
  v_revisions jsonb;
begin
  if v_user_id is null then
    perform private.raise_api_error('unauthenticated', 'Authentication required', 401);
  end if;
  if not private.current_user_email_confirmed() then
    perform private.raise_api_error('email_unverified', 'Email confirmation required', 403);
  end if;
  if p_fleet_id is null then
    perform private.raise_api_error('not_found', 'Fleet not found', 404);
  end if;
  v_is_owner := private.has_fleet_role(p_fleet_id, v_user_id, 'owner');
  v_is_driver := private.has_fleet_role(p_fleet_id, v_user_id, 'driver');
  if not v_is_owner and not v_is_driver then
    perform private.raise_api_error('not_found', 'Fleet not found', 404);
  end if;

  select coalesce(jsonb_agg(
    case when v_is_owner then
      jsonb_build_object(
        'id', v.id, 'plate', v.plate, 'model', v.model,
        'public_name', v.public_name, 'capacity', v.capacity, 'status', v.status
      )
    else
      jsonb_build_object(
        'id', v.id, 'model', v.model, 'public_name', v.public_name,
        'capacity', v.capacity, 'status', v.status
      )
    end order by v.id
  ), '[]'::jsonb)
  into v_vans
  from public.vans v
  where v.fleet_id = p_fleet_id
    and (v_is_owner or exists (
      select 1 from public.routes assigned_route
      where assigned_route.fleet_id = v.fleet_id
        and assigned_route.van_id = v.id
        and assigned_route.driver_user_id = v_user_id
    ));

  select coalesce(jsonb_agg(
    case when v_is_owner then
      jsonb_build_object(
        'id', r.id, 'name', r.name, 'direction', r.direction, 'shift', r.shift,
        'paired_route_id', r.paired_route_id, 'van_id', r.van_id,
        'driver_user_id', r.driver_user_id, 'proximity_minutes', r.proximity_minutes,
        'origin_label', r.origin_label, 'destination_label', r.destination_label,
        'status', r.status, 'routing_revision', r.routing_revision
      )
    else
      jsonb_build_object(
        'id', r.id, 'name', r.name, 'direction', r.direction, 'shift', r.shift,
        'paired_route_id', r.paired_route_id, 'van_id', r.van_id,
        'proximity_minutes', r.proximity_minutes,
        'origin_label', r.origin_label, 'destination_label', r.destination_label,
        'status', r.status, 'routing_revision', r.routing_revision
      )
    end order by r.id
  ), '[]'::jsonb)
  into v_routes
  from public.routes r
  where r.fleet_id = p_fleet_id
    and (v_is_owner or r.driver_user_id = v_user_id);

  select coalesce(jsonb_agg(
    jsonb_build_object(
      'id', rs.id, 'route_id', rs.route_id, 'weekdays', rs.weekdays,
      'starts_at', rs.starts_at, 'ends_at', rs.ends_at,
      'ends_next_day', rs.ends_next_day, 'timezone', rs.timezone,
      'valid_from', rs.valid_from, 'valid_until', rs.valid_until,
      'confirmation_minutes', rs.confirmation_minutes, 'status', rs.status
    ) order by rs.id
  ), '[]'::jsonb)
  into v_schedules
  from public.route_schedules rs
  where rs.fleet_id = p_fleet_id
    and (v_is_owner or exists (
      select 1 from public.routes r
      where r.fleet_id = rs.fleet_id and r.id = rs.route_id
        and r.driver_user_id = v_user_id
    ));

  select coalesce(jsonb_agg(
    case when v_is_owner then
      jsonb_build_object(
        'id', tr.id, 'enrollment_id', tr.enrollment_id, 'student_id', tr.student_id,
        'route_student_schedule_id', tr.route_student_schedule_id,
        'route_id', tr.route_id, 'schedule_id', tr.schedule_id, 'van_id', tr.van_id,
        'weekday', tr.weekday, 'direction', tr.direction,
        'valid_from', tr.valid_from, 'valid_until', tr.valid_until, 'status', tr.status
      )
    else
      jsonb_build_object(
        'id', tr.id, 'enrollment_id', tr.enrollment_id,
        'route_student_schedule_id', tr.route_student_schedule_id,
        'route_id', tr.route_id, 'schedule_id', tr.schedule_id, 'van_id', tr.van_id,
        'weekday', tr.weekday, 'direction', tr.direction,
        'valid_from', tr.valid_from, 'valid_until', tr.valid_until, 'status', tr.status
      )
    end order by tr.id
  ), '[]'::jsonb)
  into v_reservations
  from public.transport_reservations tr
  where tr.fleet_id = p_fleet_id
    and (v_is_owner or exists (
      select 1 from public.routes r
      where r.fleet_id = tr.fleet_id and r.id = tr.route_id
        and r.driver_user_id = v_user_id
    ));

  select coalesce(jsonb_agg(
    jsonb_build_object(
      'route_id', r.id, 'routing_revision', r.routing_revision
    ) order by r.id
  ), '[]'::jsonb)
  into v_revisions
  from public.routes r
  where r.fleet_id = p_fleet_id
    and (v_is_owner or r.driver_user_id = v_user_id);

  return jsonb_build_object(
    'vans', v_vans,
    'routes', v_routes,
    'schedules', v_schedules,
    'reservations', v_reservations,
    'revisions', v_revisions
  );
end;
$$;

create or replace function public.get_my_transport()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_students jsonb;
  v_enrollments jsonb;
  v_schedules jsonb;
  v_reservations jsonb;
  v_revisions jsonb;
begin
  if v_user_id is null then
    perform private.raise_api_error('unauthenticated', 'Authentication required', 401);
  end if;
  if not private.current_user_email_confirmed() then
    perform private.raise_api_error('email_unverified', 'Email confirmation required', 403);
  end if;

  select coalesce(jsonb_agg(
    jsonb_build_object(
      'id', s.id, 'full_name', s.full_name, 'student_type', s.student_type
    ) order by s.id
  ), '[]'::jsonb)
  into v_students
  from public.students s
  where private.can_view_student(s.id, v_user_id);

  select coalesce(jsonb_agg(
    jsonb_build_object(
      'id', e.id, 'fleet_id', e.fleet_id, 'student_id', e.student_id,
      'school_id', e.school_id, 'shift', e.shift, 'status', e.status,
      'routing_revision', e.routing_revision
    ) order by e.id
  ), '[]'::jsonb)
  into v_enrollments
  from public.fleet_enrollments e
  where e.status = 'active'
    and private.can_view_student(e.student_id, v_user_id)
    and exists (
      select 1
      from public.fleet_memberships fm
      join public.fleet_membership_roles fmr on fmr.membership_id = fm.id
      where fm.id is not null and fm.fleet_id = e.fleet_id
        and fm.user_id = v_user_id and fm.status = 'active'
        and fmr.role in ('guardian', 'student')
    );

  select coalesce(jsonb_agg(
    jsonb_build_object(
      'id', rss.id, 'enrollment_id', rss.enrollment_id, 'route_id', rss.route_id,
      'schedule_id', rss.schedule_id, 'weekday', rss.weekday,
      'direction', rss.direction, 'valid_from', rss.valid_from,
      'valid_until', rss.valid_until, 'status', rss.status
    ) order by rss.id
  ), '[]'::jsonb)
  into v_schedules
  from public.route_student_schedules rss
  where exists (
    select 1 from public.fleet_enrollments e
    where e.id = rss.enrollment_id and e.fleet_id = rss.fleet_id
      and e.status = 'active' and private.can_view_student(e.student_id, v_user_id)
      and exists (
        select 1
        from public.fleet_memberships fm
        join public.fleet_membership_roles fmr on fmr.membership_id = fm.id
        where fm.fleet_id = e.fleet_id and fm.user_id = v_user_id and fm.status = 'active'
          and fmr.role in ('guardian', 'student')
      )
  );

  select coalesce(jsonb_agg(
    jsonb_build_object(
      'id', tr.id, 'enrollment_id', tr.enrollment_id,
      'route_student_schedule_id', tr.route_student_schedule_id,
      'route_id', tr.route_id, 'schedule_id', tr.schedule_id,
      'van_id', tr.van_id, 'weekday', tr.weekday, 'direction', tr.direction,
      'valid_from', tr.valid_from, 'valid_until', tr.valid_until, 'status', tr.status
    ) order by tr.id
  ), '[]'::jsonb)
  into v_reservations
  from public.transport_reservations tr
  where exists (
    select 1 from public.fleet_enrollments e
    where e.id = tr.enrollment_id and e.fleet_id = tr.fleet_id
      and e.status = 'active' and private.can_view_student(e.student_id, v_user_id)
      and exists (
        select 1
        from public.fleet_memberships fm
        join public.fleet_membership_roles fmr on fmr.membership_id = fm.id
        where fm.fleet_id = e.fleet_id and fm.user_id = v_user_id and fm.status = 'active'
          and fmr.role in ('guardian', 'student')
      )
  );

  select coalesce(jsonb_agg(
    jsonb_build_object(
      'enrollment_id', e.id, 'routing_revision', e.routing_revision
    ) order by e.id
  ), '[]'::jsonb)
  into v_revisions
  from public.fleet_enrollments e
  where e.status = 'active'
    and private.can_view_student(e.student_id, v_user_id)
    and exists (
      select 1
      from public.fleet_memberships fm
      join public.fleet_membership_roles fmr on fmr.membership_id = fm.id
      where fm.fleet_id = e.fleet_id and fm.user_id = v_user_id and fm.status = 'active'
        and fmr.role in ('guardian', 'student')
    );

  return jsonb_build_object(
    'students', v_students,
    'enrollments', v_enrollments,
    'schedules', v_schedules,
    'reservations', v_reservations,
    'revisions', v_revisions
  );
end;
$$;

create or replace function public.list_marketplace_vans(
  p_fleet_id uuid
) returns table(
  id uuid,
  public_name text,
  model text,
  capacity integer
)
language sql
stable
security definer
set search_path = ''
as $$
  select v.id, v.public_name, v.model, v.capacity
  from public.vans v
  join public.fleets f on f.id = v.fleet_id
  where v.fleet_id = p_fleet_id
    and f.status = 'published'
    and v.status = 'active'
  order by v.id
$$;

revoke execute on function public.get_fleet_planning(uuid) from public, anon;
revoke execute on function public.get_my_transport() from public, anon;
revoke execute on function public.list_marketplace_vans(uuid) from public;
grant execute on function public.get_fleet_planning(uuid) to authenticated;
grant execute on function public.get_my_transport() to authenticated;
grant execute on function public.list_marketplace_vans(uuid) to anon, authenticated;
