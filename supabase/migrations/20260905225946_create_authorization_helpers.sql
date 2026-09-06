create function private.is_active_fleet_member(
  p_fleet_id uuid,
  p_user_id uuid
) returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.fleet_memberships fm
    where fm.fleet_id = p_fleet_id
      and fm.user_id = p_user_id
      and fm.status = 'active'
  );
$$;

create function private.has_fleet_role(
  p_fleet_id uuid,
  p_user_id uuid,
  p_role text
) returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.fleet_memberships fm
    join public.fleet_membership_roles fmr on fmr.membership_id = fm.id
    where fm.fleet_id = p_fleet_id
      and fm.user_id = p_user_id
      and fm.status = 'active'
      and fmr.role = p_role
  );
$$;

create function private.is_last_active_owner(p_membership_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select
    exists (
      select 1
      from public.fleet_membership_roles existing_role
      where existing_role.membership_id = p_membership_id
        and existing_role.role = 'owner'
    )
    and (
      select count(*)
      from public.fleet_memberships fm
      join public.fleet_membership_roles fmr on fmr.membership_id = fm.id
      where fm.fleet_id = (
        select target.fleet_id
        from public.fleet_memberships target
        where target.id = p_membership_id
      )
        and fm.status = 'active'
        and fmr.role = 'owner'
    ) = 1;
$$;

revoke execute on function private.is_active_fleet_member(uuid, uuid) from public, anon, authenticated;
revoke execute on function private.has_fleet_role(uuid, uuid, text) from public, anon, authenticated;
revoke execute on function private.is_last_active_owner(uuid) from public, anon, authenticated;
