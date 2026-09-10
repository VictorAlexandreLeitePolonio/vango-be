create table public.device_tokens (
  id uuid primary key default extensions.gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete restrict,
  installation_id uuid not null,
  platform text not null,
  token text not null,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  revoked_at timestamptz,
  constraint device_tokens_platform_valid check (platform in ('ios', 'android')),
  constraint device_tokens_token_valid check (
    btrim(token) <> '' and char_length(token) <= 4096
  ),
  constraint device_tokens_active_dates_valid check (
    (active and revoked_at is null) or (not active and revoked_at is not null)
  )
);

create unique index device_tokens_active_installation_key
  on public.device_tokens (user_id, installation_id) where active;
create unique index device_tokens_active_token_key
  on public.device_tokens (token) where active;
create index device_tokens_user_idx on public.device_tokens (user_id, updated_at desc);

alter table public.device_tokens enable row level security;
revoke all on table public.device_tokens from public, anon, authenticated;

create function public.register_device(
  p_installation_id uuid,
  p_platform text,
  p_token text
) returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_token text := nullif(btrim(p_token), '');
  v_current public.device_tokens%rowtype;
  v_id uuid;
  v_now timestamptz := clock_timestamp();
  v_constraint text;
begin
  if v_user_id is null then
    perform private.raise_api_error('unauthenticated', 'Authentication required', 401);
  end if;
  if not private.current_user_email_confirmed() then
    perform private.raise_api_error('email_unverified', 'Email confirmation required', 403);
  end if;
  if p_installation_id is null or p_platform is null
    or p_platform not in ('ios', 'android')
    or v_token is null or char_length(v_token) > 4096 then
    perform private.raise_api_error('invalid_input', 'Invalid device', 400);
  end if;
  if not exists (select 1 from public.profiles p where p.id = v_user_id) then
    perform private.raise_api_error('not_found', 'User not found', 404);
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('device-installation:' || v_user_id::text || ':'
      || p_installation_id::text, 0)
  );
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('device-token:' || v_token, 0)
  );

  perform 1
  from public.device_tokens d
  where d.token = v_token and d.active and d.user_id <> v_user_id
  for update;
  if found then
    perform private.raise_api_error('device_conflict', 'Device token is unavailable', 409);
  end if;

  update public.device_tokens
  set active = false, revoked_at = coalesce(revoked_at, v_now), updated_at = v_now
  where user_id = v_user_id and token = v_token and active
    and installation_id <> p_installation_id;

  select * into v_current
  from public.device_tokens d
  where d.user_id = v_user_id
    and d.installation_id = p_installation_id
    and d.active
  for update;

  if found then
    update public.device_tokens
    set platform = p_platform, token = v_token, active = true,
        revoked_at = null, updated_at = v_now
    where id = v_current.id;
    return v_current.id;
  end if;

  insert into public.device_tokens (
    user_id, installation_id, platform, token, active, created_at, updated_at
  ) values (
    v_user_id, p_installation_id, p_platform, v_token, true, v_now, v_now
  ) returning id into v_id;

  return v_id;
exception
  when unique_violation then
    get stacked diagnostics v_constraint = constraint_name;
    if v_constraint in (
      'device_tokens_active_token_key',
      'device_tokens_active_installation_key'
    ) then
      perform private.raise_api_error('device_conflict', 'Device token is unavailable', 409);
    end if;
    raise;
end;
$$;

create function public.revoke_device(
  p_installation_id uuid
) returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_now timestamptz := clock_timestamp();
begin
  if v_user_id is null then
    perform private.raise_api_error('unauthenticated', 'Authentication required', 401);
  end if;
  if not private.current_user_email_confirmed() then
    perform private.raise_api_error('email_unverified', 'Email confirmation required', 403);
  end if;
  if p_installation_id is null then
    perform private.raise_api_error('invalid_input', 'Installation is required', 400);
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('device-installation:' || v_user_id::text || ':'
      || p_installation_id::text, 0)
  );
  update public.device_tokens
  set active = false, revoked_at = coalesce(revoked_at, v_now), updated_at = v_now
  where user_id = v_user_id and installation_id = p_installation_id and active;
end;
$$;

revoke all on function public.register_device(uuid, text, text) from public, anon;
revoke all on function public.revoke_device(uuid) from public, anon;
grant execute on function public.register_device(uuid, text, text) to authenticated;
grant execute on function public.revoke_device(uuid) to authenticated;
