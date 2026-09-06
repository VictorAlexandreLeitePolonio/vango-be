create function public.create_fleet(
  p_name text,
  p_slug text,
  p_description text default null,
  p_logo_path text default null,
  p_status text default 'draft'
) returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_email_confirmed boolean;
  v_fleet_id uuid;
  v_membership_id uuid;
begin
  if v_user_id is null then
    raise sqlstate 'PGRST' using
      message = jsonb_build_object('code', 'unauthenticated', 'message', 'Authentication required')::text,
      detail = jsonb_build_object('status', 401)::text;
  end if;

  select u.email_confirmed_at is not null
  into v_email_confirmed
  from auth.users u
  where u.id = v_user_id;

  if v_email_confirmed is not true then
    raise sqlstate 'PGRST' using
      message = jsonb_build_object('code', 'email_unverified', 'message', 'Email confirmation required')::text,
      detail = jsonb_build_object('status', 403)::text;
  end if;

  if p_name is null or btrim(p_name) = ''
    or p_slug is null
    or p_slug !~ '^[a-z0-9]+(?:-[a-z0-9]+)*$' then
    raise sqlstate 'PGRST' using
      message = jsonb_build_object('code', 'invalid_input', 'message', 'Invalid fleet name or slug')::text,
      detail = jsonb_build_object('status', 400)::text;
  end if;

  if p_status is null or p_status not in ('draft', 'published') then
    raise sqlstate 'PGRST' using
      message = jsonb_build_object('code', 'invalid_status', 'message', 'Invalid initial fleet status')::text,
      detail = jsonb_build_object('status', 400)::text;
  end if;

  insert into public.fleets (
    name,
    slug,
    description,
    logo_path,
    status,
    created_by
  ) values (
    btrim(p_name),
    p_slug,
    p_description,
    p_logo_path,
    p_status,
    v_user_id
  )
  returning id into v_fleet_id;

  insert into public.fleet_memberships (fleet_id, user_id)
  values (v_fleet_id, v_user_id)
  returning id into v_membership_id;

  insert into public.fleet_membership_roles (membership_id, role)
  values (v_membership_id, 'owner');

  insert into public.audit_events (
    fleet_id,
    actor_user_id,
    action,
    entity_type,
    entity_id
  ) values (
    v_fleet_id,
    v_user_id,
    'fleet_created',
    'fleet',
    v_fleet_id
  );

  return v_fleet_id;
exception
  when unique_violation then
    raise sqlstate 'PGRST' using
      message = jsonb_build_object('code', 'slug_conflict', 'message', 'Fleet slug already exists')::text,
      detail = jsonb_build_object('status', 409)::text;
end;
$$;

revoke execute on function public.create_fleet(text, text, text, text, text) from public, anon;
grant execute on function public.create_fleet(text, text, text, text, text) to authenticated;
