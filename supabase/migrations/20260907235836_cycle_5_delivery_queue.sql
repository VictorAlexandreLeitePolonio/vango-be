create table public.notification_deliveries (
  id uuid primary key default extensions.gen_random_uuid(),
  notification_id uuid not null,
  device_id uuid not null,
  state text not null default 'pending',
  attempt integer not null default 0,
  next_attempt_at timestamptz not null default now(),
  lease_id uuid,
  lease_until timestamptz,
  claimed_token text,
  provider_id text,
  last_error_code text,
  sent_at timestamptz,
  constraint notification_deliveries_notification_fk
    foreign key (notification_id) references public.notifications(id) on delete cascade,
  constraint notification_deliveries_device_fk
    foreign key (device_id) references public.device_tokens(id) on delete restrict,
  constraint notification_deliveries_state_valid check (
    state in ('pending', 'processing', 'sent', 'failed', 'expired', 'suppressed')
  ),
  constraint notification_deliveries_attempt_valid check (attempt between 0 and 5),
  constraint notification_deliveries_lease_valid check (
    (state = 'processing' and lease_id is not null and lease_until is not null)
    or (state <> 'processing')
  ),
  constraint notification_deliveries_provider_id_valid check (
    provider_id is null or (btrim(provider_id) <> '' and char_length(provider_id) <= 256)
  ),
  constraint notification_deliveries_claimed_token_valid check (
    claimed_token is null
    or (btrim(claimed_token) <> '' and char_length(claimed_token) <= 4096)
  ),
  constraint notification_deliveries_error_code_valid check (
    last_error_code is null
    or (btrim(last_error_code) <> '' and char_length(last_error_code) <= 128)
  ),
  constraint notification_deliveries_sent_date_valid check (
    (state = 'sent' and sent_at is not null)
    or (state <> 'sent')
  ),
  constraint notification_deliveries_notification_device_key unique (notification_id, device_id)
);

create index notification_deliveries_claim_idx
  on public.notification_deliveries (state, next_attempt_at, lease_until, id);
create index notification_deliveries_notification_idx
  on public.notification_deliveries (notification_id, state);
create index notification_deliveries_device_idx
  on public.notification_deliveries (device_id, state);

alter table public.notification_deliveries enable row level security;
revoke all on table public.notification_deliveries from public, anon, authenticated;

create function private.notification_retry_delay(
  p_attempt integer,
  p_retry_after_seconds integer
) returns interval
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_base numeric;
  v_jitter numeric;
  v_retry_after numeric := greatest(coalesce(p_retry_after_seconds, 0), 0);
begin
  if p_attempt is null or p_attempt < 1 or p_attempt > 5
    or p_retry_after_seconds is not null and p_retry_after_seconds < 0 then
    perform private.raise_api_error('invalid_input', 'Invalid retry parameters', 400);
  end if;
  v_base := least(3600::numeric, 60::numeric * power(2::numeric, p_attempt - 1));
  v_jitter := v_base * (0.5 + pg_catalog.random() * 0.5);
  return make_interval(secs => greatest(v_jitter, v_retry_after));
end;
$$;

