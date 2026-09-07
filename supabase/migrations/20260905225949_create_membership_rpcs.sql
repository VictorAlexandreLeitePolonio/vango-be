create function public.set_fleet_member_roles(
  p_membership_id uuid,
  p_roles text[]
) returns text[]
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_fleet_id uuid;
  v_membership_status text;
  v_old_roles text[];
  v_new_roles text[];
begin
  if v_user_id is null then
    raise sqlstate 'PGRST' using
      message = jsonb_build_object('code', 'unauthenticated', 'message', 'Authentication required')::text,
      detail = jsonb_build_object('status', 401)::text;
  end if;

  select fm.fleet_id, fm.status
  into v_fleet_id, v_membership_status
  from public.fleet_memberships fm
  where fm.id = p_membership_id
  for update;

  if not found then
    raise sqlstate 'PGRST' using
      message = jsonb_build_object('code', 'membership_conflict', 'message', 'Membership not found')::text,
      detail = jsonb_build_object('status', 404)::text;
  end if;

  if v_membership_status <> 'active' then
    raise sqlstate 'PGRST' using
      message = jsonb_build_object('code', 'membership_conflict', 'message', 'Roles require an active membership')::text,
      detail = jsonb_build_object('status', 409)::text;
  end if;

  perform 1 from public.fleets f where f.id = v_fleet_id for update;

  if not private.has_fleet_role(v_fleet_id, v_user_id, 'owner') then
    raise sqlstate 'PGRST' using
      message = jsonb_build_object('code', 'forbidden', 'message', 'Owner role required')::text,
      detail = jsonb_build_object('status', 403)::text;
  end if;

  if p_roles is null or cardinality(p_roles) = 0 or array_position(p_roles, null) is not null then
    raise sqlstate 'PGRST' using
      message = jsonb_build_object('code', 'invalid_input', 'message', 'At least one role is required')::text,
      detail = jsonb_build_object('status', 400)::text;
  end if;

  select array_agg(distinct requested.role order by requested.role)
  into v_new_roles
  from unnest(p_roles) as requested(role);

  if cardinality(v_new_roles) <> cardinality(p_roles)
    or exists (
      select 1
      from unnest(v_new_roles) as requested(role)
      where requested.role not in ('owner', 'driver', 'guardian', 'student')
    ) then
    raise sqlstate 'PGRST' using
      message = jsonb_build_object('code', 'invalid_input', 'message', 'Roles must be unique and valid')::text,
      detail = jsonb_build_object('status', 400)::text;
  end if;

  select coalesce(array_agg(fmr.role order by fmr.role), array[]::text[])
  into v_old_roles
  from public.fleet_membership_roles fmr
  where fmr.membership_id = p_membership_id;

  if 'owner' = any(v_old_roles)
    and not ('owner' = any(v_new_roles))
    and private.is_last_active_owner(p_membership_id) then
    raise sqlstate 'PGRST' using
      message = jsonb_build_object('code', 'last_owner', 'message', 'The last active owner cannot be removed')::text,
      detail = jsonb_build_object('status', 409)::text;
  end if;

  delete from public.fleet_membership_roles
  where membership_id = p_membership_id;

  insert into public.fleet_membership_roles (membership_id, role)
  select p_membership_id, requested.role
  from unnest(v_new_roles) as requested(role);

  insert into public.audit_events (
    fleet_id, actor_user_id, action, entity_type, entity_id, metadata
  ) values (
    v_fleet_id,
    v_user_id,
    'member_roles_changed',
    'fleet_membership',
    p_membership_id,
    jsonb_build_object('previous_roles', v_old_roles, 'new_roles', v_new_roles)
  );

  return v_new_roles;
end;
$$;

create function public.set_fleet_membership_status(
  p_membership_id uuid,
  p_status text
) returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_fleet_id uuid;
  v_old_status text;
begin
  if v_user_id is null then
    raise sqlstate 'PGRST' using
      message = jsonb_build_object('code', 'unauthenticated', 'message', 'Authentication required')::text,
      detail = jsonb_build_object('status', 401)::text;
  end if;

  if p_status is null or p_status not in ('active', 'suspended', 'left') then
    raise sqlstate 'PGRST' using
      message = jsonb_build_object('code', 'invalid_status', 'message', 'Invalid membership status')::text,
      detail = jsonb_build_object('status', 400)::text;
  end if;

  select fm.fleet_id, fm.status
  into v_fleet_id, v_old_status
  from public.fleet_memberships fm
  where fm.id = p_membership_id
  for update;

  if not found then
    raise sqlstate 'PGRST' using
      message = jsonb_build_object('code', 'membership_conflict', 'message', 'Membership not found')::text,
      detail = jsonb_build_object('status', 404)::text;
  end if;

  perform 1 from public.fleets f where f.id = v_fleet_id for update;

  if not private.has_fleet_role(v_fleet_id, v_user_id, 'owner') then
    raise sqlstate 'PGRST' using
      message = jsonb_build_object('code', 'forbidden', 'message', 'Owner role required')::text,
      detail = jsonb_build_object('status', 403)::text;
  end if;

  if p_status <> 'active' and private.is_last_active_owner(p_membership_id) then
    raise sqlstate 'PGRST' using
      message = jsonb_build_object('code', 'last_owner', 'message', 'The last active owner cannot leave or be suspended')::text,
      detail = jsonb_build_object('status', 409)::text;
  end if;

  update public.fleet_memberships
  set status = p_status,
      suspended_at = case when p_status = 'suspended' then clock_timestamp() else null end,
      left_at = case when p_status = 'left' then clock_timestamp() else null end
  where id = p_membership_id;

  if v_old_status is distinct from p_status then
    insert into public.audit_events (
      fleet_id, actor_user_id, action, entity_type, entity_id, metadata
    ) values (
      v_fleet_id,
      v_user_id,
      'membership_status_changed',
      'fleet_membership',
      p_membership_id,
      jsonb_build_object('previous_status', v_old_status, 'new_status', p_status)
    );
  end if;

  return p_status;
end;
$$;

revoke execute on function public.set_fleet_member_roles(uuid, text[]) from public, anon;
revoke execute on function public.set_fleet_membership_status(uuid, text) from public, anon;
grant execute on function public.set_fleet_member_roles(uuid, text[]) to authenticated;
grant execute on function public.set_fleet_membership_status(uuid, text) to authenticated;
