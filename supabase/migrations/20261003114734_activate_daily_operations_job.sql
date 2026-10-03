-- Activates the daily operations job created inactive by cycle 4. Versioned so the
-- remote rollout is reproducible; it only takes effect when the operator runs db push.
do $activate$
declare
  v_job_id bigint;
begin
  if to_regclass('cron.job') is null then
    raise notice 'pg_cron not available; daily operations job left untouched';
    return;
  end if;
  select jobid into v_job_id from cron.job where jobname = 'vango-daily-operations';
  if v_job_id is null then
    raise exception 'vango-daily-operations job is missing';
  end if;
  perform cron.alter_job(v_job_id, active := true);
end;
$activate$;
