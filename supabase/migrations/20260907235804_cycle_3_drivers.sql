alter table public.fleet_invitations drop constraint fleet_invitations_role_valid;
alter table public.fleet_invitations add constraint fleet_invitations_role_valid
check (role in ('guardian', 'student', 'driver'));

create or replace function private.assert_driver_releasable(
  p_fleet_id uuid,
  p_user_id uuid
) returns void
language plpgsql
set search_path = ''
as $$
begin
  -- Route and trip assignments are checked once those tables exist.
  return;
end;
$$;

revoke execute on function private.assert_driver_releasable(uuid, uuid) from public, anon, authenticated;
grant execute on function private.assert_driver_releasable(uuid, uuid) to postgres;

create or replace function public.create_fleet_invitation(
  p_fleet_id uuid,
  p_email text,
  p_role text
) returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_email text := lower(btrim(p_email));
  v_token text;
begin
  if v_user_id is null then
    perform private.raise_api_error('unauthenticated', 'Authentication required', 401);
  end if;
  if not private.current_user_email_confirmed() then
    perform private.raise_api_error('email_unverified', 'Email confirmation required', 403);
  end if;
  if v_email is null or v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'
    or p_role is null or p_role not in ('guardian', 'student', 'driver') then
    perform private.raise_api_error('invalid_input', 'Invalid email or invitation role', 400);
  end if;

  perform private.lock_planning();
  perform 1 from public.fleets f where f.id = p_fleet_id for update;
  if not found or not private.has_fleet_role(p_fleet_id, v_user_id, 'owner') then
    perform private.raise_api_error('not_found', 'Fleet not found', 404);
  end if;

  v_token := encode(extensions.gen_random_bytes(32), 'hex');
  insert into public.fleet_invitations (
    fleet_id, email, token_hash, role, created_by, expires_at
  ) values (
    p_fleet_id, v_email, extensions.digest(v_token, 'sha256'), p_role,
    v_user_id, clock_timestamp() + interval '14 days'
  );
  insert into public.audit_events (
    fleet_id, actor_user_id, action, entity_type, entity_id, metadata
  )
  select p_fleet_id, v_user_id, 'fleet_invitation_created', 'fleet_invitation', i.id,
         jsonb_build_object('role', p_role)
  from public.fleet_invitations i
  where i.token_hash = extensions.digest(v_token, 'sha256');
  return v_token;
exception
  when unique_violation then
    perform private.raise_api_error('invitation_conflict', 'A pending invitation already exists', 409);
    return null;
end;
$$;

create function public.accept_driver_invitation(
  p_token text
) returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_invitation public.fleet_invitations%rowtype;
  v_membership_id uuid;
  v_membership_status text;
begin
  if v_user_id is null then
    perform private.raise_api_error('unauthenticated', 'Authentication required', 401);
  end if;
  if not private.current_user_email_confirmed() then
    perform private.raise_api_error('email_unverified', 'Email confirmation required', 403);
  end if;
  if p_token is null or btrim(p_token) = '' then
    perform private.raise_api_error('not_found', 'Invitation not found', 404);
  end if;

  perform private.lock_planning();
  select * into v_invitation
  from public.fleet_invitations i
  where i.token_hash = extensions.digest(p_token, 'sha256')
  for update;
  if not found then
    perform private.raise_api_error('not_found', 'Invitation not found', 404);
  end if;
  if v_invitation.status <> 'pending' then
    if v_invitation.status = 'expired' then
      return null;
    end if;
    perform private.raise_api_error('invalid_transition', 'Invitation is no longer pending', 409);
  end if;
  if clock_timestamp() > v_invitation.expires_at then
    update public.fleet_invitations
    set status = 'expired', responded_at = clock_timestamp(), responded_by = v_user_id
    where id = v_invitation.id;
    return null;
  end if;
  if v_invitation.role <> 'driver' then
    perform private.raise_api_error('invalid_input', 'Invitation is not for a driver', 400);
  end if;
  if private.current_user_email() is distinct from lower(btrim(v_invitation.email)) then
    perform private.raise_api_error('invitation_email_mismatch', 'Authenticated email does not match invitation', 403);
  end if;

  perform 1 from public.fleets f
  where f.id = v_invitation.fleet_id
  for update;
  if not found then
    perform private.raise_api_error('not_found', 'Fleet not found', 404);
  end if;

  select fm.id, fm.status into v_membership_id, v_membership_status
  from public.fleet_memberships fm
  where fm.fleet_id = v_invitation.fleet_id and fm.user_id = v_user_id
  for update;
  if not found then
    insert into public.fleet_memberships (fleet_id, user_id)
    values (v_invitation.fleet_id, v_user_id)
    returning id into v_membership_id;
  elsif v_membership_status = 'left' then
    update public.fleet_memberships
    set status = 'active', suspended_at = null, left_at = null
    where id = v_membership_id;
  elsif v_membership_status = 'suspended' then
    perform private.raise_api_error('membership_conflict', 'Suspended membership cannot accept a driver invitation', 409);
  end if;

  insert into public.fleet_membership_role_sources (
    membership_id, role, source_type, enrollment_id
  ) values (v_membership_id, 'driver', 'manual', null)
  on conflict do nothing;
  perform private.sync_effective_membership_roles(v_membership_id);

  update public.fleet_invitations
  set status = 'accepted', responded_by = v_user_id, responded_at = clock_timestamp()
  where id = v_invitation.id;
  insert into public.audit_events (
    fleet_id, actor_user_id, action, entity_type, entity_id, metadata
  ) values (
    v_invitation.fleet_id, v_user_id, 'fleet_invitation_accepted',
    'fleet_invitation', v_invitation.id, jsonb_build_object('role', 'driver')
  );
  return v_membership_id;
