create table public.notifications (
  id uuid primary key default extensions.gen_random_uuid(),
  fleet_id uuid not null references public.fleets(id) on delete restrict,
  event_key text not null,
  category text not null,
  entity_type text not null,
  entity_id uuid not null,
  body jsonb not null,
  occurred_at timestamptz not null,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  constraint notifications_event_key_not_blank check (
    btrim(event_key) <> '' and char_length(event_key) <= 512
  ),
  constraint notifications_category_not_blank check (
    btrim(category) <> '' and char_length(category) <= 64
  ),
  constraint notifications_entity_type_not_blank check (
    btrim(entity_type) <> '' and char_length(entity_type) <= 64
  ),
  constraint notifications_body_object check (jsonb_typeof(body) = 'object'),
  constraint notifications_expiry_after_occurrence check (expires_at > occurred_at),
  constraint notifications_id_fleet_key unique (id, fleet_id),
  constraint notifications_event_key_unique unique (fleet_id, event_key)
);

create index notifications_fleet_occurred_idx
  on public.notifications (fleet_id, occurred_at desc, created_at desc, id desc);
create index notifications_expiry_idx
  on public.notifications (expires_at);

create table public.notification_recipients (
  notification_id uuid not null,
  fleet_id uuid not null,
  user_id uuid not null references public.profiles(id) on delete restrict,
  read_at timestamptz,
  created_at timestamptz not null default now(),
  constraint notification_recipients_pkey primary key (notification_id, user_id),
  constraint notification_recipients_notification_fleet_fk
    foreign key (notification_id, fleet_id)
    references public.notifications(id, fleet_id) on delete cascade
);

create index notification_recipients_user_created_idx
  on public.notification_recipients (user_id, created_at desc, notification_id);
create index notification_recipients_fleet_user_idx
  on public.notification_recipients (fleet_id, user_id, notification_id);

alter table public.notifications enable row level security;
alter table public.notification_recipients enable row level security;

revoke all on table public.notifications from public, anon, authenticated;
revoke all on table public.notification_recipients from public, anon, authenticated;

create function private.can_read_notification(
  p_notification_id uuid,
  p_user_id uuid
) returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.notification_recipients nr
    join public.notifications n
      on n.id = nr.notification_id
     and n.fleet_id = nr.fleet_id
    where nr.notification_id = p_notification_id
      and nr.user_id = p_user_id
      and (
        private.is_active_fleet_member(nr.fleet_id, p_user_id)
        or (
          n.entity_type = 'join_request'
          and exists (
            select 1
            from public.fleet_join_requests request
            where request.id = n.entity_id
              and request.fleet_id = n.fleet_id
              and request.requester_user_id = p_user_id
          )
        )
      )
      and (
        n.body->>'student_id' is null
        or (
          n.entity_type = 'join_request'
          and exists (
            select 1
            from public.fleet_join_requests request
            where request.id = n.entity_id
              and request.fleet_id = n.fleet_id
              and request.requester_user_id = p_user_id
          )
        )
        or private.has_fleet_role(n.fleet_id, p_user_id, 'owner')
        or private.has_fleet_role(n.fleet_id, p_user_id, 'driver')
        or (
          n.body->>'student_id' ~
            '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
          and private.can_view_student((n.body->>'student_id')::uuid, p_user_id)
        )
      )
  );
$$;

create policy notification_recipients_select_authorized
on public.notification_recipients for select to authenticated
using (private.can_read_notification(notification_id, (select auth.uid())));

