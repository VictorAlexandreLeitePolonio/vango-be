-- The dispatch schedule is a real pg_cron job.  pg_cron is installed in the
-- database configured by cron.database_name (the hosted database is
-- postgres); pg_net remains server-side and is never exposed to clients.
create extension if not exists pg_net with schema extensions;
create extension if not exists pg_cron;

insert into private.notification_worker_state (id, activation_event_id, enabled)
values (true, 0, false)
on conflict (id) do nothing;

create function private.dispatch_notification_worker()
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_url text;
  v_secret text;
  v_request_id bigint;
begin
  if to_regclass('vault.decrypted_secrets') is null then
    perform private.raise_api_error(
      'worker_dependency_missing',
      'Secure worker configuration is unavailable',
      503
    );
  end if;

  select s.decrypted_secret into v_url
  from vault.decrypted_secrets s
  where s.name = 'notification_worker_url';
  select s.decrypted_secret into v_secret
  from vault.decrypted_secrets s
  where s.name = 'notification_worker_secret';
  if v_url is null or btrim(v_url) = ''
    or v_secret is null or btrim(v_secret) = '' then
    perform private.raise_api_error(
      'worker_not_configured',
      'Worker configuration is unavailable',
      503
    );
  end if;
  if v_url !~ '^https?://[^[:space:]]+$' then
    perform private.raise_api_error(
      'worker_not_configured',
      'Worker configuration is unavailable',
      503
    );
  end if;
  if to_regprocedure('net.http_post(text,jsonb,jsonb,jsonb,integer)') is null then
    perform private.raise_api_error(
      'worker_dependency_missing',
      'HTTP worker extension is unavailable',
      503
    );
  end if;

  -- Preparation and dispatch share the same server-side invocation.  The
  -- event cursor and reminder keys make this safe to repeat on every tick.
  perform private.materialize_notifications(100, clock_timestamp());
  execute 'select net.http_post($1, $2, $3, $4, $5)'
    into v_request_id
    using btrim(v_url), '{}'::jsonb, '{}'::jsonb,
      jsonb_build_object(
        'Content-Type', 'application/json',
        'x-worker-secret', btrim(v_secret)
      ),
      10000;
  if v_request_id is null then
    perform private.raise_api_error(
      'worker_dispatch_failed',
      'Worker request was not queued',
      503
    );
  end if;
  return v_request_id;
end;
$$;

revoke all on function private.dispatch_notification_worker()
  from public, anon, authenticated;
grant execute on function private.dispatch_notification_worker()
  to postgres, supabase_admin;

do $$
declare
  v_job_id bigint;
begin
  select j.jobid into v_job_id
  from cron.job j
  where j.jobname = 'notification-dispatch';
  if v_job_id is null then
    select cron.schedule(
      'notification-dispatch',
      '* * * * *',
      'select private.dispatch_notification_worker();'
    ) into v_job_id;
  end if;
  perform cron.alter_job(v_job_id, active := false);
end;
$$;