create function public.claim_notification_deliveries(
  p_limit integer,
  p_lease_id uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_now timestamptz := clock_timestamp();
begin
  if p_limit is null or p_limit < 1 or p_limit > 100 or p_lease_id is null then
    perform private.raise_api_error('invalid_input', 'Invalid delivery claim', 400);
  end if;

  insert into public.notification_deliveries (notification_id, device_id)
  select nr.notification_id, d.id
  from public.notification_recipients nr
  join public.notifications n on n.id = nr.notification_id
  join public.device_tokens d on d.user_id = nr.user_id and d.active
  where n.expires_at > v_now
    and private.notification_actionable(n.id, nr.user_id, v_now)
  on conflict (notification_id, device_id) do nothing;

  update public.notification_deliveries d
  set state = case
        when n.expires_at <= v_now then 'expired'
        when not device.active then 'suppressed'
        when d.state = 'processing' and d.attempt >= 5 then 'failed'
        else d.state
      end,
      lease_id = null,
      lease_until = null,
      claimed_token = null,
      last_error_code = case
        when n.expires_at <= v_now then 'expired'
        when not device.active then 'device_inactive'
        when d.state = 'processing' and d.attempt >= 5 then 'attempt_limit'
        else d.last_error_code
      end
  from public.notifications n, public.device_tokens device
  where d.notification_id = n.id
    and device.id = d.device_id
    and d.state in ('pending', 'processing')
    and (
      n.expires_at <= v_now
      or not device.active
      or d.state = 'processing' and d.attempt >= 5 and d.lease_until < v_now
    );

  with candidates as (
    select d.id, device.token as claimed_token
    from public.notification_deliveries d
    join public.notifications n on n.id = d.notification_id
    join public.device_tokens device on device.id = d.device_id
    join public.notification_recipients nr
      on nr.notification_id = d.notification_id and nr.user_id = device.user_id
    where device.active
      and (
        (d.state = 'pending' and d.next_attempt_at <= v_now)
        or (d.state = 'processing' and d.lease_until < v_now)
      )
      and d.attempt < 5
      and private.notification_actionable(n.id, nr.user_id, v_now)
    order by d.next_attempt_at, d.id
    limit p_limit
    for update of d skip locked
  )
  update public.notification_deliveries d
  set state = 'processing',
      attempt = d.attempt + 1,
      lease_id = p_lease_id,
      lease_until = v_now + interval '60 seconds',
      claimed_token = candidates.claimed_token
  from candidates
  where d.id = candidates.id;

  return coalesce(
    (
      select jsonb_agg(item order by item->>'id')
      from (
        select jsonb_build_object(
          'id', d.id,
          'token', device.token,
          'notification_id', d.notification_id,
          'expires_at', n.expires_at,
          'attempt', d.attempt,
          'lease_id', d.lease_id
        ) as item
        from public.notification_deliveries d
        join public.notifications n on n.id = d.notification_id
        join public.device_tokens device on device.id = d.device_id
        where d.lease_id = p_lease_id and d.state = 'processing'
          and d.lease_until = v_now + interval '60 seconds'
      ) rows
    ),
    '[]'::jsonb
  );
end;
$$;

create function public.notification_delivery_ready(
  p_delivery_id uuid,
  p_lease_id uuid
) returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_now timestamptz := clock_timestamp();
  v_user_id uuid;
  v_notification_id uuid;
begin
  if p_delivery_id is null or p_lease_id is null then
    return false;
  end if;
  select d.notification_id, device.user_id
  into v_notification_id, v_user_id
  from public.notification_deliveries d
  join public.device_tokens device on device.id = d.device_id
  where d.id = p_delivery_id and d.lease_id = p_lease_id
    and d.state = 'processing' and d.lease_until > v_now
    and device.active and d.claimed_token = device.token;
  if not found then
    return false;
  end if;
  return private.notification_actionable(v_notification_id, v_user_id, v_now);
end;
$$;

create function public.finish_notification_delivery(
  p_delivery_id uuid,
  p_lease_id uuid,
  p_outcome text,
  p_provider_id text,
  p_error_code text,
  p_retry_after_seconds integer
) returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_now timestamptz := clock_timestamp();
  v_delivery public.notification_deliveries%rowtype;
  v_notification public.notifications%rowtype;
  v_user_id uuid;
  v_current_token text;
  v_context record;
  v_next_attempt_at timestamptz;
  v_retry_delay interval;
  v_state text;
  v_last_error_code text := nullif(btrim(p_error_code), '');
begin
  if p_delivery_id is null or p_lease_id is null or p_outcome is null
    or p_outcome not in ('sent', 'retry', 'invalid_token', 'permanent_failure') then
    perform private.raise_api_error('invalid_input', 'Invalid delivery outcome', 400);
  end if;
  if p_provider_id is not null
    and (btrim(p_provider_id) = '' or char_length(p_provider_id) > 256) then
    perform private.raise_api_error('invalid_input', 'Invalid provider id', 400);
  end if;
  if p_error_code is not null
    and (btrim(p_error_code) = '' or char_length(p_error_code) > 128
      or p_error_code !~ '^[A-Za-z0-9_.:-]+$') then
    perform private.raise_api_error('invalid_input', 'Invalid error code', 400);
  end if;
  if p_retry_after_seconds is not null and p_retry_after_seconds < 0 then
    perform private.raise_api_error('invalid_input', 'Invalid retry delay', 400);
  end if;

  select d as delivery, n as notification, device.user_id as user_id,
    device.token as current_token
  into v_context
  from public.notification_deliveries d
  join public.notifications n on n.id = d.notification_id
  join public.device_tokens device on device.id = d.device_id
  where d.id = p_delivery_id and d.lease_id = p_lease_id
    and d.state = 'processing' and d.lease_until > v_now
  for update of d;
  if not found then
    return 'lease_lost';
  end if;
  v_delivery := v_context.delivery;
  v_notification := v_context.notification;
  v_user_id := v_context.user_id;
  v_current_token := v_context.current_token;
  v_now := clock_timestamp();
  if v_delivery.lease_until <= v_now then
    return 'lease_lost';
  end if;

  if p_outcome = 'sent' then
    update public.notification_deliveries
    set state = 'sent', provider_id = nullif(btrim(p_provider_id), ''),
        last_error_code = null, sent_at = v_now,
        lease_id = null, lease_until = null, claimed_token = null,
        next_attempt_at = v_now
    where id = v_delivery.id and lease_id = p_lease_id and state = 'processing';
    if not found then return 'lease_lost'; end if;
    return 'sent';
  elsif p_outcome = 'invalid_token' then
    if v_delivery.claimed_token is not null
      and v_delivery.claimed_token = v_current_token then
      update public.device_tokens
      set active = false, revoked_at = coalesce(revoked_at, v_now), updated_at = v_now
      where id = v_delivery.device_id and active
        and token = v_delivery.claimed_token;
      v_state := 'failed';
    else
      v_state := 'suppressed';
      v_last_error_code := coalesce(v_last_error_code, 'token_rotated');
    end if;
  elsif p_outcome = 'permanent_failure' then
    if v_notification.expires_at <= v_now then
      v_state := 'expired';
    elsif not private.notification_actionable(v_notification.id, v_user_id, v_now) then
      v_state := 'suppressed';
    else
      v_state := 'failed';
    end if;
  else
    if v_notification.expires_at <= v_now then
      v_state := 'expired';
    elsif v_delivery.attempt >= 5 then
      v_state := 'failed';
    else
      v_retry_delay := private.notification_retry_delay(
        v_delivery.attempt, p_retry_after_seconds
      );
      v_next_attempt_at := v_now + v_retry_delay;
      if v_next_attempt_at >= v_notification.expires_at then
        v_state := 'expired';
      else
      update public.notification_deliveries
      set state = 'pending', next_attempt_at = v_next_attempt_at,
            last_error_code = v_last_error_code,
            lease_id = null, lease_until = null, claimed_token = null
        where id = v_delivery.id and lease_id = p_lease_id and state = 'processing';
        if not found then return 'lease_lost'; end if;
        return 'retry';
      end if;
    end if;
  end if;

  update public.notification_deliveries
  set state = v_state,
      next_attempt_at = v_now,
      last_error_code = v_last_error_code,
      lease_id = null,
      lease_until = null,
      claimed_token = null
  where id = v_delivery.id and lease_id = p_lease_id and state = 'processing';
  if not found then return 'lease_lost'; end if;
  return v_state;
end;
$$;

revoke all on function private.notification_retry_delay(integer, integer)
  from public, anon, authenticated;
revoke all on function public.claim_notification_deliveries(integer, uuid)
  from public, anon, authenticated;
revoke all on function public.notification_delivery_ready(uuid, uuid)
  from public, anon, authenticated;
revoke all on function public.finish_notification_delivery(uuid, uuid, text, text, text, integer)
  from public, anon, authenticated;
grant execute on function public.claim_notification_deliveries(integer, uuid)
  to service_role, postgres, supabase_admin;
grant execute on function public.notification_delivery_ready(uuid, uuid)
  to service_role, postgres, supabase_admin;
grant execute on function public.finish_notification_delivery(uuid, uuid, text, text, text, integer)
  to service_role, postgres, supabase_admin;
grant execute on function private.notification_retry_delay(integer, integer)
  to postgres, supabase_admin;