create function private.create_notification(
  p_fleet_id uuid,
  p_event_key text,
  p_category text,
  p_entity_type text,
  p_entity_id uuid,
  p_body jsonb,
  p_occurred_at timestamptz,
  p_expires_at timestamptz,
  p_recipient_ids uuid[]
) returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_notification_id uuid;
begin
  if p_fleet_id is null or p_event_key is null or btrim(p_event_key) = ''
    or char_length(p_event_key) > 512
    or p_category is null or btrim(p_category) = '' or char_length(p_category) > 64
    or p_entity_type is null or btrim(p_entity_type) = ''
    or char_length(p_entity_type) > 64
    or p_entity_id is null
    or p_body is null or jsonb_typeof(p_body) <> 'object'
    or p_occurred_at is null or p_expires_at is null
    or p_expires_at <= p_occurred_at then
    perform private.raise_api_error('invalid_input', 'Invalid notification', 400);
  end if;

  if not exists (select 1 from public.fleets f where f.id = p_fleet_id) then
    perform private.raise_api_error('not_found', 'Fleet not found', 404);
  end if;

  insert into public.notifications (
    fleet_id, event_key, category, entity_type, entity_id, body,
    occurred_at, expires_at
  ) values (
    p_fleet_id, btrim(p_event_key), btrim(p_category), btrim(p_entity_type),
    p_entity_id, p_body, p_occurred_at, p_expires_at
  )
  on conflict (fleet_id, event_key) do update
    set event_key = excluded.event_key
  returning id into v_notification_id;

  insert into public.notification_recipients (notification_id, fleet_id, user_id)
  select v_notification_id, p_fleet_id, recipients.user_id
  from (
    select distinct recipient_id as user_id
    from unnest(coalesce(p_recipient_ids, '{}'::uuid[])) as input(recipient_id)
    where recipient_id is not null
  ) recipients
  where private.is_active_fleet_member(p_fleet_id, recipients.user_id)
    or (
      p_entity_type = 'join_request'
      and exists (
        select 1
        from public.fleet_join_requests request
        where request.id = p_entity_id
          and request.fleet_id = p_fleet_id
          and request.requester_user_id = recipients.user_id
      )
    )
  on conflict (notification_id, user_id) do nothing;

  return v_notification_id;
end;
$$;

create function public.list_notifications(
  p_limit integer,
  p_offset integer
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_items jsonb;
begin
  if v_user_id is null then
    perform private.raise_api_error('unauthenticated', 'Authentication required', 401);
  end if;
  if not private.current_user_email_confirmed() then
    perform private.raise_api_error('email_unverified', 'Email confirmation required', 403);
  end if;
  if p_limit is null or p_limit < 1 or p_limit > 50
    or p_offset is null or p_offset < 0 then
    perform private.raise_api_error('invalid_input', 'Invalid pagination', 400);
  end if;

  select coalesce(jsonb_agg(page.item), '[]'::jsonb)
  into v_items
  from (
    select jsonb_build_object(
      'id', n.id,
      'category', n.category,
      'body', n.body,
      'occurred_at', n.occurred_at,
      'read_at', nr.read_at,
      'entity_type', n.entity_type,
      'entity_id', n.entity_id
    ) as item
    from public.notification_recipients nr
    join public.notifications n on n.id = nr.notification_id
    where nr.user_id = v_user_id
      and private.can_read_notification(n.id, v_user_id)
    order by n.occurred_at desc, n.created_at desc, n.id desc
    offset p_offset limit p_limit
  ) page;

  return jsonb_build_object('items', v_items, 'limit', p_limit, 'offset', p_offset);
end;
$$;

create function public.read_notification(
  p_notification_id uuid
) returns timestamptz
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_read_at timestamptz;
begin
  if v_user_id is null then
    perform private.raise_api_error('unauthenticated', 'Authentication required', 401);
  end if;
  if not private.current_user_email_confirmed() then
    perform private.raise_api_error('email_unverified', 'Email confirmation required', 403);
  end if;
  if p_notification_id is null
    or not private.can_read_notification(p_notification_id, v_user_id) then
    perform private.raise_api_error('not_found', 'Notification not found', 404);
  end if;

  update public.notification_recipients
  set read_at = coalesce(read_at, clock_timestamp())
  where notification_id = p_notification_id and user_id = v_user_id
  returning read_at into v_read_at;

  if v_read_at is null then
    perform private.raise_api_error('not_found', 'Notification not found', 404);
  end if;
  return v_read_at;
end;
$$;

revoke all on function private.can_read_notification(uuid, uuid)
  from public, anon, authenticated;
revoke all on function private.create_notification(
  uuid, text, text, text, uuid, jsonb, timestamptz, timestamptz, uuid[]
) from public, anon, authenticated;
revoke all on function public.list_notifications(integer, integer) from public, anon;
revoke all on function public.read_notification(uuid) from public, anon;
grant execute on function public.list_notifications(integer, integer) to authenticated;
grant execute on function public.read_notification(uuid) to authenticated;
grant execute on function private.create_notification(
  uuid, text, text, text, uuid, jsonb, timestamptz, timestamptz, uuid[]
) to postgres, supabase_admin;
