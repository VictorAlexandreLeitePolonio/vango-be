create or replace function private.run_daily_operations(
  p_now timestamptz
) returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_target record;
begin
  if p_now is null then
    perform private.raise_api_error('invalid_input', 'Clock is required', 400);
  end if;
  perform private.lock_planning();

  -- A single generation call handles every fleet for a service date.  Keep
  -- one call per distinct local-tomorrow date even when several fleets share
  -- that date; generate_trips is idempotent across all active agendas.
  for v_target in
    select distinct ((p_now at time zone rs.timezone)::date + 1)::date as service_date
    from public.route_schedules rs
    join public.routes r
      on r.id = rs.route_id and r.fleet_id = rs.fleet_id
    where rs.status = 'active'
      and r.status = 'active'
      and rs.valid_until >= ((p_now at time zone rs.timezone)::date + 1)::date
    order by service_date
  loop
    perform private.generate_trips(v_target.service_date, p_now);
  end loop;
  perform private.close_confirmations(p_now);
end;
$$;

revoke all on function private.run_daily_operations(timestamptz)
  from public, anon, authenticated;
grant execute on function private.run_daily_operations(timestamptz)
  to postgres, supabase_admin;

-- The extension is installed in the configured Cron database.  The job is
-- deliberately created inactive so rollout inspection can happen first.
create extension if not exists pg_cron;

do $job_setup$
declare
  v_job record;
  v_job_id bigint;
begin
  for v_job in select jobid from cron.job where jobname = 'vango-daily-operations' loop
    perform cron.unschedule(v_job.jobid);
  end loop;
  v_job_id := cron.schedule(
    'vango-daily-operations',
    '* * * * *',
    $cron_command$select private.run_daily_operations(clock_timestamp());$cron_command$
  );
  perform cron.alter_job(v_job_id, active := false);
end;
$job_setup$;