end;
$$;

create or replace function public.set_fleet_member_roles(
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
  v_target_user_id uuid;
  v_membership_status text;
  v_old_roles text[];
  v_new_roles text[];
begin
  if v_user_id is null then
    perform private.raise_api_error('unauthenticated', 'Authentication required', 401);
  end if;
  perform private.lock_planning();

  select fm.fleet_id, fm.user_id, fm.status
  into v_fleet_id, v_target_user_id, v_membership_status
  from public.fleet_memberships fm
  where fm.id = p_membership_id
  for update;
  if not found then
    perform private.raise_api_error('membership_conflict', 'Membership not found', 404);
  end if;
  if v_membership_status <> 'active' then
    perform private.raise_api_error('membership_conflict', 'Roles require an active membership', 409);
  end if;
  perform 1 from public.fleets f where f.id = v_fleet_id for update;
  if not private.has_fleet_role(v_fleet_id, v_user_id, 'owner') then
    perform private.raise_api_error('forbidden', 'Owner role required', 403);
  end if;
  if p_roles is null or cardinality(p_roles) = 0 or array_position(p_roles, null) is not null then
    perform private.raise_api_error('invalid_input', 'At least one role is required', 400);
  end if;

  select array_agg(distinct requested.role order by requested.role)
  into v_new_roles
  from unnest(p_roles) as requested(role);
  if cardinality(v_new_roles) <> cardinality(p_roles)
    or exists (
      select 1 from unnest(v_new_roles) as requested(role)
      where requested.role not in ('owner', 'driver', 'guardian', 'student')
    ) then
    perform private.raise_api_error('invalid_input', 'Roles must be unique and valid', 400);
  end if;

  select coalesce(array_agg(fmr.role order by fmr.role), array[]::text[])
  into v_old_roles
  from public.fleet_membership_roles fmr
  where fmr.membership_id = p_membership_id;
  if 'owner' = any(v_old_roles) and not ('owner' = any(v_new_roles))
    and private.is_last_active_owner(p_membership_id) then
    perform private.raise_api_error('last_owner', 'The last active owner cannot be removed', 409);
  end if;
  if 'driver' = any(v_old_roles) and not ('driver' = any(v_new_roles)) then
    perform private.assert_driver_releasable(v_fleet_id, v_target_user_id);
  end if;

  delete from public.fleet_membership_role_sources
  where membership_id = p_membership_id and source_type = 'manual';
  insert into public.fleet_membership_role_sources (membership_id, role, source_type)
  select p_membership_id, requested.role, 'manual'
  from unnest(v_new_roles) as requested(role);
  perform private.sync_effective_membership_roles(p_membership_id);
  select coalesce(array_agg(fmr.role order by fmr.role), array[]::text[])
  into v_new_roles
  from public.fleet_membership_roles fmr
  where fmr.membership_id = p_membership_id;
  if v_old_roles is distinct from v_new_roles then
    insert into public.audit_events (
      fleet_id, actor_user_id, action, entity_type, entity_id, metadata
    ) values (
      v_fleet_id, v_user_id, 'member_roles_changed', 'fleet_membership',
      p_membership_id, jsonb_build_object('previous_roles', v_old_roles, 'new_roles', v_new_roles)
    );
  end if;
  return v_new_roles;
end;
$$;

create or replace function public.set_fleet_membership_status(
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
  v_target_user_id uuid;
  v_old_status text;
begin
  if v_user_id is null then
    perform private.raise_api_error('unauthenticated', 'Authentication required', 401);
  end if;
  if p_status is null or p_status not in ('active', 'suspended', 'left') then
    perform private.raise_api_error('invalid_status', 'Invalid membership status', 400);
  end if;
  perform private.lock_planning();
  select fm.fleet_id, fm.user_id, fm.status
  into v_fleet_id, v_target_user_id, v_old_status
  from public.fleet_memberships fm
  where fm.id = p_membership_id
  for update;
  if not found then
    perform private.raise_api_error('membership_conflict', 'Membership not found', 404);
  end if;
  perform 1 from public.fleets f where f.id = v_fleet_id for update;
  if not private.has_fleet_role(v_fleet_id, v_user_id, 'owner') then
    perform private.raise_api_error('forbidden', 'Owner role required', 403);
  end if;
  if p_status <> 'active' and private.is_last_active_owner(p_membership_id) then
    perform private.raise_api_error('last_owner', 'The last active owner cannot leave or be suspended', 409);
  end if;
  if p_status <> 'active' and exists (
    select 1 from public.fleet_membership_roles fmr
    where fmr.membership_id = p_membership_id and fmr.role = 'driver'
  ) then
    perform private.assert_driver_releasable(v_fleet_id, v_target_user_id);
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
      v_fleet_id, v_user_id, 'membership_status_changed', 'fleet_membership',
      p_membership_id, jsonb_build_object('previous_status', v_old_status, 'new_status', p_status)
    );
  end if;
  return p_status;
end;
$$;

revoke execute on function public.create_fleet_invitation(uuid, text, text) from public, anon;
revoke execute on function public.accept_driver_invitation(text) from public, anon;
revoke execute on function public.set_fleet_member_roles(uuid, text[]) from public, anon;
revoke execute on function public.set_fleet_membership_status(uuid, text) from public, anon;
grant execute on function public.create_fleet_invitation(uuid, text, text) to authenticated;
grant execute on function public.accept_driver_invitation(text) to authenticated;
grant execute on function public.set_fleet_member_roles(uuid, text[]) to authenticated;
grant execute on function public.set_fleet_membership_status(uuid, text) to authenticated;
